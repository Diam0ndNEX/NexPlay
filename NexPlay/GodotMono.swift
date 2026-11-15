import CryptoKit
import Foundation

// 8.7.16: Godot 3 C# (Mono) games on Godot's own C# web runtime (Godot Engine, MIT license).
//
// A desktop C# export keeps its compiled C# next to the executable (data_<name>/Assemblies: the game's .dll,
// GodotSharp.dll, extra libraries) and loads the .NET class libraries from data_<name>/Mono. A web export instead
// carries everything inside the .pck under res://.mono/assemblies/Release/ (Godot 3's ExportPlugin.cs:
// assembliesInsidePck; godotsharp_dirs.cpp: res_assemblies_dir; gd_mono_assembly.cpp searches it).
// So before the first start this copies into the game's .pck, under that folder:
//   - the web runtime's class libraries and its own GodotSharp.dll (NexPlay.app/GodotRuntimes/godotmono-<v>.zip,
//     built by tools/fetch_godot_runtimes.py; GodotSharp.dll must match the engine or Godot calls it out of sync),
//   - the game's own assemblies (everything in data_*/Assemblies except GodotSharp*.dll).
// The compiled C# itself doesn't depend on Windows. The rest of the pack is copied unchanged (Godot 3 packs are
// format 1: absolute offsets, so every entry gets a new offset). A marker beside the pack records what went in, so
// the work is done once per runtime.

enum GodotMono {
    static let releaseFolder = "res://.mono/assemblies/Release/"

    enum MonoError: LocalizedError {
        case noAssemblies
        case notGodot3
        case badPack(String)
        case noSpace(Int64)

        var errorDescription: String? {
            switch self {
            case .noAssemblies:
                return "This C# Godot game has no Assemblies folder (data_<name>/Assemblies) next to its .pck, so its C# code can't be found. Import the whole game folder."
            case .notGodot3:
                return "Only Godot 3 C# games can run on the C# web runtime."
            case .badPack(let why):
                return "The game's .pck couldn't be prepared for C#: \(why)"
            case .noSpace(let needed):
                return "Not enough free space to prepare this C# game (about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed)."
            }
        }
    }

