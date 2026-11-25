import Foundation
import UIKit
import ZIPFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var isImporting = false
    @Published var importMessage: String?
    /// Saves rescued from a deleted game with the same title, offered after an import.
    @Published var rescueOffer: RescueOffer?

    private let fileURL = Paths.support.appendingPathComponent("library.json")

    /// 8.6.2: the app's library, for screens shown where no environment object reaches (Setup Center's Windows check).
    static weak var current: LibraryStore?

    init() {
        ImportPipeline.sweepStaging()
        load()
        LibraryStore.current = self
        // 8.14.1: a delete the app did not finish (it closed or crashed after the game left the list) is finished now.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.finishPendingDeletes()
        }
    }

    // MARK: - Pending deletes (8.14.1)

    /// PendingDeletes/<uuid>.json: the game being deleted, written before it leaves the list, removed when every step
    /// is done. The owner saw the app close while deleting, with the game gone from the list on the next start but its
    /// files, saves and web data possibly still there.
    private static let pendingFolder: URL = {
        let dir = Paths.support.appendingPathComponent("PendingDeletes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func pendingURL(_ id: UUID) -> URL {
        pendingFolder.appendingPathComponent("\(id.uuidString).json")
    }

    private func notePending(_ game: Game) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(game) {
            try? data.write(to: Self.pendingURL(game.id), options: .atomic)
        }
    }

    private func finishPendingDeletes() async {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.pendingFolder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let game = try? decoder.decode(Game.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // A game that is in the library again (re-imported with the same id) is not touched.
            if self.game(id: game.id) != nil {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // If the same step closes the app again, it must not do so at every start: after two tries the web data
            // step is skipped, after three the record is dropped.
            let key = "pendingDeleteTries.\(game.id.uuidString)"
            let tries = UserDefaults.standard.integer(forKey: key) + 1
            UserDefaults.standard.set(tries, forKey: key)
            if tries > 3 {
                AppLog.log("delete: gave up finishing the delete of \(game.name)")
                try? FileManager.default.removeItem(at: url)
                UserDefaults.standard.removeObject(forKey: key)
                continue
            }
            AppLog.log("delete: finishing the delete of \(game.name) that did not complete last time (try \(tries))")
            _ = AppLog.shared.text
            await removeFiles(of: game, skipWebData: tries >= 2)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            games = try decoder.decode([Game].self, from: data)
        } catch {
            // Never overwrite a library we could not read: keep a copy for recovery.
            let copy = Paths.support.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: copy)
            AppLog.log("library.json could not be read (\(error.localizedDescription)); copy kept as \(copy.lastPathComponent)")
            games = []
        }
    }

    /// Writes library.json now (adding and removing games: a crash right after must not lose the change).
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = games
        let url = fileURL
        // On the same serial queue as delayed writes, so an older delayed write can never land after this one.
        Self.saveQueue.sync { Self.write(snapshot, to: url) }
        PendingLibraryWrite.shared.clearAll()
    }

    /// 8.19.0: small changes (a name typed letter by letter, play time, settings toggles) are written once, 0.4 s
    /// after the last one, off the main thread. Before, every keystroke encoded and wrote the whole library.
    private func saveSoon() {
        pendingSave?.cancel()
        let snapshot = games
        let url = fileURL
        let token = PendingLibraryWrite.shared.set(snapshot, url)
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url)
            PendingLibraryWrite.shared.clear(token)
        }
        pendingSave = work
        Self.saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes a pending change now (the app goes to the background).
    func flushSave() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        let snapshot = games
        let url = fileURL
        Self.saveQueue.sync { Self.write(snapshot, to: url) }
        PendingLibraryWrite.shared.clearAll()
    }

    private var pendingSave: DispatchWorkItem?
    private static let saveQueue = DispatchQueue(label: "NexPlay.library-save", qos: .utility)

    nonisolated static func write(_ games: [Game], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(games)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.log("library.json could not be written: \(error.localizedDescription)")
        }
    }

    // MARK: - Changes

    /// Changes one game in place. Always go through this, so a stale copy of a game never overwrites newer changes.
    func mutate(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[index])
        saveSoon()
    }

    func game(id: UUID) -> Game? {
        games.first { $0.id == id }
    }

    func toggleFavorite(_ game: Game) {
        mutate(game.id) { $0.isFavorite.toggle() }
    }

    /// Removes the game's files, web data and backups. Save files are moved to Rescued Saves first,
    /// so re-importing the same game can put them back.
    func delete(_ game: Game) async {
        let target = game
        // 8.7.10: the card leaves the list first, so nothing on screen (card, zoom source, game page) points at a game
        // whose files are being removed underneath it.
        // 8.14.0: each step is logged first, so a crash while deleting names its step in the next launch's log.
        AppLog.log("delete: \(game.name): removing from the library")
        notePending(game)
        games.removeAll { $0.id == game.id }
        save()
        await removeFiles(of: target)
    }

    /// Every step after the game left the list. Safe to run again: each step skips what is already gone.
    private func removeFiles(of game: Game, skipWebData: Bool = false) async {
        let target = game
        AppLog.log("delete: rescuing saves")
        _ = await Task.detached(priority: .userInitiated) { SaveArchive.rescue(target) }.value
        if skipWebData {
            AppLog.log("delete: web data skipped")
        } else {
            AppLog.log("delete: web data")
            _ = AppLog.shared.text
            await DataStores.wipe(for: game)
        }
        AppLog.log("delete: files")
        WindowsLibraryLink.remove(for: game)
        try? FileManager.default.removeItem(at: Paths.folder(for: game))
        try? FileManager.default.removeItem(at: Paths.backupFolder(for: game))
        try? FileManager.default.removeItem(at: Paths.customCoverURL(for: game))
        Gallery.removeAll(for: game)
        ModStore.removeAll(for: game)
        SaveStateStore.removeAll(for: game.id)
        RenPyRuntime.clearPackage(for: game)
        let parkedProfiles = SaveProfiles.root.appendingPathComponent(game.id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: parkedProfiles.path) {
            // Saves of other profiles are rescued too, never thrown away.
            let target = Paths.rescuedSaves.appendingPathComponent("\(Paths.safeName(game.name))-profiles-\(game.id.uuidString)", isDirectory: true)
            try? FileManager.default.moveItem(at: parkedProfiles, to: target)
        }
        CoverCache.forget(game)
        WindowsGameFiles.forget(game)
        try? FileManager.default.removeItem(at: Self.pendingURL(game.id))
        AppLog.log("deleted \(game.name)")
    }

    /// Puts rescued saves back into the game the offer names.
    func acceptRescue(_ offer: RescueOffer) async {
        guard let game = self.game(id: offer.gameID) else { return }
        let folder = offer.folder
        do {
            let count = try await Task.detached(priority: .userInitiated) {
                try SaveArchive.putBackRescued(folder, into: game)
            }.value
            importMessage = "Put back \(count) save file(s) for \(game.name)."
        } catch {
            importMessage = "Could not put the saves back: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    /// Status text for the progress card while importing.
    @Published var importStatus = ""
    /// Stage, detail and percentage for the floating import card.
    @Published var importProgress = ImportProgress()
    private var importCancel: ImportCancel?
    /// A download from a link (LinkImport.swift), cancelled with the import card's X.
    var downloadTask: URLSessionTask?
    /// True while a link download runs (the queue waits for it).
    var isDownloading = false
    /// 8.19.0: items picked while another import runs wait here instead of being dropped.
    private var importQueue: [ImportJob] = []
    private var queueRunning = false
    /// Items of the current run (done + waiting), for "2 of 5" on the card.
    private var runTotal = 0
    private var runDone = 0

    func cancelImport() {
        importCancel?.cancel()
        downloadTask?.cancel()
        if !importQueue.isEmpty {
            AppLog.log("import: cancelled, \(importQueue.count) waiting item(s) dropped")
            for job in importQueue { ([job.url] + job.parts).forEach { Self.removeTemporary($0) } }
            importQueue.removeAll()
        }
    }

    /// 8.19.0: asked with a UIKit alert over whatever is on screen. The SwiftUI dialog sat on the library and never
    /// appeared while a game page or sheet was open, so the import waited forever and every later import was ignored.
    private func askUpdate(title: String, existing: Game) async -> UpdateChoice {
        await withCheckedContinuation { (continuation: CheckedContinuation<UpdateChoice, Never>) in
            var answered = false
            func answer(_ choice: UpdateChoice) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: choice)
            }
            let alert = UIAlertController(
                title: "\(title) is already in your library",
                message: "Update keeps its saves, settings and layout and replaces the game files. A file in the new version that sits where a save is gets kept as a .nex-displaced.bak copy.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Update It", style: .default) { _ in answer(.update) })
            alert.addAction(UIAlertAction(title: "Add as New Game", style: .default) { _ in answer(.addNew) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(.cancel) })
            TopController.present(alert)
        }
    }

    /// 7.4.0 bulk import: every game folder and archive one level inside a picked folder, in one queue.
    func importFolderOfGames(_ parent: URL) async {
        let access = ScopedAccess(parent)
        let archives: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "xz", "bz2", "html", "htm", "swf", "exe", "iso", "jgp"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let children = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let found = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])) ?? []
            return found.filter { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { return true }
                return archives.contains(url.pathExtension.lowercased()) || ArchiveParts.volume(url) != nil
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
        guard !children.isEmpty else {
            importMessage = "No game folders or archives were found inside \(parent.lastPathComponent)."
            return
        }
        AppLog.log("bulk import: \(children.count) item(s) from \(parent.lastPathComponent)")
        enqueue(ArchiveParts.group(children).compactMap { group in
            guard let first = group.first else { return nil }
            return ImportJob(url: first, parts: Array(group.dropFirst()), access: [access])
        })
        await runQueue()
    }

    /// Imports picked files and folders (security-scoped URLs from Files are fine) and downloaded or Inbox copies,
    /// which are deleted afterwards. While another import runs the items are queued behind it.
    func importItems(_ urls: [URL]) async {
        let accesses = urls.map { ScopedAccess($0) }
        var jobs: [ImportJob] = []
        for group in ArchiveParts.group(urls) {
            guard var first = group.first else { continue }
            var parts = Array(group.dropFirst())
            // One volume picked alone: the other volumes are used when they sit next to it and can be read
            // (downloads, Inbox copies, a folder picked for bulk import).
            if parts.isEmpty, ArchiveParts.volume(first) != nil || first.pathExtension.lowercased() == "rar" {
                let all = ArchiveParts.siblings(of: first)
                if all.count > 1, let head = all.first {
                    first = head
                    parts = Array(all.dropFirst())
                }
            }
            jobs.append(ImportJob(url: first, parts: parts, access: accesses))
        }
        enqueue(jobs)
        await runQueue()
    }

    private func enqueue(_ jobs: [ImportJob]) {
        guard !jobs.isEmpty else { return }
        if queueRunning || isDownloading {
            AppLog.log("import: \(jobs.count) item(s) queued behind the current import")
        }
        importQueue += jobs
        runTotal += jobs.count
        if queueRunning { importProgress.itemCount = runTotal }
    }

    /// Runs the queue unless it is already running (a link download that is still running starts it when done).
    func runQueue() async {
        guard !queueRunning, !importQueue.isEmpty else { return }
        if isDownloading { return }
        queueRunning = true
        isImporting = true
        let cancel = ImportCancel()
        importCancel = cancel
        var notes: [String] = []
        cancel.onProgress { stage, detail, fraction in
            Task { @MainActor in
                self.importProgress.stage = stage
                self.importProgress.detail = detail
                if let fraction { self.importProgress.fraction = fraction }
            }
        }

        while !importQueue.isEmpty {
            if cancel.isCancelled { break }
            let job = importQueue.removeFirst()
            runDone += 1
            if let note = await importOne(job, cancel: cancel, multiple: runTotal > 1) { notes.append(note) }
            Self.removeTemporary(job.url)
            job.parts.forEach { Self.removeTemporary($0) }
        }

        importCancel = nil
        importStatus = ""
        queueRunning = false
        runTotal = 0
        runDone = 0
        isImporting = false
        if !notes.isEmpty {
            let text = notes.joined(separator: "\n\n")
            importMessage = importMessage.map { $0 + "\n\n" + text } ?? text
        }
        // Items picked after a cancel stopped the loop start their own run.
        if !importQueue.isEmpty {
            runTotal = importQueue.count
            Task { await self.runQueue() }
        }
    }

    /// One item: stage, ask about an existing copy, install or update. Returns the line for the summary alert.
    private func importOne(_ job: ImportJob, cancel: ImportCancel, multiple: Bool) async -> String? {
        let url = job.url
        importProgress = ImportProgress(stage: .preparing, detail: url.lastPathComponent, fraction: 0,
                                        item: runDone, itemCount: max(runTotal, runDone), itemName: url.lastPathComponent)
        do {
            importStatus = "Preparing \(url.lastPathComponent)…"
            AppLog.log("import: start \(url.lastPathComponent)")
            let staged = try await stageAsking(job, cancel: cancel)

            var choice = UpdateChoice.addNew
            let existing = games.first { $0.name.caseInsensitiveCompare(staged.title) == .orderedSame && $0.engine == staged.found.engine }
            if let existing {
                choice = await askUpdate(title: staged.title, existing: existing)
            }
            if choice == .cancel || cancel.isCancelled {
                try? FileManager.default.removeItem(at: staged.folder)
                return cancel.isCancelled ? "\(url.lastPathComponent): cancelled." : nil
            }

            importStatus = "Installing \(staged.title)…"
            importProgress.itemName = staged.title
            importProgress.stage = choice == .update ? .updating : .installing
            importProgress.detail = staged.title
            importProgress.fraction = ImportStage.installing.span.0
            var lines: [String] = []
            if choice == .update, let existing {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try ImportPipeline.update(existing, with: staged)
                }.value
                mutate(existing.id) { game in
                    game.engine = updated.engine
                    game.entry = updated.entry
                    if updated.engine == .windows {
                        game.exePath = staged.found.entry
                        game.windowsInfo = WindowsPE.inspect(program: staged.found.entry, in: Paths.folder(for: existing))
                    }
                }
                RenPyRuntime.clearPackage(for: existing)
                CoverCache.forget(existing)
                WindowsGameFiles.forget(existing)
                lines.append("Updated \(staged.title). Saves and settings were kept.")
                AppLog.log("updated \(staged.title) from \(url.lastPathComponent)")
            } else {
                let game = try await Task.detached(priority: .userInitiated) {
                    try ImportPipeline.install(staged)
                }.value
                games.append(game)
                save()
                AppLog.log("imported \(game.name) (\(game.engine.badge)) from \(url.lastPathComponent)")
                if game.engine.isRPGMaker, let folder = SaveArchive.rescued(forTitle: game.name) {
                    rescueOffer = RescueOffer(gameID: game.id, gameName: game.name, folder: folder)
                }
            }
            importProgress.fraction = 1
            if let note = staged.encodingNote { lines.append(note) }
            lines += staged.warnings
            if !lines.isEmpty || multiple {
                return ([staged.title + ":"] + (lines.isEmpty ? ["Imported."] : lines)).joined(separator: "\n")
            }
            return nil
        } catch PipelineError.cancelled {
            return "\(url.lastPathComponent): cancelled."
        } catch {
            AppLog.log("import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Stages a job; an encrypted archive asks for its password (up to three tries) and is read again with it.
    private func stageAsking(_ job: ImportJob, cancel: ImportCancel) async throws -> StagedImport {
        var password: String?
        var tries = 0
        let url = job.url
        let parts = job.parts
        while true {
            let given = password
            do {
                return try await Task.detached(priority: .userInitiated) {
                    try ImportPipeline.stage(url, parts: parts, password: given, cancel: cancel) { text in
                        Task { @MainActor in self.importStatus = text }
                    }
                }.value
            } catch PipelineError.needsPassword(let name, let wrong) {
                tries += 1
                guard tries <= 3, let answer = await askPassword(name: name, wrong: wrong) else {
                    throw PipelineError.needsPassword(name, wrong: wrong)
                }
                AppLog.log("import: trying a password for \(name)")
                password = answer
            }
        }
    }

    private func askPassword(name: String, wrong: Bool) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var answered = false
            let alert = UIAlertController(
                title: wrong ? "Wrong Password" : "Password Needed",
                message: "\(name) is protected. Enter its password (F95zone and other sites often list it next to the download).",
                preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = "Password"
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: "Unpack", style: .default) { [weak alert] _ in
                guard !answered else { return }
                answered = true
                let text = alert?.textFields?.first?.text ?? ""
                continuation.resume(returning: text.isEmpty ? nil : text)
            })
            TopController.present(alert)
        }
    }

    /// Deletes copies iOS or NexPlay made only for importing (Inbox copies, picker copies, link downloads).
    /// Never touches a file the user picked in place.
    nonisolated static func removeTemporary(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("LinkImport-") {
            try? FileManager.default.removeItem(at: parent)
        } else if path.contains("/Inbox/") || path.hasPrefix(temp + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 8.19.0: the newest library change not on disk yet. NexPlay calls exit(0) in a few places (Windows games need a
/// fresh launch); an atexit handler writes this first, so a change made just before is not lost.
final class PendingLibraryWrite: @unchecked Sendable {
    static let shared = PendingLibraryWrite()
    private let lock = NSLock()
    private var games: [Game]?
    private var url: URL?
    private var token = 0

    private init() {
        atexit {
            PendingLibraryWrite.shared.writeIfNeeded()
        }
    }

    func set(_ games: [Game], _ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        token += 1
        self.games = games
        self.url = url
        return token
    }

    /// Clears the pending write if no newer one came after `token`.
    func clear(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == self.token { games = nil }
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        games = nil
    }

    private func writeIfNeeded() {
        lock.lock()
        let pending = games
        let target = url
        games = nil
        lock.unlock()
        if let pending, let target { LibraryStore.write(pending, to: target) }
    }
}

/// One queued import and the security-scoped access it needs.
struct ImportJob {
    let url: URL
    /// The other volumes of a split archive, in order.
    var parts: [URL] = []
    let access: [ScopedAccess]
}

enum UpdateChoice {
    case update, addNew, cancel
}


struct RescueOffer: Identifiable {
    let id = UUID()
    let gameID: UUID
    let gameName: String
    let folder: URL
}
