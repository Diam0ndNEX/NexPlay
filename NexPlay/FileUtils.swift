import Foundation
import ZIPFoundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NexPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let games: URL = {
        let dir = support.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func folder(for game: Game) -> URL {
        games.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    /// The folder that holds the game's entry page (for RPG Maker MV/MZ this is the "www" folder).
    static func entryDirectory(for game: Game) -> URL {
        folder(for: game).appendingPathComponent(game.entry).deletingLastPathComponent()
    }

    static func coverURL(for game: Game) -> URL? {
        let url = entryDirectory(for: game).appendingPathComponent("icon/icon.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// Finds the game inside an imported folder. Looks up to two folders deep, so "Game/www/index.html" works.
    static func detect(in root: URL) -> DetectedGame? {
        let fm = FileManager.default
        var level: [URL] = [root]
        var firstPlain: URL?

        for _ in 0...2 {
            var next: [URL] = []
            for dir in level {
                let index = dir.appendingPathComponent("index.html")
                if fm.fileExists(atPath: index.path) {
                    let rel = relativePath(of: dir, in: root)
                    let entry = rel.isEmpty ? "index.html" : rel + "/index.html"
                    if fm.fileExists(atPath: dir.appendingPathComponent("js/rmmz_core.js").path) {
                        return DetectedGame(engine: .rpgMZ, entry: entry)
                    }
                    if fm.fileExists(atPath: dir.appendingPathComponent("js/rpg_core.js").path) {
                        return DetectedGame(engine: .rpgMV, entry: entry)
                    }
                    if firstPlain == nil { firstPlain = dir }
                }
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                next += kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            level = next
        }

        if let dir = firstPlain {
            let rel = relativePath(of: dir, in: root)
            return DetectedGame(engine: .web, entry: rel.isEmpty ? "index.html" : rel + "/index.html")
        }
        if let html = htmlFiles(in: root).first {
            return DetectedGame(engine: .web, entry: html.lastPathComponent)
        }
        return nil
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