    /// The folder with the game's compiled C# (data_<name>/Assemblies on Windows/Linux, GodotSharp/Assemblies in a
    /// Mac app): looked for beside the pack, then anywhere in the game folder up to three levels down.
    static func gameAssemblies(pack: URL, root: URL?) -> URL? {
        let fm = FileManager.default
        var starts = [pack.deletingLastPathComponent()]
        if let root, root.standardizedFileURL != starts[0].standardizedFileURL { starts.append(root) }
        // 8.8.3: the folder that holds GodotSharp.dll is the game's Assemblies folder whatever it is called or where it
        // is (the 8.8.1 name check found nothing for Project Kat).
        for start in starts {
            guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            var named: URL?
            for case let url as URL in walker {
                if walker.level > 6 { walker.skipDescendants(); continue }
                let name = url.lastPathComponent.lowercased()
                if name == "godotsharp.dll" { return url.deletingLastPathComponent() }
                if named == nil, name == "assemblies",
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
                    if parent.hasPrefix("data_") || parent == "godotsharp" { named = url }
                }
            }
            if let named { return named }
        }
        return nil
    }

    /// For the log when no compiled C# was found: the game's folders (four levels) with their .dll counts.
    static func folderSummary(pack: URL, root: URL?) -> String {
        let fm = FileManager.default
        let start = root ?? pack.deletingLastPathComponent()
        guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return "unreadable" }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let rel = "/" + GameScanner.relativePath(of: url, in: start)
            if isDir {
                if counts[rel] == nil { counts[rel] = 0; order.append(rel) }
            } else if url.pathExtension.lowercased() == "dll" {
                let parent = (rel as NSString).deletingLastPathComponent
                counts[parent, default: 0] += 1
            }
        }
        return order.prefix(40).map { "\($0)/ (\(counts[$0] ?? 0) dll)" }.joined(separator: ", ")
    }

    /// One file to put into the pack.
    private struct Addition {
        let name: String
        let url: URL
        let size: UInt64
    }

    /// A directory entry of a format 1 pack.
    private struct Entry {
        let nameData: Data
        let name: String
        let offset: UInt64
        let size: UInt64
        let md5: Data
    }

    /// Puts the runtime's and the game's assemblies into the pack (once per runtime). Returns lines for the game
    /// log. Synchronous file work: call it from a background task.
    static func prepare(pack: URL, root: URL?, runtimeFolder: URL, runtime: GodotVersion) throws -> [String] {
        let fm = FileManager.default
        // 8.9.0: no assemblies folder = the game's C# is inside the pack itself (Project Kat's .exe carries a pack with
        // res://.mono/assemblies/Release/Lacie Engine.dll and the desktop class libraries): "embedded" mode.
        let gameFolder = gameAssemblies(pack: pack, root: root)
        let embedded = gameFolder == nil
        // The runtime's files first (class libraries for the web, GodotSharp.dll for this engine), then the game's.
        var byName: [String: Addition] = [:]
        var order: [String] = []
        var fromRuntime = 0
        var fromGame = 0
        func add(_ url: URL) -> Bool {
            let file = url.lastPathComponent
            let key = file.lowercased()
            guard key.hasSuffix(".dll"), byName[key] == nil else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { return false }
            byName[key] = Addition(name: releaseFolder + file, url: url, size: UInt64(size))
            order.append(key)
            return true
        }
        let runtimeAssemblies = runtimeFolder.appendingPathComponent("assemblies", isDirectory: true)
        for url in ((try? fm.contentsOfDirectory(at: runtimeAssemblies, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where add(url) {
            fromRuntime += 1
        }
        guard byName["mscorlib.dll"] != nil, byName["godotsharp.dll"] != nil else {
            throw MonoError.badPack("the Godot \(runtime) C# runtime in this build is incomplete")
        }
        if let gameFolder {
            for url in ((try? fm.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if url.lastPathComponent.lowercased().hasPrefix("godotsharp") { continue }
                if add(url) { fromGame += 1 }
            }
            guard fromGame > 0 else { throw MonoError.noAssemblies }
        }
        let additions = order.compactMap { byName[$0] }

        // Done before with the same files?
        let marker = pack.deletingLastPathComponent().appendingPathComponent("." + pack.lastPathComponent + ".nexmono")
        let stamp = (["runtime \(runtime)" + (embedded ? " embedded" : "")] + additions.map { "\($0.name) \($0.size)" }).joined(separator: "\n")
        if let old = try? String(contentsOf: marker, encoding: .utf8), old == stamp {
            return ["C# files already in the pack for the Godot \(runtime) C# runtime (\(additions.count) files)"]
        }

        guard let head = GodotRuntime.header(pack) else { throw MonoError.badPack("not a Godot pack") }
        guard head.format <= 1, head.version.major == 3 else { throw MonoError.notGodot3 }
        guard let handle = try? FileHandle(forReadingFrom: pack) else { throw MonoError.badPack("can't open it") }
        defer { try? handle.close() }
        let reader = PackReader(handle: handle, size: head.size)
        guard let headerBytes = reader.data(at: 0, count: 84), let count = reader.u32(at: 84), count < 2_000_000 else {
            throw MonoError.badPack("unreadable directory")
        }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var position: UInt64 = 88
        for _ in 0..<count {
            guard let length = reader.u32(at: position), length < 65_536,
                  let nameData = reader.data(at: position + 4, count: Int(length)) else {
                throw MonoError.badPack("unreadable directory")
            }
            position += 4 + UInt64(length)
            guard let offset = reader.u64(at: position), let size = reader.u64(at: position + 8),
                  let md5 = reader.data(at: position + 16, count: 16) else {
                throw MonoError.badPack("unreadable directory")
            }
            position += 32
            guard offset <= head.size, size <= head.size - offset else {
                throw MonoError.badPack("a file lies outside the pack (an offset not fixed after unpacking it from the .exe)")
            }
            let name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
            entries.append(Entry(nameData: nameData, name: name, offset: offset, size: size, md5: md5))
        }
        // Earlier C# files (another runtime) are replaced. Embedded mode keeps the game's own assemblies (Lacie Engine.dll,
        // Karambolo.PO.dll, Newtonsoft.Json.dll...) and drops the desktop class libraries, GodotSharp and the .pdb files:
        // the runtime brings the web versions of those.
        func isFramework(_ file: String) -> Bool {
            ["system.", "mono.", "i18n", "accessibility", "mscorlib", "netstandard", "novell.", "godotsharp"].contains { file.hasPrefix($0) }
        }
        let assembliesPrefix = "res://.mono/assemblies/"
        let kept = entries.filter { entry in
            let lower = entry.name.lowercased()
            guard lower.hasPrefix(assembliesPrefix) else { return true }
            guard embedded else { return false }
            let file = (lower as NSString).lastPathComponent
            return file.hasSuffix(".dll") && byName[file] == nil && !isFramework(file)
        }
        let embeddedGame = kept.filter { $0.name.lowercased().hasPrefix(assembliesPrefix) }
        if embedded {
            guard !embeddedGame.isEmpty else { throw MonoError.noAssemblies }
            fromGame = embeddedGame.count
        }

        var newNames: [Data] = []
        for addition in additions {
            var data = Data(addition.name.utf8)
            let pad = (4 - data.count % 4) % 4
            data.append(Data(repeating: 0, count: pad))
            newNames.append(data)
        }
        var directorySize: UInt64 = 0
        for entry in kept { directorySize += 4 + UInt64(entry.nameData.count) + 32 }
        for name in newNames { directorySize += 4 + UInt64(name.count) + 32 }
        let dataStart: UInt64 = 88 + directorySize
        let total = dataStart + kept.reduce(0) { $0 + $1.size } + additions.reduce(0) { $0 + $1.size }

        let folder = pack.deletingLastPathComponent()
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < Int64(total) + 64_000_000 {
            throw MonoError.noSpace(Int64(total) + 64_000_000)
        }

        let temp = folder.appendingPathComponent("." + pack.lastPathComponent + ".nexmono-\(UUID().uuidString)")
        fm.createFile(atPath: temp.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var directory = Data()
            directory.append(headerBytes)
            appendU32(&directory, UInt32(kept.count + additions.count))
            var cursor = dataStart
            for entry in kept {
                appendU32(&directory, UInt32(entry.nameData.count))
                directory.append(entry.nameData)
                appendU64(&directory, cursor)
                appendU64(&directory, entry.size)
                directory.append(entry.md5)
                cursor += entry.size
            }
            var digests: [Data] = []
            for addition in additions {
                let bytes = try Data(contentsOf: addition.url)
                digests.append(Data(Insecure.MD5.hash(data: bytes)))
            }
            for (index, addition) in additions.enumerated() {
                appendU32(&directory, UInt32(newNames[index].count))
                directory.append(newNames[index])
                appendU64(&directory, cursor)
                appendU64(&directory, addition.size)
                directory.append(digests[index])
                cursor += addition.size
            }
            guard UInt64(directory.count) == dataStart else { throw MonoError.badPack("directory size mismatch") }
            try output.write(contentsOf: directory)
            for entry in kept {
                try handle.seek(toOffset: entry.offset)
                var remaining = entry.size
                while remaining > 0 {
                    let chunk = Int(min(remaining, 4 << 20))
                    guard let data = try handle.read(upToCount: chunk), !data.isEmpty else {
                        throw MonoError.badPack("the pack ended early")
                    }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
            }
            for addition in additions {
                let bytes = try Data(contentsOf: addition.url)
                try output.write(contentsOf: bytes)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        _ = try fm.replaceItemAt(pack, withItemAt: temp)
        try? stamp.write(to: marker, atomically: true, encoding: .utf8)
        let source = gameFolder.map { "\($0.deletingLastPathComponent().lastPathComponent)/Assemblies" } ?? "the pack itself"
        return ["C# files put into the pack for the Godot \(runtime) C# runtime: \(fromGame) from the game (\(source)), \(fromRuntime) from the runtime; \(entries.count - kept.count + embeddedGame.count) earlier ones replaced"]
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 4))
    }

    private static func appendU64(_ data: inout Data, _ value: UInt64) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 8))
    }
}
