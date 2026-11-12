import Foundation
import ZIPFoundation

// The "displaced copy" convention (a replaced save is kept as <name>.<app>-displaced.bak) and rescuing saves into
// "Rescued Saves" when a game is deleted follow Empo's docs/saves.mdx and SaveMigration.swift.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

struct SaveInfo {
    var count: Int = 0
    var bytes: Int64 = 0
    var newest: Date?
    var displaced: Int = 0
}

struct BackupEntry: Identifiable, Hashable {
    let url: URL
    let date: Date
    let bytes: Int64
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum SaveArchiveError: LocalizedError {
    case noSaves
    case notABackup
    case wrongKind(found: String, wanted: String)

    var errorDescription: String? {
        switch self {
        case .noSaves: return "This game has no save files yet."
        case .notABackup: return "No RPG Maker save files (.rpgsave or .rmmzsave) were found in what you picked."
        case .wrongKind(let found, let wanted):
            return "These are \(found) save files, but this game uses \(wanted) files. They come from a different RPG Maker version."
        }
    }
}

/// File-based saves (NW.js mode): info, ZIP export and restore, backups, rescue on delete.
/// Everything here is synchronous file work: call it from a background task.
enum SaveArchive {
    static let displacedSuffix = ".nex-displaced.bak"
    static let saveExtensions: Set<String> = ["rpgsave", "rmmzsave"]

    /// Regular files below `folder`, with paths relative to it.
    static func files(in folder: URL) -> [(url: URL, relative: String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [(url: URL, relative: String)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append((url, GameScanner.relativePath(of: url, in: folder)))
        }
        return result
    }

    static func info(for game: Game) -> SaveInfo {
        var info = SaveInfo()
        for file in files(in: Paths.saveFolder(for: game)) {
            if file.relative.hasSuffix(displacedSuffix) {
                info.displaced += 1
                continue
            }
            let values = try? file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            info.count += 1
            info.bytes += Int64(values?.fileSize ?? 0)
            if let date = values?.contentModificationDate, date > (info.newest ?? .distantPast) {
                info.newest = date
            }
        }
        return info
    }

    /// Zips the game's save/ folder; entries are named save/<file>.
    static func zipSaves(of game: Game, to zipURL: URL) throws {
        let folder = Paths.saveFolder(for: game)
        guard !files(in: folder).isEmpty else { throw SaveArchiveError.noSaves }
        let fm = FileManager.default
        try? fm.removeItem(at: zipURL)
        try fm.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.zipItem(at: folder, to: zipURL, shouldKeepParent: true)
    }

    /// A ZIP of the saves in the temp folder, named <Name>-saves-<date>.zip, ready for the share sheet.
    static func exportZip(for game: Game) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Paths.safeName(game.name))-saves-\(Paths.timestamp()).zip")
        try zipSaves(of: game, to: url)
        AppLog.log("exported saves of \(game.name)")
        return url
    }

    /// Copies the current saves into Backups/<game-uuid>/<label>.zip. Returns nil when there is nothing to back up.
    @discardableResult
    static func backUp(_ game: Game, label: String) throws -> URL? {
        guard !files(in: Paths.saveFolder(for: game)).isEmpty else { return nil }
        let url = Paths.backupFolder(for: game).appendingPathComponent("\(label).zip")
        try zipSaves(of: game, to: url)
        return url
    }

