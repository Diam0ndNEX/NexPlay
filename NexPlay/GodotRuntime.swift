import Foundation
import ZIPFoundation

// Desktop Godot games (.pck, or a .exe / .x86_64 with the .pck embedded) run on Godot's own web runtime: the
// official web export template of the same major.minor version, bundled in NexPlay.app/GodotRuntimes by
// tools/fetch_godot_runtimes.py at build time (Godot Engine, MIT license, https://godotengine.org/license).
// The runtime loads the game's .pck with `--main-pack`, exactly as a web export does with its own .pck.
// Pack layout (header: "GDPC", format version, major, minor, patch; embedded: ...pck, u64 size, "GDPC" at the end)
// follows Godot's core/io/file_access_pack.cpp.

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

enum GodotRuntime {
    private static let magic: UInt32 = 0x4350_4447 // "GDPC" little-endian

    // MARK: - Packs

    /// The engine version a .pck was exported with, or nil when the file is not a Godot pack (or is encrypted
    /// in a way that hides the header).
    static func packVersion(_ url: URL) -> GodotVersion? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 20), data.count == 20 else { return nil }
        func word(_ index: Int) -> UInt32 {
            data.subdata(in: index * 4..<(index + 1) * 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        guard word(0) == magic else { return nil }
        let major = Int(word(2)), minor = Int(word(3)), patch = Int(word(4))
        guard (3...9).contains(major), minor < 100, patch < 100 else { return nil }
        return GodotVersion(major: major, minor: minor, patch: patch)
    }

    /// Where a pack embedded at the end of an executable starts and how long it is.
    static func embeddedPack(in url: URL) -> (offset: UInt64, length: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 32 else { return nil }
        guard (try? handle.seek(toOffset: size - 12)) != nil,
              let tail = try? handle.read(upToCount: 12), tail.count == 12 else { return nil }
        let length = tail.subdata(in: 0..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let end = tail.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
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
                    guard ["exe", "x86_64", "x86_32", "arm64", ""].contains(ext) else { continue }
                    let base = kid.deletingPathExtension().lastPathComponent
                    if names.contains(base.lowercased() + ".pck") { continue }
                    guard let pack = embeddedPack(in: kid) else { continue }
                    try cancel?.check()
                    cancel?.report(.scanning, "Unpacking the Godot game from \(kid.lastPathComponent)…", 0.5, force: true)
                    try copyRange(of: kid, offset: pack.offset, length: pack.length,
                                  to: dir.appendingPathComponent(base + ".pck"), cancel: cancel)
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

    /// The runtime for a pack: same major.minor (newest patch), else the oldest newer minor of the same major
    /// (Godot loads packs from older minors, never from newer ones).
    static func runtime(for pack: GodotVersion) -> GodotVersion? {
        let sameMajor = bundled.filter { $0.major == pack.major }
        if let exact = sameMajor.filter({ $0.minor == pack.minor }).max() { return exact }
        return sameMajor.filter { $0.minor > pack.minor }.min()
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

    enum RuntimeError: LocalizedError {
        case missing(String)
        case noPack
        case unknownVersion
        case noRuntime(String, [String])

        var errorDescription: String? {
            switch self {
            case .missing(let version):
                return "The Godot \(version) runtime isn't in this build of NexPlay."
            case .noPack:
                return "No Godot .pck file was found in this game."
            case .unknownVersion:
                return "The game's .pck doesn't say which Godot version made it (it may be encrypted)."
            case .noRuntime(let version, let have):
                return "This game was made with Godot \(version), and this build of NexPlay has runtimes for \(have.joined(separator: ", ")). Packs from a newer Godot than the newest runtime can't load."
            }
        }
    }

    // MARK: - Launcher

    /// The page that starts a desktop game on the web runtime. Paths are URL paths on the local server.
    static func launcherPage(packPath: String, title: String, threads: Bool) -> Data {
        let pack = PageScripts.jsString("/" + packPath)
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
                text.textContent = 'Godot could not start:\\n' + message;
                fill.parentNode.style.display = 'none';
                status.style.display = 'flex';
            }
            try {
                var canvas = document.getElementById('canvas');
                var engine = new Engine({
                    canvas: canvas,
                    executable: '/__godot/godot',
                    mainPack: \(pack),
                    args: [],
                    canvasResizePolicy: 2,
                    focusCanvas: true,
                    ensureCrossOriginIsolationHeaders: false,
                    serviceWorker: '',
                    experimentalVK: false,
                    gdextensionLibs: [],
                    fileSizes: {}
                });
                if (typeof Engine.getMissingFeatures === 'function') {
                    var missing = Engine.getMissingFeatures({ threads: \(threads ? "true" : "false") });
                    if (missing && missing.length) { fail('Missing browser features: ' + missing.join(', ')); return; }
                }
                text.textContent = 'Loading…';
                engine.startGame({
                    onProgress: function (current, total) {
                        if (total > 0) {
                            var p = Math.min(100, Math.floor(current * 100 / total));
                            fill.style.width = p + '%';
                            text.textContent = 'Loading… ' + p + '%';
                        }
                    }
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

extension Game {
    /// A desktop Godot game: its entry is the .pck the web runtime loads.
    var isGodotDesktop: Bool {
        engine == .godot && entry.lowercased().hasSuffix(".pck")
    }
}
