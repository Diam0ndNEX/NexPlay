import Foundation
import ZIPFoundation

// Desktop Godot games (.pck, or a .exe / .x86_64 with the .pck embedded) run on Godot's own web runtime: the
// official web export template of the same major.minor version, bundled in NexPlay.app/GodotRuntimes by
// tools/fetch_godot_runtimes.py at build time (Godot Engine, MIT license, https://godotengine.org/license).
// The runtime loads the game's .pck with `--main-pack`, exactly as a web export does with its own .pck.
// Pack layout (header: "GDPC", format version, major, minor, patch; format 2+: flags, file base; embedded:
// ...pck, u64 size, "GDPC" at the end) follows Godot's core/io/file_access_pack.cpp.

struct GodotVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)" }

    static func < (a: GodotVersion, b: GodotVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "4.3" or "3.6.3".
    init?(_ text: String) {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        major = parts[0]
        minor = parts[1]
        patch = parts.count > 2 ? parts[2] : 0
    }
}

/// What the player needs to start a desktop Godot game.
struct GodotLaunch {
    let version: GodotVersion
    let runtime: GodotVersion
    let folder: URL
    /// Lines for the game log (pack header, repairs).
    let notes: [String]
    /// Extra command-line arguments for the engine (a main scene the project only names for some platforms).
    /// May hold `GodotRuntime.overrideMarker` entries, which the launcher page turns into preloaded files.
    let args: [String]
}

enum GodotRuntime {
    private static let magic: UInt32 = 0x4350_4447 // "GDPC" little-endian
    static let executableExtensions: Set<String> = ["exe", "x86_64", "x86_32", "arm64", ""]
    /// An argument starting with this names an override.cfg beside the pack (file name only). The launcher page
    /// removes it from the engine arguments and copies the file next to the pack in Godot's file system, where
    /// Godot loads it like a desktop build does (override.cfg beside the executable / main pack).
    static let overrideMarker = "--nexplay-override="

    // MARK: - Packs

    /// The fields of a pack header that matter here. Godot 3 packs are format 1; Godot 4 packs are format 2 or 3
    /// and add flags (1 = encrypted directory, 2 = file offsets count from the start of the pack) and the file base.
    struct PackHeader {
        let format: UInt32
        let version: GodotVersion
        let flags: UInt32
        let fileBase: UInt64
        let size: UInt64

        var encrypted: Bool { format >= 2 && flags & 1 != 0 }
        var relativeBase: Bool { format >= 2 && flags & 2 != 0 }

        var summary: String {
            if format >= 2 {
                return "pack format \(format), Godot \(version), flags \(flags), file base \(fileBase), \(size) bytes"
            }
            return "pack format \(format), Godot \(version), \(size) bytes"
        }
    }