    static func backups(for game: Game) -> [BackupEntry] {
        let fm = FileManager.default
        let folder = Paths.backupFolder(for: game)
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "zip" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return BackupEntry(url: url, date: values?.contentModificationDate ?? .distantPast,
                                   bytes: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    /// Restores saves from a ZIP (a backup or an export). Same rules as `importSaves`.
    static func restore(zip: URL, into game: Game) throws -> Int {
        try importSaves(from: [zip], into: game)
    }

    /// Imports saves from what the person picked: ZIPs, loose save files (.rpgsave / .rmmzsave, e.g. copied from a
    /// PC's www/save folder), or folders. The current saves are backed up first (before-restore-<date>.zip), and
    /// every file that gets replaced is kept as <name>.nex-displaced.bak. Returns how many files were imported.
    static func importSaves(from urls: [URL], into game: Game) throws -> Int {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("save-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "zip" {
                let folder = temp.appendingPathComponent("zip-\(index)", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: folder)
            } else {
                let target = temp.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: target.path) { continue }
                try fm.copyItem(at: url, to: target)
            }
        }
        GameScanner.tidy(temp)

        guard let source = saveRoot(in: temp) else { throw SaveArchiveError.notABackup }
        try checkKind(in: source, for: game)
        try backUp(game, label: "before-restore-\(Paths.timestamp())")
        // A real save/ folder comes over whole; loose files only bring their save files.
        let wholeFolder = source.lastPathComponent.lowercased() == "save"
        let count = try putBack(from: source, into: Paths.saveFolder(for: game), onlySaveFiles: !wholeFolder)
        if count == 0 { throw SaveArchiveError.notABackup }
        AppLog.log("imported \(count) save file(s) into \(game.name) from \(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
        return count
    }

    /// MV saves are .rpgsave, MZ saves are .rmmzsave; saves of the other kind can't load.
    private static func checkKind(in folder: URL, for game: Game) throws {
        let kids = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let found = Set(kids.map { $0.pathExtension.lowercased() }).intersection(saveExtensions)
        switch game.engine {
        case .rpgMV where !found.contains("rpgsave") && found.contains("rmmzsave"):
            throw SaveArchiveError.wrongKind(found: "RPG Maker MZ (.rmmzsave)", wanted: "RPG Maker MV (.rpgsave)")
        case .rpgMZ where !found.contains("rmmzsave") && found.contains("rpgsave"):
            throw SaveArchiveError.wrongKind(found: "RPG Maker MV (.rpgsave)", wanted: "RPG Maker MZ (.rmmzsave)")
        default:
            break
        }
    }

    /// The shallowest folder in an unpacked import that holds save files directly (a folder named save wins at
    /// the same depth). Looks up to six levels deep, so a ZIP of a whole game (Game/www/save) works too.
    static func saveRoot(in folder: URL) -> URL? {
        let fm = FileManager.default
        var level = [folder]
        for _ in 0...5 {
            let holders = level.filter { hasSaveFiles($0) }
            if let named = holders.first(where: { $0.lastPathComponent.lowercased() == "save" }) { return named }
            if let first = holders.first { return first }
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                next += kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }

    private static func hasSaveFiles(_ dir: URL) -> Bool {
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return kids.contains { saveExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Copies every file from `source` into `destination` (only top-level .rpgsave/.rmmzsave files when
    /// `onlySaveFiles`). A file that would be replaced is kept as <name>.nex-displaced.bak first.
    /// Returns the number of files copied.
    static func putBack(from source: URL, into destination: URL, onlySaveFiles: Bool = false) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var count = 0
        for file in files(in: source) {
            if file.relative.hasSuffix(displacedSuffix) { continue }
            if onlySaveFiles {
                if file.relative.contains("/") || !saveExtensions.contains(file.url.pathExtension.lowercased()) { continue }
            }
            let target = destination.appendingPathComponent(file.relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                let displaced = URL(fileURLWithPath: target.path + displacedSuffix)
                try? fm.removeItem(at: displaced)
                try fm.moveItem(at: target, to: displaced)
            }
            try fm.copyItem(at: file.url, to: target)
            count += 1
        }
        return count
    }

    /// Deletes the save files after backing them up (before-delete-<date>.zip).
    static func deleteSaves(of game: Game) throws {
        try backUp(game, label: "before-delete-\(Paths.timestamp())")
        try? FileManager.default.removeItem(at: Paths.saveFolder(for: game))
        AppLog.log("deleted saves of \(game.name) (backup kept)")
    }

    // MARK: - Rescue on delete

    /// Moves the game's save/ folder into Rescued Saves/<name>-<uuid>/ before the game is deleted.
    @discardableResult
    static func rescue(_ game: Game) -> URL? {
        let folder = Paths.saveFolder(for: game)
        guard !files(in: folder).isEmpty else { return nil }
        let target = Paths.rescuedSaves.appendingPathComponent("\(Paths.safeName(game.name))-\(game.id.uuidString)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: folder, to: target)
            AppLog.log("rescued saves of \(game.name) into Rescued Saves/\(target.lastPathComponent)")
            return target
        } catch {
            AppLog.log("could not rescue saves of \(game.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// The newest rescued save folder for a game with this title, if any.
    static func rescued(forTitle title: String) -> URL? {
        let prefix = Paths.safeName(title) + "-"
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: Paths.rescuedSaves, includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        let matches = kids.filter { url in
            let name = url.lastPathComponent
            // <safe name>-<36 character uuid>
            return name.hasPrefix(prefix) && name.count == prefix.count + 36
        }
        return matches.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Puts rescued saves into a game and removes the rescued folder.
    static func putBackRescued(_ folder: URL, into game: Game) throws -> Int {
        let count = try putBack(from: folder, into: Paths.saveFolder(for: game))
        try? FileManager.default.removeItem(at: folder)
        AppLog.log("put \(count) rescued save file(s) back into \(game.name)")
        return count
    }
}
