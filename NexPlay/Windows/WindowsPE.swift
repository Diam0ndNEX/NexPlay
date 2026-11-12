import Foundation

// 7.1.0: what a Windows game needs, read from its program's PE header and import table at import time, so NexPlay can
// say before Play whether the Windows runtime is likely to draw it. DXMT translates Direct3D 10/11 to Metal; other
// graphics APIs are less certain. A program that imports a DLL shipped next to it (UnityPlayer.dll, a game engine DLL)
// is judged by that DLL's imports too.

/// The result of a PE scan, kept on the game (`Game.windowsInfo`).
struct WindowsInfo: Codable, Hashable {
    /// 32 or 64; 0 when unknown.
    var bits: Int
    /// The graphics API the game uses: "Direct3D 12", "Direct3D 11", "Direct3D 10", "Direct3D 9", "Direct3D 8",
    /// "Vulkan", "OpenGL", "DirectDraw", "GDI" or "Unknown".
    var api: String
    /// A .NET program (CLR header).
    var dotNet: Bool
    /// An engine recognised from the folder (Unity, Godot, GameMaker, Unreal, RPG Maker 2000/2003, ...), or nil.
    var engine: String?

    enum Outlook: String { case likely, uncertain, unlikely }

    var outlook: Outlook {
        switch api {
        case "Direct3D 11", "Direct3D 10": return .likely
        case "DirectDraw", "GDI", "Direct3D 8": return .unlikely
        default: return .uncertain
        }
    }

    /// "Should work (Direct3D 11, 64-bit)" and the like.
    var summary: String {
        var parts = [api]
        if bits != 0 { parts.append("\(bits)-bit") }
        if dotNet { parts.append(".NET") }
        if let engine { parts.insert(engine, at: 0) }
        let detail = parts.joined(separator: ", ")
        switch outlook {
        case .likely: return "Should work (\(detail))"
        case .uncertain: return "Uncertain (\(detail))"
        case .unlikely: return "Unlikely (\(detail))"
        }
    }
}

enum WindowsPE {
    struct Header {
        var bits = 0
        var imports: [String] = []
        var dotNet = false
    }

    /// Reads the PE header, import names and CLR flag of one program or DLL. Nil when it isn't a PE file.
    static func read(_ url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func bytes(_ offset: UInt64, _ count: Int) -> Data {
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: count) ?? Data()
            } catch { return Data() }
        }
        func u16(_ data: Data, _ at: Int) -> Int {
            guard at >= 0, at + 2 <= data.count else { return 0 }
            return Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8
        }
        func u32(_ data: Data, _ at: Int) -> Int { u16(data, at) | u16(data, at + 2) << 16 }

        let dos = bytes(0, 64)
        guard dos.count == 64, dos[dos.startIndex] == 0x4d, dos[dos.startIndex + 1] == 0x5a else { return nil }
        let peOffset = u32(dos, 60)
        guard peOffset > 0, peOffset < 16 << 20 else { return nil }
        let head = bytes(UInt64(peOffset), 24 + 240)
        guard head.count >= 24 + 96, u32(head, 0) == 0x4550 else { return nil }
        let sections = u16(head, 6)
        let optionalSize = u16(head, 20)
        let optional = 24
        let magic = u16(head, optional)
        var result = Header()
        let directories: Int
        switch magic {
        case 0x10b: result.bits = 32; directories = optional + 96
        case 0x20b: result.bits = 64; directories = optional + 112
        default: return result
        }
        func directory(_ index: Int) -> (rva: Int, size: Int) {
            (u32(head, directories + index * 8), u32(head, directories + index * 8 + 4))
        }
        let table = bytes(UInt64(peOffset + 24 + optionalSize), min(sections, 96) * 40)
        func fileOffset(_ rva: Int) -> Int? {
            for i in 0..<min(sections, 96) {
                let base = i * 40
                let virtualAddress = u32(table, base + 12)
                let size = max(u32(table, base + 8), u32(table, base + 16))
                let raw = u32(table, base + 20)
                if rva >= virtualAddress, rva < virtualAddress + size { return rva - virtualAddress + raw }
            }
            return nil
        }
        result.dotNet = directory(14).rva != 0
        let imports = directory(1)
        if imports.rva != 0, let start = fileOffset(imports.rva) {
            let descriptors = bytes(UInt64(start), min(max(imports.size, 20), 20 * 512))
            var at = 0
            while at + 20 <= descriptors.count {
                let nameRVA = u32(descriptors, at + 12)
                if nameRVA == 0 { break }
                if let nameOffset = fileOffset(nameRVA) {
                    let raw = bytes(UInt64(nameOffset), 128)
                    let end = raw.firstIndex(of: 0) ?? raw.endIndex
                    if let name = String(data: raw[raw.startIndex..<end], encoding: .ascii), !name.isEmpty {
                        result.imports.append(name.lowercased())
                    }
                }
                at += 20
            }
        }
        return result
    }

    /// Scans a game's program (and DLLs it imports from its own folder) and its folder.
    static func inspect(program: String, in root: URL) -> WindowsInfo? {
        let exe = root.appendingPathComponent(program)
        guard let main = read(exe) else { return nil }
        var imports = Set(main.imports)
        var dotNet = main.dotNet
        let folder = exe.deletingLastPathComponent()
        let local = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var byName: [String: String] = [:]
        for name in local { byName[name.lowercased()] = name }
        for dll in main.imports {
            guard let name = byName[dll], let sub = read(folder.appendingPathComponent(name)) else { continue }
            imports.formUnion(sub.imports)
            dotNet = dotNet || sub.dotNet
        }
        let names = Set(local.map { $0.lowercased() })
        return WindowsInfo(bits: main.bits, api: api(imports), dotNet: dotNet, engine: engine(names: names, folder: folder))
    }

    private static func api(_ imports: Set<String>) -> String {
        if imports.contains("d3d12.dll") { return "Direct3D 12" }
        if imports.contains("d3d11.dll") || imports.contains("dxgi.dll") { return "Direct3D 11" }
        if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") { return "Direct3D 10" }
        if imports.contains("d3d9.dll") { return "Direct3D 9" }
        if imports.contains("vulkan-1.dll") { return "Vulkan" }
        if imports.contains("opengl32.dll") { return "OpenGL" }
        if imports.contains("d3d8.dll") { return "Direct3D 8" }
        if imports.contains("ddraw.dll") { return "DirectDraw" }
        if imports.contains("gdi32.dll") && imports.contains("user32.dll") { return "GDI" }
        return "Unknown"
    }

    private static func engine(names: Set<String>, folder: URL) -> String? {
        if names.contains("unityplayer.dll") || names.contains(where: { $0.hasSuffix("_data") }) { return "Unity" }
        if names.contains(where: { $0.hasSuffix(".pck") }) { return "Godot" }
        if names.contains("data.win") { return "GameMaker" }
        if names.contains("engine") && names.contains(where: { $0 == "binaries" || $0.hasSuffix(".uproject") }) { return "Unreal" }
        if names.contains("rpg_rt.exe") || names.contains("rpg_rt.ldb") { return "RPG Maker 2000/2003" }
        if names.contains("game.ini") && names.contains(where: { $0.hasPrefix("game.rgss") }) { return "RPG Maker XP/VX/Ace" }
        if names.contains("nw.dll") || names.contains("nw_elf.dll") { return "NW.js" }
        if names.contains(where: { $0.hasSuffix(".wolf") }) || names.contains("data.wolf") { return "WOLF RPG" }
        if names.contains("renpy") { return "Ren'Py" }
        return nil
    }
}
