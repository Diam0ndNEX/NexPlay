import Foundation
import ZIPFoundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NexPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let games: URL = subfolder("Games")
    /// Save backups: Backups/<game-uuid>/<date>.zip
    static let backups: URL = subfolder("Backups")
    /// Saves kept when a game is deleted: Rescued Saves/<name>-<uuid>/
    static let rescuedSaves: URL = subfolder("Rescued Saves")
    /// Covers the user picked: Covers/<game-uuid>.png (wins over the game's own icon).
    static let covers: URL = subfolder("Covers")
    /// Screenshots taken in a game: Gallery/<game-uuid>/<date>.png
    static let gallery: URL = subfolder("Gallery")

    private static func subfolder(_ name: String) -> URL {
        let dir = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func folder(for game: Game) -> URL {
        games.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    /// The folder that holds the game's entry page (for RPG Maker MV/MZ this is the "www" folder).
    static func entryDirectory(for game: Game) -> URL {
        folder(for: game).appendingPathComponent(game.entry).deletingLastPathComponent()
    }

    /// Where RPG Maker keeps file saves in NW.js mode (next to index.html, like on a PC).
    static func saveFolder(for game: Game) -> URL {
        entryDirectory(for: game).appendingPathComponent("save", isDirectory: true)
    }

    static func backupFolder(for game: Game) -> URL {
        backups.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    static func coverURL(for game: Game) -> URL? {
        let custom = customCoverURL(for: game)
        if FileManager.default.fileExists(atPath: custom.path) { return custom }
        let url = entryDirectory(for: game).appendingPathComponent("icon/icon.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func customCoverURL(for game: Game) -> URL {
        covers.appendingPathComponent(game.id.uuidString + ".png")
    }

    static func galleryFolder(for game: Game) -> URL {
        gallery.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    /// A name that is safe to use as a file name.
    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Game" : String(trimmed.prefix(80))
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}

enum MIME {
    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8", "xml": "application/xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "ico": "image/x-icon", "bmp": "image/bmp",
        "mp3": "audio/mpeg", "ogg": "audio/ogg", "oga": "audio/ogg", "wav": "audio/wav",
        "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac", "opus": "audio/ogg; codecs=opus",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm", "rpgmvp": "application/octet-stream",
    ]

    static func type(for url: URL) -> String {
        types[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}

enum ImportError: LocalizedError {
    case missing
    case unsupported(String)
    case noGame

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The file could not be found."
        case .unsupported(let ext):
            let kind = ext.isEmpty ? "This file" : "A .\(ext) file"
            return "\(kind) can't be imported. Unpack archives like RAR or 7z first, then import the folder or a ZIP."
        case .noGame:
            return "No game found. NexPlay looks for an index.html (RPG Maker MV/MZ keep it in the \"www\" folder)."
        }
    }
}

struct DetectedGame {
    let engine: GameEngine
    let entry: String
}

enum GameScanner {
    /// Removes junk that ZIPs made on a Mac carry along.
    static func tidy(_ root: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: root.appendingPathComponent("__MACOSX"))
        try? fm.removeItem(at: root.appendingPathComponent(".DS_Store"))
    }

    /// Path of `url` relative to `root`, comparing resolved paths (iOS reports /var as /private/var).
    static func relativePath(of url: URL, in root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let full = url.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        var rel = String(full.dropFirst(base.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Finds the game inside an imported folder. Looks up to three folders deep, so "Game/www/index.html" works.
    /// RPG Maker MV/MZ wins, then Godot web exports, Construct, TyranoScript, Twine, then any HTML page
    /// (index.html first, else the page whose name matches the folder, else the largest page).
    static func detect(in root: URL) -> DetectedGame? {
        let fm = FileManager.default
        var level: [URL] = [root]
        var plain: (dir: URL, page: URL)?

        func entry(_ page: URL) -> String { relativePath(of: page, in: root) }

        for _ in 0...3 {
            var next: [URL] = []
            for dir in level {
                let pages = htmlFiles(in: dir)
                let index = pages.first { $0.lastPathComponent.lowercased() == "index.html" }
                if let index {
                    if fm.fileExists(atPath: dir.appendingPathComponent("js/rmmz_core.js").path) {
                        return DetectedGame(engine: .rpgMZ, entry: entry(index))
                    }
                    if fm.fileExists(atPath: dir.appendingPathComponent("js/rpg_core.js").path) {
                        return DetectedGame(engine: .rpgMV, entry: entry(index))
                    }
                }
                if !pages.isEmpty {
                    if let godot = godotPage(in: dir, pages: pages) {
                        return DetectedGame(engine: .godot, entry: entry(godot))
                    }
                    let start = index ?? preferredPage(pages, folder: dir)
                    if isConstruct(dir) { return DetectedGame(engine: .construct, entry: entry(start)) }
                    if isTyrano(dir) { return DetectedGame(engine: .tyrano, entry: entry(start)) }
                    if let story = pages.first(where: { isTwine($0) }) {
                        return DetectedGame(engine: .twine, entry: entry(story))
                    }
                    if plain == nil { plain = (dir, start) }
                }
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                next += kids.filter {
                    let name = $0.lastPathComponent.lowercased()
                    return name != "__macosx" && name != "node_modules"
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            }
            level = next
        }
        if let plain { return DetectedGame(engine: .web, entry: entry(plain.page)) }
        return nil
    }

    /// A Godot web export: an HTML page next to a .pck and a .wasm (Godot 3 and 4).
    private static func godotPage(in dir: URL, pages: [URL]) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let lower = names.map { $0.lowercased() }
        guard let pck = lower.first(where: { $0.hasSuffix(".pck") }), lower.contains(where: { $0.hasSuffix(".wasm") }) else {
            return nil
        }
        let base = String(pck.dropLast(4))
        if let same = pages.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == base }) { return same }
        if let index = pages.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) { return index }
        return pages.first
    }

    /// A Godot desktop build (a .pck or a Godot .exe without a web page). It can't run in a web view.
    static func isDesktopGodot(_ root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        var count = 0
        for case let url as URL in walker {
            count += 1
            if count > 3000 { break }
            if url.pathExtension.lowercased() == "pck" { return true }
        }
        return false
    }

    private static func isConstruct(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return ["c2runtime.js", "scripts/c3runtime.js", "scripts/c3main.js", "scripts/main.js"].contains {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        } && (fm.fileExists(atPath: dir.appendingPathComponent("data.json").path)
              || fm.fileExists(atPath: dir.appendingPathComponent("data.js").path)
              || fm.fileExists(atPath: dir.appendingPathComponent("c2runtime.js").path))
    }

    private static func isTyrano(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("tyrano").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("data/scenario").path)
    }

    /// Twine 2 stories are one HTML file holding a <tw-storydata> element.
    private static func isTwine(_ page: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: page) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4_000_000)) ?? Data()
        return data.range(of: Data("<tw-storydata".utf8)) != nil
    }

    /// The page to start: one named like the folder or "game"/"main"/"play", else the largest.
    private static func preferredPage(_ pages: [URL], folder: URL) -> URL {
        let folderName = folder.lastPathComponent.lowercased()
        let wanted = [folderName, "game", "main", "play", "start", "story"]
        for name in wanted {
            if let page = pages.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return page
            }
        }
        let sized = pages.map { page -> (URL, Int) in
            let size = (try? page.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (page, size)
        }
        return sized.max { $0.1 < $1.1 }?.0 ?? pages[0]
    }

    static func htmlFiles(in dir: URL) -> [URL] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return kids
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// RPG Maker games name themselves in data/System.json; other games use their page title.
    static func title(for found: DetectedGame, in root: URL) -> String? {
        let entryURL = root.appendingPathComponent(found.entry)
        let dir = entryURL.deletingLastPathComponent()

        if found.engine.isRPGMaker,
           let data = try? Data(contentsOf: dir.appendingPathComponent("data/System.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["gameTitle"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return htmlTitle(at: entryURL)
    }

    static func htmlTitle(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>",
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let title = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
        return total
    }
}