    static func header(_ url: URL) -> PackHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 32 else { return nil }
        guard (try? handle.seek(toOffset: 0)) != nil,
              let data = try? handle.read(upToCount: 32), data.count == 32 else { return nil }
        guard readU32(data, 0) == magic else { return nil }
        let format = readU32(data, 4)
        let major = Int(readU32(data, 8)), minor = Int(readU32(data, 12)), patch = Int(readU32(data, 16))
        guard (3...9).contains(major), minor < 100, patch < 100 else { return nil }
        let flags = format >= 2 ? readU32(data, 20) : 0
        let base = format >= 2 ? readU64(data, 24) : 0
        return PackHeader(format: format, version: GodotVersion(major: major, minor: minor, patch: patch),
                          flags: flags, fileBase: base, size: size)
    }

    /// The engine version a .pck was exported with, or nil when the file is not a Godot pack.
    static func packVersion(_ url: URL) -> GodotVersion? {
        header(url)?.version
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        data.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    /// Where a pack embedded at the end of an executable starts and how long it is.
    static func embeddedPack(in url: URL) -> (offset: UInt64, length: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 32 else { return nil }
        guard (try? handle.seek(toOffset: size - 12)) != nil,
              let tail = try? handle.read(upToCount: 12), tail.count == 12 else { return nil }
        let length = readU64(tail, 0)
        let end = readU32(tail, 8)
        guard end == magic, length > 0, length < size - 12 else { return nil }
        return (size - 12 - length, length)
    }

    /// Copies packs embedded in Windows/Linux executables into "<name>.pck" next to them, so a game that ships as
    /// one .exe can run. Looks two folders deep; skips executables that already have a .pck beside them.
    @discardableResult
    static func extractEmbeddedPacks(in root: URL, cancel: ImportCancel?) throws -> Int {
        let fm = FileManager.default
        var extracted = 0
        var level = [root]
        for _ in 0...2 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                let names = Set(kids.map { $0.lastPathComponent.lowercased() })
                for kid in kids {
                    if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        next.append(kid)
                        continue
                    }
                    let ext = kid.pathExtension.lowercased()
                    guard executableExtensions.contains(ext) else { continue }
                    let base = kid.deletingPathExtension().lastPathComponent
                    if names.contains(base.lowercased() + ".pck") { continue }
                    guard let pack = embeddedPack(in: kid) else { continue }
                    try cancel?.check()
                    cancel?.report(.scanning, "Unpacking the Godot game from \(kid.lastPathComponent)…", 0.5, force: true)
                    let target = dir.appendingPathComponent(base + ".pck")
                    try copyRange(of: kid, offset: pack.offset, length: pack.length, to: target, cancel: cancel)
                    if let note = try? rebase(target, exeOffset: pack.offset) {
                        AppLog.log("godot import: \(note)")
                    }
                    extracted += 1
                }
            }
            level = next
        }
        return extracted
    }

    private static func copyRange(of source: URL, offset: UInt64, length: UInt64, to target: URL, cancel: ImportCancel?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try input.seek(toOffset: offset)
        var remaining = length
        let chunk: UInt64 = 4 << 20
        while remaining > 0 {
            try cancel?.check()
            let count = Int(min(chunk, remaining))
            guard let data = try input.read(upToCount: count), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    // MARK: - Offsets of packs cut out of an executable

    /// A pack cut out of an .exe keeps file offsets that count from the start of the .exe when the export did not
    /// mark them as relative (Godot 3 and early Godot 4 exports). Godot then reads the wrong bytes: "no main scene
    /// defined", or a crash such as "call_indirect to a signature that does not match". This shifts the offsets so
    /// they count from the start of the .pck. Safe to run again: offsets that already fit inside the pack are left
    /// alone. Returns a line for the log when it changed something.
    @discardableResult
    static func rebase(_ pack: URL, exeOffset: UInt64) throws -> String? {
        guard exeOffset > 0, let head = header(pack) else { return nil }
        if head.format >= 2 {
            guard !head.relativeBase, head.fileBase >= head.size, head.fileBase >= exeOffset,
                  head.fileBase - exeOffset < head.size else { return nil }
            try writeU64(head.fileBase - exeOffset, at: 24, in: pack)
            return "fixed the file base of \(pack.lastPathComponent) (it counted from the start of the .exe)"
        }
        // Format 1 (Godot 3): every directory entry carries its own offset.
        guard let entries = format1Entries(pack, size: head.size), !entries.isEmpty else { return nil }
        var maxEnd: UInt64 = 0
        var minOffset = UInt64.max
        for entry in entries {
            maxEnd = max(maxEnd, entry.offset &+ entry.length)
            minOffset = min(minOffset, entry.offset)
        }
        guard maxEnd > head.size, minOffset >= exeOffset, maxEnd - exeOffset <= head.size else { return nil }
        let handle = try FileHandle(forUpdating: pack)
        defer { try? handle.close() }
        for entry in entries {
            try handle.seek(toOffset: entry.position)
            var value = (entry.offset - exeOffset).littleEndian
            let bytes = withUnsafeBytes(of: &value) { Data($0) }
            try handle.write(contentsOf: bytes)
        }
        return "fixed \(entries.count) file offsets in \(pack.lastPathComponent) (they counted from the start of the .exe)"
    }

    /// For a .pck that an older NexPlay cut out of an executable without fixing it: finds that executable beside
    /// the pack (same embedded length) and rebases the pack. Returns a line for the log when something changed.
    static func repairIfExtracted(_ pack: URL) -> String? {
        let fm = FileManager.default
        guard let size = (try? pack.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        let dir = pack.deletingLastPathComponent()
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for kid in kids {
            guard executableExtensions.contains(kid.pathExtension.lowercased()) else { continue }
            if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            guard let embedded = embeddedPack(in: kid), embedded.length == UInt64(size) else { continue }
            do {
                return try rebase(pack, exeOffset: embedded.offset)
            } catch {
                return "could not fix \(pack.lastPathComponent): \(error.localizedDescription)"
            }
        }
        return nil
    }

    private static func writeU64(_ value: UInt64, at offset: UInt64, in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var little = value.littleEndian
        let bytes = withUnsafeBytes(of: &little) { Data($0) }
        try handle.write(contentsOf: bytes)
    }

    /// Directory entries of a format 1 pack: where each offset is stored, the offset and the file length.
    /// Layout: header (20 bytes) + 16 reserved u32, file count, then per file: u32 name length, name, u64 offset,
    /// u64 size, 16-byte md5.
    private static func format1Entries(_ pack: URL, size: UInt64) -> [(position: UInt64, offset: UInt64, length: UInt64)]? {
        guard let handle = try? FileHandle(forReadingFrom: pack) else { return nil }
        defer { try? handle.close() }
        let reader = PackReader(handle: handle, size: size)
        var position: UInt64 = 84
        guard let count = reader.u32(at: position), count > 0, count < 2_000_000 else { return nil }
        position += 4
        var entries: [(position: UInt64, offset: UInt64, length: UInt64)] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let nameLength = reader.u32(at: position), nameLength < 65_536 else { return nil }
            position += 4 + UInt64(nameLength)
            guard let offset = reader.u64(at: position), let length = reader.u64(at: position + 8) else { return nil }
            entries.append((position: position, offset: offset, length: length))
            position += 32
        }
        return entries
    }

    /// The main .pck of a desktop Godot game (relative to `root`): the one named like an executable, else the
    /// largest. nil when there is none.
    static func mainPack(in root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var packs: [(URL, Int)] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20000 { break }
            guard url.pathExtension.lowercased() == "pck" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            packs.append((url, size))
        }
        let valid = packs.filter { packVersion($0.0) != nil }
        return (valid.isEmpty ? packs : valid).max { $0.1 < $1.1 }?.0
    }

    /// True when the folder looks like a C#/.NET Godot export (those can't run on the web runtime).
    static func usesDotNet(_ root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20000 { break }
            let name = url.lastPathComponent
            if name == "GodotSharp.dll" || name.hasPrefix("GodotSharp") || name == "GodotPlugins.dll" { return true }
        }
        return false
    }

    // MARK: - Runtimes

    /// Versions bundled in the app, from NexPlay.app/GodotRuntimes/godot-<version>.zip.
    static var bundled: [GodotVersion] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("GodotRuntimes"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name -> GodotVersion? in
            guard name.hasPrefix("godot-"), name.hasSuffix(".zip") else { return nil }
            return GodotVersion(String(name.dropFirst(6).dropLast(4)))
        }
        .sorted()
    }

    /// The runtime for a pack: a bundled version picked in Game Settings, else the same major.minor (newest
    /// patch), else the oldest newer minor of the same major (Godot loads packs from older minors, never from newer
    /// ones). Godot 4.0-4.2 packs go to the oldest single-threaded runtime (4.3+): the threaded 4.1/4.2 web builds
    /// crash in Safari on iPhone ("call_indirect to a signature that does not match").
    static func runtime(for pack: GodotVersion, override chosen: String? = nil) -> GodotVersion? {
        let have = bundled
        if let chosen, let wanted = GodotVersion(chosen), have.contains(wanted) { return wanted }
        let sameMajor = have.filter { $0.major == pack.major }
        if pack.major == 4 && pack.minor <= 2, let single = sameMajor.filter({ $0.minor >= 3 }).min() { return single }
        if let exact = sameMajor.filter({ $0.minor == pack.minor }).max() { return exact }
        return sameMajor.filter { $0.minor > pack.minor }.min()
    }

    /// Runtimes that can load a pack of this version (same major, same or newer minor), for Game Settings.
    static func compatible(with pack: GodotVersion) -> [GodotVersion] {
        bundled.filter { $0.major == pack.major && $0.minor >= pack.minor }
    }

    // MARK: - Pack contents

    /// What the pack says about itself: whether it holds project settings, and the main scene they name.
    struct PackInfo {
        var files = 0
        var hasProject = false
        var mainScene: String?
        /// A main scene named only for some platforms ("application/run/main_scene.pc"), passed on the command line.
        var platformScene: String?
        /// Every scene in the pack (res:// paths, remaps resolved to the original name).
        var scenes: [String] = []
    }

    /// Reads the pack directory (formats 1-3, not encrypted) and the project settings in it.
    static func inspect(_ pack: URL) -> PackInfo? {
        guard let head = header(pack), !head.encrypted,
              let handle = try? FileHandle(forReadingFrom: pack) else { return nil }
        defer { try? handle.close() }
        let reader = PackReader(handle: handle, size: head.size)
        var position: UInt64
        var base: UInt64 = 0
        switch head.format {
        case 0, 1:
            position = 84
        case 2:
            position = 96
            base = head.fileBase
        default:
            guard let dir = reader.u64(at: 32) else { return nil }
            position = dir
            base = head.fileBase
        }
        guard let count = reader.u32(at: position), count < 2_000_000 else { return nil }
        position += 4
        var info = PackInfo()
        info.files = Int(count)
        var project: (offset: UInt64, size: UInt64)?
        var sceneSet = Set<String>()
        for _ in 0..<count {
            guard let length = reader.u32(at: position), length < 65_536,
                  let nameData = reader.data(at: position + 4, count: Int(length)) else { break }
            position += 4 + UInt64(length)
            guard let offset = reader.u64(at: position), let size = reader.u64(at: position + 8) else { break }
            position += head.format >= 2 ? 36 : 32
            let name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
            if name.hasSuffix("project.binary") && !name.contains("/.godot/") {
                project = (base + offset, size)
            }
            if let scene = scenePath(name) { sceneSet.insert(scene) }
        }
        info.scenes = sceneSet.sorted()
        guard let project, project.size > 0, project.size < 16_000_000,
              let data = reader.data(at: project.offset, count: Int(project.size)) else { return info }
        info.hasProject = data.prefix(4) == Data("ECFG".utf8)
        info.mainScene = sceneValue(after: "application/run/main_scene", in: data, exact: true)
        if info.mainScene == nil {
            info.platformScene = sceneValue(after: "application/run/main_scene.", in: data, exact: false)
        }
        return info
    }

    /// A pack entry as a scene path ("res://Main.tscn"), or nil when it is not a scene. "x.tscn.remap" becomes
    /// "x.tscn" (Godot follows the remap); converted copies and import caches are skipped.
    private static func scenePath(_ entry: String) -> String? {
        var path = entry
        if path.lowercased().hasSuffix(".remap") { path = String(path.dropLast(6)) }
        let lower = path.lowercased()
        guard lower.hasSuffix(".tscn") || lower.hasSuffix(".scn") || lower.hasSuffix(".escn") else { return nil }
        if lower.contains(".converted.") || lower.contains(".import/") || lower.contains(".godot/") { return nil }
        if !path.hasPrefix("res://") {
            path = path.hasPrefix("/") ? "res:/" + path : "res://" + path
        }
        if path.lowercased().hasPrefix("res://addons/") { return nil }
        return path
    }

    /// How deep a res:// path is (0 = at the top of the project).
    private static func depth(_ path: String) -> Int {
        path.dropFirst(6).filter { $0 == "/" }.count
    }

    /// A likely main scene when the project names none: a scene called main, boot, splash, title... (shallowest
    /// first), else the only scene at the top of the project. nil when nothing looks right.
    static func guessMainScene(_ scenes: [String]) -> String? {
        let preferred = ["main", "boot", "bootstrap", "start", "startup", "launcher", "entry", "init", "root",
                         "splash", "splashscreen", "splash_screen", "intro", "title", "titlescreen", "title_screen",
                         "mainmenu", "main_menu", "menu", "game", "loader", "loading"]
        var best: (score: Int, path: String)?
        for path in scenes {
            let file = (path as NSString).lastPathComponent
            let name = (file as NSString).deletingPathExtension.lowercased()
            guard let rank = preferred.firstIndex(of: name) else { continue }
            let score = rank * 10 + min(depth(path), 9)
            if let current = best, current.score <= score { continue }
            best = (score: score, path: path)
        }
        if let best { return best.path }
        let top = scenes.filter { depth($0) == 0 }
        return top.count == 1 ? top[0] : nil
    }

    /// The first res:// or uid:// string after a settings key (the key is followed by its value in project.binary).
    private static func sceneValue(after key: String, in data: Data, exact: Bool) -> String? {
        let keyData = Data(key.utf8)
        var searchStart = data.startIndex
        while let found = data.range(of: keyData, in: searchStart..<data.endIndex) {
            searchStart = found.upperBound
            // An exact key is followed by its value's length, not by ".feature" (a per-platform variant).
            if exact, found.upperBound < data.endIndex, data[found.upperBound] == UInt8(ascii: ".") { continue }
            let window = data[found.upperBound..<min(data.endIndex, found.upperBound + 400)]
            for marker in ["res://", "uid://"] {
                if let start = window.range(of: Data(marker.utf8)) {
                    var end = start.lowerBound
                    while end < window.endIndex, window[end] >= 0x20, window[end] < 0x7F { end += 1 }
                    let value = String(decoding: window[start.lowerBound..<end], as: UTF8.self)
                    if value.count > marker.count { return value }
                }
            }
        }
        return nil
    }

    // MARK: - override.cfg

    /// An override.cfg beside the pack (any letter case). Desktop Godot loads it from beside the executable and
    /// lets it change project settings, including the main scene.
    static func overrideFile(beside pack: URL) -> URL? {
        let dir = pack.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = names.first(where: { $0.lowercased() == "override.cfg" }) else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// The main scene an override.cfg sets ([application] run/main_scene="res://..."), a per-platform one if that
    /// is all it has.
    static func overrideScene(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var section = ""
        var exact: String?
        var perPlatform: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            var key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 { key = String(key.dropFirst().dropLast()) }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") { value.removeFirst() }
            if value.hasSuffix("\"") { value.removeLast() }
            guard value.hasPrefix("res://") || value.hasPrefix("uid://") else { continue }
            let full = section.isEmpty ? key : section + "/" + key
            if full == "application/run/main_scene" {
                exact = value
            } else if full.hasPrefix("application/run/main_scene.") && perPlatform == nil {
                perPlatform = value
            }
        }
        return exact ?? perPlatform
    }

    /// Unpacks a bundled runtime into Application Support/NexPlay/GodotRuntimes/<version>/ once, and returns the
    /// folder (godot.js, godot.wasm, worklets).
    static func prepare(_ version: GodotVersion) throws -> URL {
        let fm = FileManager.default
        let folder = Paths.support.appendingPathComponent("GodotRuntimes/\(version)", isDirectory: true)
        if fm.fileExists(atPath: folder.appendingPathComponent("godot.wasm").path) { return folder }
        guard let zip = Bundle.main.resourceURL?.appendingPathComponent("GodotRuntimes/godot-\(version).zip"),
              fm.fileExists(atPath: zip.path) else { throw RuntimeError.missing(version.description) }
        let temp = folder.deletingLastPathComponent().appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: temp)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: temp, to: folder)
        return folder
    }

    /// Everything needed to start a desktop game: repairs an old extracted pack, reads its header, picks and
    /// unpacks the runtime. Synchronous file work: call it from a background task.
    static func launch(pack: URL, override chosen: String? = nil) throws -> GodotLaunch {
        guard FileManager.default.fileExists(atPath: pack.path) else { throw RuntimeError.noPack }
        var notes: [String] = []
        if let note = repairIfExtracted(pack) { notes.append(note) }
        guard let head = header(pack) else { throw RuntimeError.unknownVersion }
        notes.append(head.summary)
        if head.encrypted { throw RuntimeError.encrypted }
        var args: [String] = []
        var cfgScene: String?
        if let cfg = overrideFile(beside: pack) {
            args.append(overrideMarker + cfg.lastPathComponent)
            cfgScene = overrideScene(cfg)
            var line = "\(cfg.lastPathComponent) found beside the pack, loaded into the game"
            if let cfgScene { line += " (main scene \(cfgScene))" }
            notes.append(line)
        }
        if let info = inspect(pack) {
            var line = "pack holds \(info.files) files, \(info.scenes.count) scenes"
            line += info.hasProject ? ", project settings found" : ", NO project settings (project.binary) found"
            if let scene = info.mainScene { line += ", main scene \(scene)" }
            if let scene = info.platformScene {
                line += ", main scene only set per platform (\(scene)), passed on the command line"
                args.append(scene)
            }
            if info.mainScene == nil && info.platformScene == nil {
                if let cfgScene {
                    line += ", main scene from override.cfg \(cfgScene), passed on the command line"
                    args.append(cfgScene)
                } else if let guess = guessMainScene(info.scenes) {
                    line += ", no main scene set; guessed \(guess), passed on the command line"
                    args.append(guess)
                } else {
                    line += ", no main scene set and none could be guessed"
                }
            }
            notes.append(line)
            if info.mainScene == nil && cfgScene == nil && !info.scenes.isEmpty {
                let top = info.scenes.sorted { (depth($0), $0) < (depth($1), $1) }.prefix(15)
                notes.append("top scenes in the pack: " + top.joined(separator: ", "))
            }
        }
        guard let picked = GodotRuntime.runtime(for: head.version, override: chosen) else {
            throw RuntimeError.noRuntime(head.version.description, GodotRuntime.bundled.map { $0.description })
        }
        if chosen != nil { notes.append("runtime chosen in Game Settings") }
        let folder = try GodotRuntime.prepare(picked)
        return GodotLaunch(version: head.version, runtime: picked, folder: folder, notes: notes, args: args)
    }

    enum RuntimeError: LocalizedError {
        case missing(String)
        case noPack
        case unknownVersion
        case encrypted
        case noRuntime(String, [String])

        var errorDescription: String? {
            switch self {
            case .missing(let version):
                return "The Godot \(version) runtime isn't in this build of NexPlay."
            case .noPack:
                return "No Godot .pck file was found in this game."
            case .unknownVersion:
                return "The game's .pck doesn't say which Godot version made it (it may be encrypted)."
            case .encrypted:
                return "This Godot game is encrypted with its developer's key, so the Godot runtime can't read it."
            case .noRuntime(let version, let have):
                return "This game was made with Godot \(version), and this build of NexPlay has runtimes for \(have.joined(separator: ", ")). Packs from a newer Godot than the newest runtime can't load."
            }
        }
    }

    // MARK: - Launcher

    /// The page that starts a desktop game on the web runtime. Paths are URL paths on the local server.
    /// `packPath` is percent-encoded and relative to the game folder.
    static func launcherPage(packPath: String, title: String, threads: Bool, args: [String] = []) -> Data {
        let pack = PageScripts.jsString("/" + packPath)
        // override.cfg goes next to the pack in Godot's file system (same folder as the pack's path there).
        let packDir = (packPath as NSString).deletingLastPathComponent
        let prefix = packDir.isEmpty ? "/" : "/" + packDir + "/"
        var preloads: [String] = []
        var engineArgs: [String] = []
        for arg in args {
            if arg.hasPrefix(overrideMarker) {
                let name = String(arg.dropFirst(overrideMarker.count))
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                preloads.append("[" + PageScripts.jsString(prefix + encoded) + ", " + PageScripts.jsString(prefix + "override.cfg") + "]")
            } else {
                engineArgs.append(arg)
            }
        }
        let argList = "[" + engineArgs.map { PageScripts.jsString($0) }.joined(separator: ", ") + "]"
        let preloadList = "[" + preloads.joined(separator: ", ") + "]"
        let name = title.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "&", with: "")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <title>\(name)</title>
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #000; touch-action: none; }
        #canvas { display: block; width: 100%; height: 100%; outline: none; }
        #status { position: fixed; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center;
                  color: #cfc8ff; font: 15px -apple-system, sans-serif; text-align: center; padding: 24px; white-space: pre-line; }
        #bar { width: 60%; max-width: 320px; height: 6px; border-radius: 3px; background: #2a2340; margin-top: 14px; overflow: hidden; }
        #fill { width: 0; height: 100%; background: linear-gradient(90deg, #7350f2, #9e7aff); transition: width .2s; }
        </style></head>
        <body>
        <canvas id="canvas" tabindex="0">Your browser can't show this game.</canvas>
        <div id="status"><div id="text">Starting Godot…</div><div id="bar"><div id="fill"></div></div></div>
        <script src="/__godot/godot.js"></script>
        <script>
        (function () {
            var status = document.getElementById('status');
            var text = document.getElementById('text');
            var fill = document.getElementById('fill');
            function fail(err) {
                var message = err && err.message ? err.message : String(err);
                console.error('Godot could not start: ' + message);
                text.textContent = 'Godot could not start:\\n' + message + '\\n\\nThe game log (gear > Game Log) shows what Godot printed.';
                fill.parentNode.style.display = 'none';
                status.style.display = 'flex';
            }
            try {
                var canvas = document.getElementById('canvas');
                var engine = new Engine({
                    canvas: canvas,
                    executable: '/__godot/godot',
                    mainPack: \(pack),
                    args: \(argList),
                    canvasResizePolicy: 2,
                    focusCanvas: true,
                    ensureCrossOriginIsolationHeaders: false,
                    serviceWorker: '',
                    experimentalVK: false,
                    gdextensionLibs: [],
                    fileSizes: {},
                    onPrint: function () { console.log('godot: ' + Array.prototype.join.call(arguments, ' ')); },
                    onPrintError: function () { console.error('godot: ' + Array.prototype.join.call(arguments, ' ')); }
                });
                if (typeof Engine.getMissingFeatures === 'function') {
                    var missing = Engine.getMissingFeatures({ threads: \(threads ? "true" : "false") });
                    if (missing && missing.length) { fail('Missing browser features: ' + missing.join(', ')); return; }
                }
                text.textContent = 'Loading…';
                var preloads = \(preloadList);
                var ready = Promise.all(preloads.map(function (p) {
                    if (typeof engine.preloadFile !== 'function') { return null; }
                    return Promise.resolve(engine.preloadFile(p[0], p[1])).then(function () {
                        console.log('godot: loaded ' + decodeURIComponent(p[0]) + ' as ' + decodeURIComponent(p[1]));
                    }, function (e) {
                        console.log('godot: could not load ' + decodeURIComponent(p[0]) + ': ' + (e && e.message ? e.message : e));
                    });
                }));
                ready.then(function () {
                    return engine.startGame({
                        onProgress: function (current, total) {
                            if (total > 0) {
                                var p = Math.min(100, Math.floor(current * 100 / total));
                                fill.style.width = p + '%';
                                text.textContent = 'Loading… ' + p + '%';
                            }
                        }
                    });
                }).then(function () {
                    status.style.display = 'none';
                    canvas.focus();
                }, fail);
            } catch (err) {
                fail(err);
            }
        })();
        </script>
        </body></html>
        """
        return Data(html.utf8)
    }
}

/// Reads little-endian numbers from a file through a 1 MB window (pack directories can hold thousands of entries).
private final class PackReader {
    private let handle: FileHandle
    private let size: UInt64
    private var buffer = Data()
    private var start: UInt64 = 0

    init(handle: FileHandle, size: UInt64) {
        self.handle = handle
        self.size = size
    }

    private func bytes(at offset: UInt64, count: Int) -> Data? {
        let end = offset + UInt64(count)
        guard end <= size else { return nil }
        if offset < start || end > start + UInt64(buffer.count) {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: max(count, 1 << 20)) else { return nil }
            buffer = Data(data)
            start = offset
        }
        guard end <= start + UInt64(buffer.count) else { return nil }
        let from = Int(offset - start)
        return buffer.subdata(in: from..<from + count)
    }

    func u32(at offset: UInt64) -> UInt32? {
        bytes(at: offset, count: 4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    }

    func u64(at offset: UInt64) -> UInt64? {
        bytes(at: offset, count: 8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
    }

    /// Raw bytes (read directly when larger than the window).
    func data(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count <= (1 << 20) { return bytes(at: offset, count: count) }
        guard offset + UInt64(count) <= size, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }
}

extension Game {
    /// A desktop Godot game: its entry is the .pck the web runtime loads.
    var isGodotDesktop: Bool {
        engine == .godot && entry.lowercased().hasSuffix(".pck")
    }
}
