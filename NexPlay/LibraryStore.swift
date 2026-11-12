import Foundation
import ZIPFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var isImporting = false
    @Published var importMessage: String?
    /// Saves rescued from a deleted game with the same title, offered after an import.
    @Published var rescueOffer: RescueOffer?

    private let fileURL = Paths.support.appendingPathComponent("library.json")

    init() {
        ImportPipeline.sweepStaging()
        load()
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

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(games) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Changes

    /// Changes one game in place. Always go through this, so a stale copy of a game never overwrites newer changes.
    func mutate(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[index])
        save()
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
        _ = await Task.detached(priority: .userInitiated) { SaveArchive.rescue(target) }.value
        await DataStores.wipe(for: game)
        try? FileManager.default.removeItem(at: Paths.folder(for: game))
        try? FileManager.default.removeItem(at: Paths.backupFolder(for: game))
        try? FileManager.default.removeItem(at: Paths.customCoverURL(for: game))
        Gallery.removeAll(for: game)
        ModStore.removeAll(for: game)
        RenPyRuntime.clearPackage(for: game)
        let parkedProfiles = SaveProfiles.root.appendingPathComponent(game.id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: parkedProfiles.path) {
            // Saves of other profiles are rescued too, never thrown away.
            let target = Paths.rescuedSaves.appendingPathComponent("\(Paths.safeName(game.name))-profiles-\(game.id.uuidString)", isDirectory: true)
            try? FileManager.default.moveItem(at: parkedProfiles, to: target)
        }
        CoverCache.forget(game)
        games.removeAll { $0.id == game.id }
        save()
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
    /// Asks whether an import with the title of an installed game updates it or is added as a new game.
    @Published var pendingUpdate: PendingUpdate?
    private var importCancel: ImportCancel?
    /// A download from a link (LinkImport.swift), cancelled with the import card's X.
    var downloadTask: URLSessionTask?

    func cancelImport() {
        importCancel?.cancel()
        downloadTask?.cancel()
    }

    func answerUpdate(_ choice: UpdateChoice) {
        let request = pendingUpdate
        pendingUpdate = nil
        request?.continuation.resume(returning: choice)
    }

    private func askUpdate(title: String, existing: Game) async -> UpdateChoice {
        await withCheckedContinuation { continuation in
            pendingUpdate = PendingUpdate(title: title, existing: existing, continuation: continuation)
        }
    }

    func importItems(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        let cancel = ImportCancel()
        importCancel = cancel
        var notes: [String] = []
        importProgress = ImportProgress(stage: .preparing, detail: "", fraction: 0, item: 1, itemCount: urls.count,
                                        itemName: urls.first?.lastPathComponent ?? "")
        cancel.onProgress { stage, detail, fraction in
            Task { @MainActor in
                self.importProgress.stage = stage
                self.importProgress.detail = detail
                if let fraction { self.importProgress.fraction = fraction }
            }
        }

        for (index, url) in urls.enumerated() {
            if cancel.isCancelled { break }
            importProgress = ImportProgress(stage: .preparing, detail: url.lastPathComponent, fraction: 0,
                                            item: index + 1, itemCount: urls.count, itemName: url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                importStatus = "Preparing \(url.lastPathComponent)…"
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ImportPipeline.stage(url, cancel: cancel) { text in
                        Task { @MainActor in self.importStatus = text }
                    }
                }.value

                var choice = UpdateChoice.addNew
                let existing = games.first { $0.name.caseInsensitiveCompare(staged.title) == .orderedSame && $0.engine == staged.found.engine }
                if let existing {
                    choice = await askUpdate(title: staged.title, existing: existing)
                }
                if choice == .cancel || cancel.isCancelled {
                    try? FileManager.default.removeItem(at: staged.folder)
                    continue
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
                    }
                    RenPyRuntime.clearPackage(for: existing)
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
                if !lines.isEmpty || urls.count > 1 {
                    notes.append(([staged.title + ":"] + (lines.isEmpty ? ["Imported."] : lines)).joined(separator: "\n"))
                }
            } catch PipelineError.cancelled {
                notes.append("\(url.lastPathComponent): cancelled.")
            } catch {
                notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.log("import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        importCancel = nil
        importStatus = ""
        isImporting = false
        if !notes.isEmpty {
            importMessage = notes.joined(separator: "\n\n")
        }
    }
}

enum UpdateChoice {
    case update, addNew, cancel
}

struct PendingUpdate: Identifiable {
    let id = UUID()
    let title: String
    let existing: Game
    let continuation: CheckedContinuation<UpdateChoice, Never>
}

struct RescueOffer: Identifiable {
    let id = UUID()
    let gameID: UUID
    let gameName: String
    let folder: URL
}
