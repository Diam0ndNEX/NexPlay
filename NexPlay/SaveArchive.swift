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

    var errorDescription: String? {
        switch self {
        case .noSaves: return "This game has no save files yet."
        case .notABackup: return "This ZIP holds no RPG Maker save files."
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

    /// Restores saves from a ZIP. The current saves are backed up first (before-restore-<date>.zip),
    /// and every file that gets replaced is kept as <name>.nex-displaced.bak. Returns how many files were restored.
    static func restore(zip: URL, into game: Game) throws -> Int {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.unzipItem(at: zip, to: temp)
        GameScanner.tidy(temp)

        guard let source = saveRoot(in: temp) else { throw SaveArchiveError.notABackup }
        try backUp(game, label: "before-restore-\(Paths.timestamp())")
        let count = try putBack(from: source, into: Paths.saveFolder(for: game))
        AppLog.log("restored \(count) save file(s) into \(game.name) from \(zip.lastPathComponent)")
        return count
    }

    /// The folder in an unpacked ZIP that holds save files: save/, www/save/, or the top level.
    static func saveRoot(in folder: URL) -> URL? {
        let fm = FileManager.default
        var candidates = [folder.appendingPathComponent("save"), folder.appendingPathComponent("www/save"), folder]
        // A ZIP of a folder may add one more level.
        let kids = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for kid in kids {
            candidates.append(kid.appendingPathComponent("save"))
            candidates.append(kid)
        }
        for candidate in candidates {
            let hasSave = files(in: candidate).contains { file in
                saveExtensions.contains(file.url.pathExtension.lowercased()) && !file.relative.contains("/")
            }
            if hasSave { return candidate }
        }
        return nil
    }

    /// Copies every file from `source` into `destination`. A file that would be replaced is kept as
    /// <name>.nex-displaced.bak first. Returns the number of files copied.
    static func putBack(from source: URL, into destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var count = 0
        for file in files(in: source) {
            if file.relative.hasSuffix(displacedSuffix) { continue }
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
