import Foundation
import UIKit
import ZIPFoundation

// Save profiles, mods, RPG Maker image decryption, game art and the media index behind the game page.
// Feature ideas (profiles, media browser, per-game and global mods) come from RPGPlayer screenshots; RPG Maker
// MV/MZ asset decryption follows the public format (16-byte "RPGMV" header, first 16 bytes XORed with the
// System.json encryptionKey) that open tools such as Petschko's RPG-Maker-MV-Decrypter document. Code is NexPlay's own.

// MARK: - RPG Maker MV/MZ encrypted assets

enum RPGMakerCrypto {
    /// The 16-byte key from data/System.json ("encryptionKey", 32 hex characters), or nil.
    static func key(for game: Game) -> [UInt8]? {
        guard game.engine.isRPGMaker else { return nil }
        let url = Paths.entryDirectory(for: game).appendingPathComponent("data/System.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hex = object["encryptionKey"] as? String else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.count >= 16 ? Array(bytes.prefix(16)) : nil
    }

    static func isEncrypted(_ url: URL) -> Bool {
        ["rpgmvp", "png_", "rpgmvo", "ogg_", "rpgmvm", "m4a_"].contains(url.pathExtension.lowercased())
    }

    /// The plain file bytes of an encrypted asset (header removed, first 16 bytes restored).
    static func decrypt(_ data: Data, key: [UInt8]) -> Data? {
        guard data.count > 32, key.count >= 16 else { return nil }
        var body = [UInt8](data.dropFirst(16))
        for i in 0..<16 { body[i] ^= key[i] }
        return Data(body)
    }

    /// An image from a plain or encrypted file.
    static func image(at url: URL, key: [UInt8]?) -> UIImage? {
        if isEncrypted(url) {
            guard let key, let raw = try? Data(contentsOf: url), let plain = decrypt(raw, key: key) else { return nil }
            return UIImage(data: plain)
        }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - Game art

enum GameArt {
    /// The big picture for the game page: the custom cover, else RPG Maker's title screen, else the icon,
    /// else an image a web game ships (Godot's <name>.icon.png / .apple-touch-icon.png, favicon.png).
    static func hero(for game: Game) -> UIImage? {
        let custom = Paths.customCoverURL(for: game)
        if let image = UIImage(contentsOfFile: custom.path) { return image }
        if game.engine.isRPGMaker, let title = titleScreen(for: game) { return title }
        if let url = Paths.coverURL(for: game), let image = UIImage(contentsOfFile: url.path) { return image }
        if game.engine == .renpy {
            // Ren'Py's main menu background, else its window icon.
            let gui = Paths.entryDirectory(for: game).appendingPathComponent("game/gui")
            for name in ["main_menu.png", "main_menu.jpg", "main_menu.webp", "game_menu.png", "window_icon.png"] {
                if let image = UIImage(contentsOfFile: gui.appendingPathComponent(name).path) { return image }
            }
        }
        let dir = Paths.entryDirectory(for: game)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let preferred = names.first { $0.lowercased().hasSuffix(".apple-touch-icon.png") }
            ?? names.first { $0.lowercased().hasSuffix(".icon.png") }
            ?? names.first { ["favicon.png", "icon.png", "cover.png", "cover.jpg", "title.png"].contains($0.lowercased()) }
        if let preferred, let image = UIImage(contentsOfFile: dir.appendingPathComponent(preferred).path) { return image }
        return nil
    }

    /// img/titles1/<title1Name> from data/System.json, plain or encrypted.
    static func titleScreen(for game: Game) -> UIImage? {
        let dir = Paths.entryDirectory(for: game)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("data/System.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["title1Name"] as? String, !name.isEmpty else { return nil }
        let key = RPGMakerCrypto.key(for: game)
        for ext in ["png", "rpgmvp", "png_"] {
            let url = dir.appendingPathComponent("img/titles1/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path), let image = RPGMakerCrypto.image(at: url, key: key) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Media index (the Gallery's Media Browser)

enum MediaKind: String, CaseIterable, Identifiable {
    case pictures, portraits, titles, backgrounds, characters, videos, screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pictures: return "Pictures"
        case .portraits: return "Portraits"
        case .titles: return "Titles"
        case .backgrounds: return "Backgrounds"
        case .characters: return "Battlers"
        case .videos: return "Videos"
        case .screenshots: return "Screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .pictures: return "photo"
        case .portraits: return "person.crop.square"
        case .titles: return "textformat.size"
        case .backgrounds: return "mountain.2"
        case .characters: return "figure.stand"
        case .videos: return "film"
        case .screenshots: return "camera.viewfinder"
        }
    }

    var isVideo: Bool { self == .videos }
}

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let kind: MediaKind
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isEncrypted: Bool { RPGMakerCrypto.isEncrypted(url) }
}

enum MediaIndex {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "rpgmvp", "png_"]
    private static let videoExtensions: Set<String> = ["webm", "mp4", "m4v", "mov", "ogv"]

    /// Every picture and video in the game, grouped by kind. RPG Maker folders map to their own tabs; other
    /// games put every image in Pictures. Screenshots from the player come from the game's gallery folder.
    static func scan(_ game: Game) -> [MediaKind: [MediaItem]] {
        var result: [MediaKind: [MediaItem]] = [:]
        func add(_ url: URL, _ kind: MediaKind) { result[kind, default: []].append(MediaItem(url: url, kind: kind)) }

        let root = Paths.folder(for: game)
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                if seen > 60000 { break }
                let ext = url.pathExtension.lowercased()
                let path = url.path.lowercased()
                if videoExtensions.contains(ext) {
                    add(url, .videos)
                    continue
                }
                guard imageExtensions.contains(ext) else { continue }
                if path.contains("/img/") {
                    if path.contains("/img/pictures/") { add(url, .pictures) }
                    else if path.contains("/img/faces/") { add(url, .portraits) }
                    else if path.contains("/img/titles1/") || path.contains("/img/titles2/") { add(url, .titles) }
                    else if path.contains("/img/parallaxes/") || path.contains("/img/battlebacks") { add(url, .backgrounds) }
                    else if path.contains("/img/sv_actors/") || path.contains("/img/enemies/") || path.contains("/img/sv_enemies/") {
                        add(url, .characters)
                    }
                } else if game.engine == .renpy {
                    // Ren'Py: the menu art goes to Titles, everything else to Pictures; placeholders are skipped.
                    if path.contains("/_placeholders/") { continue }
                    if path.contains("/game/gui/") { add(url, .titles) } else { add(url, .pictures) }
                } else if !game.engine.isRPGMaker, !path.contains("/node_modules/") {
                    add(url, .pictures)
                }
            }
        }
        result[.screenshots] = Gallery.shots(for: game).map { MediaItem(url: $0.url, kind: .screenshots) }
        for (kind, items) in result {
            result[kind] = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if let shots = result[.screenshots] {
            result[.screenshots] = shots.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
        }
        return result
    }

    /// A PNG copy of an item in the temp folder (decrypted when needed), for sharing.
    static func exportable(_ item: MediaItem, key: [UInt8]?) -> URL? {
        guard item.isEncrypted else { return item.url }
        guard let image = RPGMakerCrypto.image(at: item.url, key: key), let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(item.name + ".png")
        try? data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Save profiles

/// A named set of save files. The active profile's files live in the game's save/ folder (where the game reads
/// them); the others wait in Profiles/<game-uuid>/<profile-uuid>/. Switching backs up first and copies before
/// it deletes, so no save is lost.
struct SaveProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
}

struct ProfileSummary: Identifiable, Hashable {
    let profile: SaveProfile
    let isActive: Bool
    let count: Int
    let newest: Date?
    var id: UUID { profile.id }
}

enum SaveProfiles {
    static let root: URL = {
        let dir = Paths.support.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The profiles of a game; a game that never used profiles has one, "Profile 1".
    static func list(_ game: Game) -> [SaveProfile] {
        if let profiles = game.profiles, !profiles.isEmpty { return profiles }
        return [SaveProfile(id: game.activeProfile ?? defaultID(game), name: "Profile 1", created: game.addedAt)]
    }

    static func active(_ game: Game) -> SaveProfile {
        let all = list(game)
        return all.first { $0.id == game.activeProfile } ?? all[0]
    }

    /// A stable id for the implicit first profile.
    static func defaultID(_ game: Game) -> UUID {
        game.activeProfile ?? game.id
    }

    static func parkedFolder(_ game: Game, _ profileID: UUID) -> URL {
        root.appendingPathComponent(game.id.uuidString, isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    static func summaries(_ game: Game) -> [ProfileSummary] {
        let activeID = active(game).id
        return list(game).map { profile in
            let isActive = profile.id == activeID
            let folder = isActive ? Paths.saveFolder(for: game) : parkedFolder(game, profile.id)
            var count = 0
            var newest: Date?
            for file in SaveArchive.files(in: folder) where !file.relative.hasSuffix(SaveArchive.displacedSuffix) {
                count += 1
                let date = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date > (newest ?? .distantPast) { newest = date }
            }
            return ProfileSummary(profile: profile, isActive: isActive, count: count, newest: newest)
        }
    }

    /// Parks the active profile's saves and moves `target`'s saves into save/. Runs off the main thread.
    static func switchFiles(_ game: Game, from current: UUID, to target: UUID) throws {
        guard current != target else { return }
        let fm = FileManager.default
        let saves = Paths.saveFolder(for: game)
        try SaveArchive.backUp(game, label: "before-profile-switch-\(Paths.timestamp())")

        // 1. Copy the current saves out (replacing an old parked copy).
        let parked = parkedFolder(game, current)
        let staging = parked.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: parked.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: saves.path) {
            try fm.copyItem(at: saves, to: staging)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try? fm.removeItem(at: parked)
        try fm.moveItem(at: staging, to: parked)

        // 2. Only now clear save/ and bring the target's files in.
        try? fm.removeItem(at: saves)
        let incoming = parkedFolder(game, target)
        if fm.fileExists(atPath: incoming.path) {
            try fm.copyItem(at: incoming, to: saves)
            try? fm.removeItem(at: incoming)
        } else {
            try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        }
        AppLog.log("switched save profile of \(game.name)")
    }

    /// Removes a parked (inactive) profile's files into Rescued Saves.
    static func discardParked(_ game: Game, _ profileID: UUID, name: String) {
        let folder = parkedFolder(game, profileID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let target = Paths.rescuedSaves.appendingPathComponent("\(Paths.safeName(game.name))-\(Paths.safeName(name))-\(Paths.timestamp())", isDirectory: true)
        try? FileManager.default.moveItem(at: folder, to: target)
    }

    static func removeAll(for game: Game) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(game.id.uuidString, isDirectory: true))
    }
}

// MARK: - Mods

/// A mod: a folder whose files lay over the game's files (paths relative to the folder that holds index.html,
/// so "js/plugins/Foo.js" or "img/pictures/Bar.png"), or a single plugin .js. Game mods win over global mods.
struct ModEntry: Identifiable, Hashable {
    let name: String
    let url: URL
    let isGlobal: Bool
    var enabled: Bool
    var fileCount: Int
    var isPlugin: Bool
    var id: String { (isGlobal ? "global/" : "game/") + name }
}

struct ModConfig: Codable {
    var useGlobal: Bool = true
    var disabled: [String] = []
}

enum ModStore {
    static let root: URL = {
        let dir = Paths.support.appendingPathComponent("Mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var globalFolder: URL { folder(root.appendingPathComponent("Global", isDirectory: true)) }

    static func gameFolder(_ game: Game) -> URL {
        folder(root.appendingPathComponent("Games", isDirectory: true).appendingPathComponent(game.id.uuidString, isDirectory: true))
    }

    private static func folder(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func configURL(_ game: Game?) -> URL {
        root.appendingPathComponent(game.map { "\($0.id.uuidString).json" } ?? "global.json")
    }

    static func config(_ game: Game?) -> ModConfig {
        guard let data = try? Data(contentsOf: configURL(game)),
              let config = try? JSONDecoder().decode(ModConfig.self, from: data) else { return ModConfig() }
        return config
    }

    static func setConfig(_ config: ModConfig, for game: Game?) {
        if let data = try? JSONEncoder().encode(config) { try? data.write(to: configURL(game), options: .atomic) }
    }

    /// The mods in a game's folder (game != nil) or the global folder.
    static func mods(_ game: Game?) -> [ModEntry] {
        let base = game.map { gameFolder($0) } ?? globalFolder
        let disabled = Set(config(game).disabled)
        let kids = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return kids
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let files = SaveArchive.files(in: url)
                let plugin = FileManager.default.fileExists(atPath: url.appendingPathComponent(".nexplay-plugin").path)
                return ModEntry(name: url.lastPathComponent, url: url, isGlobal: game == nil,
                                enabled: !disabled.contains(url.lastPathComponent), fileCount: files.count, isPlugin: plugin)
            }
    }

    static func setEnabled(_ mod: ModEntry, _ enabled: Bool, game: Game?) {
        var config = self.config(game)
        config.disabled.removeAll { $0 == mod.name }
        if !enabled { config.disabled.append(mod.name) }
        setConfig(config, for: game)
    }

    static func delete(_ mod: ModEntry) {
        try? FileManager.default.removeItem(at: mod.url)
    }

    /// The mods that apply to a game, highest priority first.
    static func active(for game: Game) -> [ModEntry] {
        var list = mods(game).filter { $0.enabled }
        if config(game).useGlobal { list += mods(nil).filter { $0.enabled } }
        return list
    }

    /// Adds a picked folder, .zip or .js file as a mod. Runs off the main thread.
    static func add(_ source: URL, game: Game?) throws -> String {
        let fm = FileManager.default
        let base = game.map { gameFolder($0) } ?? globalFolder
        var name = Paths.safeName(source.deletingPathExtension().lastPathComponent)
        var target = base.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            name = Paths.safeName(source.deletingPathExtension().lastPathComponent) + " \(suffix)"
            target = base.appendingPathComponent(name, isDirectory: true)
            suffix += 1
        }
        let ext = source.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        _ = fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try fm.copyItem(at: source, to: target)
        } else if ext == "zip" {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.unzipItem(at: source, to: target)
            GameScanner.tidy(target)
        } else if ext == "js" {
            let plugins = target.appendingPathComponent("js/plugins", isDirectory: true)
            try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: plugins.appendingPathComponent(source.lastPathComponent))
            try Data().write(to: target.appendingPathComponent(".nexplay-plugin"))
        } else {
            throw ImportError.unsupported(ext)
        }
        flatten(target)
        return name
    }

    /// A mod packed as "<Mod>/www/js/..." or "<Mod>/<Mod>/js/..." is moved up so its files start at js/, img/...
    private static func flatten(_ folder: URL) {
        let fm = FileManager.default
        for _ in 0..<2 {
            let kids = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            let known = ["js", "img", "audio", "data", "fonts", "movies", "css", "icon", "effects"]
            if kids.contains(where: { known.contains($0.lastPathComponent.lowercased()) }) { return }
            guard kids.count == 1, let only = kids.first,
                  (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
            let inner = (try? fm.contentsOfDirectory(at: only, includingPropertiesForKeys: nil)) ?? []
            for item in inner {
                try? fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            try? fm.removeItem(at: only)
        }
    }

    /// Lowercased path relative to the game folder -> the mod file that replaces or adds it. Built once at
    /// game start; nil when no mod applies.
    static func overlay(for game: Game) -> ((String) -> String?)? {
        let mods = active(for: game)
        guard !mods.isEmpty else { return nil }
        let entryFolder = (game.entry as NSString).deletingLastPathComponent
        let prefix = entryFolder.isEmpty ? "" : entryFolder.lowercased() + "/"
        var map: [String: String] = [:]
        // Lowest priority first, so higher-priority mods overwrite.
        for mod in mods.reversed() {
            for file in SaveArchive.files(in: mod.url) where !file.relative.hasPrefix(".nexplay") {
                map[prefix + file.relative.lowercased()] = file.url.path
            }
        }
        return { path in map[path] }
    }

    /// Plugin names (file names without .js) of single-file plugin mods, to append to js/plugins.js.
    static func pluginNames(for game: Game) -> [String] {
        active(for: game).filter { $0.isPlugin }.flatMap { mod -> [String] in
            let folder = mod.url.appendingPathComponent("js/plugins")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.lowercased().hasSuffix(".js") }.map { String($0.dropLast(3)) }
        }
    }

    /// Script text of plugin mods for web games (no plugins.js there): injected at the end of the page.
    static func webScripts(for game: Game) -> [String] {
        guard !game.engine.isRPGMaker else { return [] }
        return active(for: game).filter { $0.isPlugin }.flatMap { mod -> [String] in
            SaveArchive.files(in: mod.url.appendingPathComponent("js/plugins"))
                .filter { $0.url.pathExtension.lowercased() == "js" }
                .compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        }
    }

    static func removeAll(for game: Game) {
        try? FileManager.default.removeItem(at: gameFolder(game))
        try? FileManager.default.removeItem(at: configURL(game))
    }
}
