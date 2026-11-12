import Foundation
import ImageIO
import ZIPFoundation

// Ren'Py games run on RenPyWeb, Ren'Py's own WebAssembly build (MIT, https://www.renpy.org), bundled in
// NexPlay.app/RenPyRuntimes by tools/fetch_renpy_runtimes.py: renpy-<v>-web.zip (the official web runtime) and
// renpy-<v>-engine.zip (main.py + renpy/ from the official SDK, prepared like Ren'Py's "Build Web Application").
//
// At the first start NexPlay builds the game's game.zip, the file RenPyWeb downloads and unpacks into its memory:
// the engine, the game's scripts and small files, and renpyweb_remote_files.txt listing the big images, music,
// voices and videos. Those stay in the game folder and RenPyWeb fetches them while playing ("progressive download",
// renpy/webloader.py and launcher/game/web.rpy), so even multi-gigabyte games fit. Images get a 1x1 placeholder
// (_placeholders/<path>) that Ren'Py scales to the real size until the file arrives.

typealias RuntimeVersion = GodotVersion

struct RenPyLaunch {
    let gameVersion: RuntimeVersion?
    let runtime: RuntimeVersion
    /// The unpacked web runtime (index.html, renpy.js ...).
    let webFolder: URL
    let gameZip: URL
    /// The game's game/ folder, served under __renpy/game/ for files fetched while playing.
    let gameDir: URL
    let notes: [String]
}

enum RenPyRuntime {
    /// Bump when the package layout changes, so old game.zip files are rebuilt.
    private static let packageFormat = 1

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "bmp", "gif"]
    static let audioExtensions: Set<String> = ["wav", "mp2", "mp3", "ogg", "opus", "flac", "m4a", "oga"]
    static let videoExtensions: Set<String> = ["webm", "ogv", "mp4", "mkv", "avi", "m4v", "mov", "mpg", "mpeg"]

    // MARK: - Detection

    /// The folder that holds the game's game/ folder (with .rpy, .rpyc or .rpa files), up to three levels deep.
    static func findBase(in root: URL) -> URL? {
        let fm = FileManager.default
        var level = [root]
        for _ in 0...3 {
            var next: [URL] = []
            for dir in level {
                if isGameFolder(dir.appendingPathComponent("game")) { return dir }
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                next += kids.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        && $0.lastPathComponent.lowercased() != "__macosx"
                }
            }
            level = next
        }
        return nil
    }

    /// A Ren'Py game/ folder: it holds scripts or archives (directly or one folder down).
    static func isGameFolder(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let wanted: Set<String> = ["rpy", "rpyc", "rpa", "rpi", "rpym", "rpymc"]
        var level = [dir]
        for _ in 0...1 {
            var next: [URL] = []
            for folder in level {
                let kids = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    if wanted.contains(kid.pathExtension.lowercased()) { return true }
                    if kid.lastPathComponent == "script_version.txt" { return true }
                    if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(kid) }
                }
            }
            level = next
        }
        return false
    }

    /// The game's name: config.name in options.rpy, else the name of its .exe or launcher .py, else the folder.
    static func title(base: URL) -> String? {
        let options = base.appendingPathComponent("game/options.rpy")
        if let text = ImportPipeline.readText(options),
           let regex = try? NSRegularExpression(pattern: #"config\.name\s*=\s*_?\(?\s*u?["'](.+?)["']"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let name = text[range].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let skip: Set<String> = ["renpy", "python", "pythonw", "zsync", "zsyncmake", "uninstall"]
        if let exe = names.first(where: { $0.lowercased().hasSuffix(".exe") && !skip.contains(($0 as NSString).deletingPathExtension.lowercased()) }) {
            return (exe as NSString).deletingPathExtension
        }
        if let script = names.first(where: { $0.lowercased().hasSuffix(".py") && !skip.contains(($0 as NSString).deletingPathExtension.lowercased()) }) {
            return (script as NSString).deletingPathExtension
        }
        return nil
    }

    /// The Ren'Py version the game was built with, from renpy/vc_version.py, renpy/__init__.py, the compiled
    /// version file, or the lib/ folder names (py3-* is Ren'Py 8, py2-* and python2.7 are Ren'Py 7).
    static func gameVersion(base: URL) -> RuntimeVersion? {
        let renpy = base.appendingPathComponent("renpy")
        let patterns = [
            #"version\s*=\s*u?["'](\d+)\.(\d+)\.(\d+)"#,
            #"version_tuple\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#,
        ]
        for file in ["vc_version.py", "__init__.py"] {
            guard let text = ImportPipeline.readText(renpy.appendingPathComponent(file)) else { continue }
            for pattern in patterns {
                if let version = firstVersion(in: text, pattern: pattern) { return version }
            }
        }
        // Compiled files keep the version string as plain bytes.
        let fm = FileManager.default
        var compiled: [URL] = []
        for name in ["vc_version.pyc", "vc_version.pyo"] { compiled.append(renpy.appendingPathComponent(name)) }
        let cache = renpy.appendingPathComponent("__pycache__")
        for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where name.hasPrefix("vc_version.") {
            compiled.append(cache.appendingPathComponent(name))
        }
        for url in compiled {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if let version = firstVersion(in: text, pattern: #"([6-9])\.(\d{1,2})\.(\d{1,2})\.\d{4,}"#) { return version }
        }
        let lib = (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("lib").path)) ?? []
        if lib.contains(where: { $0.hasPrefix("py3-") || $0.hasPrefix("python3") }) { return RuntimeVersion(major: 8, minor: 0, patch: 0) }
        if lib.contains(where: { $0.hasPrefix("py2-") || $0.hasPrefix("python2") }) { return RuntimeVersion(major: 7, minor: 0, patch: 0) }
        if lib.contains(where: { $0.hasPrefix("windows-") || $0.hasPrefix("linux-") || $0.hasPrefix("darwin-") }) {
            return RuntimeVersion(major: 7, minor: 0, patch: 0)
        }
        return nil
    }

    private static func firstVersion(in text: String, pattern: String) -> RuntimeVersion? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 4 else { return nil }
        var numbers: [Int] = []
        for index in 1...3 {
            guard let range = Range(match.range(at: index), in: text), let value = Int(text[range]) else { return nil }
            numbers.append(value)
        }
        guard (5...9).contains(numbers[0]) else { return nil }
        return RuntimeVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    // MARK: - Runtimes

    private static var bundleFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("RenPyRuntimes")
    }

    /// Versions bundled in the app (both the web runtime and the engine are present).
    static var bundled: [RuntimeVersion] {
        guard let folder = bundleFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let set = Set(names)
        return names.compactMap { name -> RuntimeVersion? in
            guard name.hasPrefix("renpy-"), name.hasSuffix("-web.zip") else { return nil }
            let text = String(name.dropFirst(6).dropLast(8))
            guard set.contains("renpy-\(text)-engine.zip") else { return nil }
            return RuntimeVersion(text)
        }
        .sorted()
    }

    /// The runtime for a game: Ren'Py 6/7 games run on the newest 7.x, 8.0-8.3 on the newest 8.0-8.3 runtime,
    /// 8.4 and later on the newest 8.x. A version picked in Game Settings wins when it is bundled.
    static func runtime(for version: RuntimeVersion?, override chosen: String?) -> RuntimeVersion? {
        let have = bundled
        if let chosen, let wanted = RuntimeVersion(chosen), have.contains(wanted) { return wanted }
        let sevens = have.filter { $0.major <= 7 }
        let eights = have.filter { $0.major >= 8 }
        guard let version else { return eights.filter { $0.minor <= 3 }.max() ?? eights.max() ?? sevens.max() }
        if version.major <= 7 { return sevens.max() ?? eights.min() }
        if version.minor <= 3 {
            return eights.filter { $0.minor <= 3 }.max() ?? eights.min()
        }
        return eights.max()
    }

    /// Unpacks a bundled web runtime into Application Support/NexPlay/RenPyRuntimes/<v>/ once and returns the folder
    /// that holds its index.html.
    static func prepareWeb(_ version: RuntimeVersion) throws -> URL {
        let fm = FileManager.default
        let root = Paths.support.appendingPathComponent("RenPyRuntimes/\(version)", isDirectory: true)
        if let found = indexFolder(in: root) { return found }
        guard let zip = bundleFolder?.appendingPathComponent("renpy-\(version)-web.zip"),
              fm.fileExists(atPath: zip.path) else { throw RenPyError.missing(version.description) }
        let temp = root.deletingLastPathComponent().appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: temp)
        try? fm.removeItem(at: root)
        try fm.moveItem(at: temp, to: root)
        guard let found = indexFolder(in: root) else { throw RenPyError.missing(version.description) }
        return found
    }

    private static func indexFolder(in root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("index.html").path) { return root }
        let kids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for kid in kids where fm.fileExists(atPath: kid.appendingPathComponent("index.html").path) { return kid }
        return nil
    }

    /// The bundled engine ZIP, unpacked once into Application Support/NexPlay/RenPyRuntimes/<v>-engine/.
    static func prepareEngine(_ version: RuntimeVersion) throws -> URL {
        let fm = FileManager.default
        let folder = Paths.support.appendingPathComponent("RenPyRuntimes/\(version)-engine", isDirectory: true)
        if fm.fileExists(atPath: folder.appendingPathComponent("main.py").path) { return folder }
        guard let zip = bundleFolder?.appendingPathComponent("renpy-\(version)-engine.zip"),
              fm.fileExists(atPath: zip.path) else { throw RenPyError.missing(version.description) }
        let temp = folder.deletingLastPathComponent().appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: temp)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: temp, to: folder)
        return folder
    }

    enum RenPyError: LocalizedError {
        case missing(String)
        case noRuntime
        case noGameFolder

        var errorDescription: String? {
            switch self {
            case .missing(let version):
                return "The Ren'Py \(version) runtime isn't in this build of NexPlay."
            case .noRuntime:
                return "This build of NexPlay has no Ren'Py runtime. Build it again with network access in GitHub Actions."
            case .noGameFolder:
                return "The game's game/ folder is missing."
            }
        }
    }

    // MARK: - Launch

    /// The game's base folder (the one with game/ in it).
    static func baseFolder(for game: Game) -> URL {
        Paths.entryDirectory(for: game)
    }

    /// Everything the player needs: the runtime, its web folder and the game's game.zip (built or reused).
    /// Synchronous file work: call it from a background task. `progress` gets short status lines.
    static func launch(game: Game, progress: @escaping (String) -> Void) throws -> RenPyLaunch {
        let base = baseFolder(for: game)
        let gameDir = base.appendingPathComponent("game", isDirectory: true)
        guard FileManager.default.fileExists(atPath: gameDir.path) else { throw RenPyError.noGameFolder }
        let version = gameVersion(base: base)
        guard let picked = RenPyRuntime.runtime(for: version, override: game.runtimeVersion) else { throw RenPyError.noRuntime }
        var notes: [String] = []
        notes.append("game made with Ren'Py \(version?.description ?? "unknown version"), running on Ren'Py \(picked) (web)")
        if let version, version.major == 8, picked.major == 7 { notes.append("warning: a Ren'Py 8 game on a Ren'Py 7 runtime will not start") }
        if let version, version.major <= 7, picked.major >= 8 { notes.append("warning: a Ren'Py 7 game on a Ren'Py 8 runtime will most likely not start") }
        progress("Preparing Ren'Py \(picked)…")
        let web = try prepareWeb(picked)
        let engine = try prepareEngine(picked)
        let zip = try package(game: game, gameDir: gameDir, engine: engine, runtime: picked, notes: &notes, progress: progress)
        return RenPyLaunch(gameVersion: version, runtime: picked, webFolder: web, gameZip: zip, gameDir: gameDir, notes: notes)
    }

    /// Removes a game's built package (after an update, or from Settings).
    static func clearPackage(for game: Game) {
        try? FileManager.default.removeItem(at: packageFolder(for: game))
    }

    static func packageFolder(for game: Game) -> URL {
        Paths.support.appendingPathComponent("RenPyCache/\(game.id.uuidString)", isDirectory: true)
    }

    // MARK: - Package

    private struct GameFile {
        let url: URL
        let relative: String
        let size: Int
        let date: Date
    }

    private static func listFiles(_ gameDir: URL) -> [GameFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: gameDir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [GameFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let relative = GameScanner.relativePath(of: url, in: gameDir)
            files.append(GameFile(url: url, relative: relative, size: values.fileSize ?? 0,
                                  date: values.contentModificationDate ?? Date.distantPast))
        }
        return files.sorted { $0.relative < $1.relative }
    }

    /// A short fingerprint of the game folder: when it changes, game.zip is built again.
    private static func signature(_ files: [GameFile], runtime: RuntimeVersion) -> String {
        var total = 0
        var newest = 0.0
        for file in files {
            total &+= file.size
            newest = max(newest, file.date.timeIntervalSince1970)
        }
        return "format \(packageFormat); runtime \(runtime); files \(files.count); bytes \(total); newest \(Int(newest))"
    }

    private enum Placement {
        case zip
        case skip
        case remote(String)
    }

    private static func placement(of file: GameFile) -> Placement {
        let lower = file.relative.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let ext = (lower as NSString).pathExtension
        if parts.first == "saves" || parts.first == "tmp" { return .skip }
        if parts.first == "cache" {
            return (parts.last ?? "").hasPrefix("bytecode") ? .zip : .skip
        }
        if ["log.txt", "traceback.txt", "errors.txt", "files.txt"].contains(lower) { return .skip }
        if videoExtensions.contains(ext) { return .remote("video -") }
        if audioExtensions.contains(ext) {
            if file.size <= 256 * 1024 { return .zip }
            return .remote(parts.contains(where: { $0.contains("voice") }) ? "voice -" : "music -")
        }
        if imageExtensions.contains(ext) {
            if parts.first == "gui" || file.size <= 48 * 1024 { return .zip }
            guard let size = pixelSize(file.url) else { return .zip }
            return .remote("image \(size.0),\(size.1)")
        }
        return .zip
    }

    /// Width and height from the image header (ImageIO reads only the header).
    private static func pixelSize(_ url: URL) -> (Int, Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// A 1x1 transparent PNG: the stand-in Ren'Py scales to the image's size until the real file arrives.
    private static let placeholderPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

    private static func package(game: Game, gameDir: URL, engine: URL, runtime: RuntimeVersion,
                                notes: inout [String], progress: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let folder = packageFolder(for: game)
        let zipURL = folder.appendingPathComponent("game.zip")
        let stampURL = folder.appendingPathComponent("stamp.txt")
        progress("Checking the game files…")
        let files = listFiles(gameDir)
        let stamp = signature(files, runtime: runtime)
        if fm.fileExists(atPath: zipURL.path),
           let old = try? String(contentsOf: stampURL, encoding: .utf8), old == stamp {
            notes.append("game.zip is up to date")
            return zipURL
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: stampURL)
        let temp = folder.appendingPathComponent("game.zip.part")
        let writer = try StoredZipWriter(url: temp)

        // The game first: its own files win over anything with the same name.
        var remote = ""
        var remoteCount = 0
        var zipped = 0
        var skipped = 0
        for (index, file) in files.enumerated() {
            if index % 200 == 0 { progress("Packing the game… \(index * 100 / max(files.count, 1)) %") }
            switch placement(of: file) {
            case .skip:
                skipped += 1
            case .zip:
                try writer.add(name: "game/" + file.relative, file: file.url)
                zipped += 1
            case .remote(let meta):
                remote += file.relative + "\n" + meta + "\n"
                remoteCount += 1
                if meta.hasPrefix("image") {
                    try writer.add(name: "_placeholders/" + file.relative, data: placeholderPNG)
                }
            }
        }
        try writer.add(name: "game/renpyweb_remote_files.txt", data: Data(remote.utf8))

        // Then the engine of the runtime (main.py and renpy/).
        progress("Adding the Ren'Py \(runtime) engine…")
        let engineFiles = listFiles(engine)
        for file in engineFiles {
            try writer.add(name: file.relative, file: file.url)
        }
        try writer.finish()
        try? fm.removeItem(at: zipURL)
        try fm.moveItem(at: temp, to: zipURL)
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        notes.append("built game.zip: \(zipped) game files + \(engineFiles.count) engine files, \(size / 1_048_576) MB; \(remoteCount) files load while playing; \(skipped) skipped")
        return zipURL
    }

    // MARK: - Import

    /// Unpacks .rpa archives at import, so big games don't have to fit in memory. Returns lines for the import note.
    static func prepareImport(base: URL, cancel: ImportCancel?) throws -> [String] {
        let gameDir = base.appendingPathComponent("game", isDirectory: true)
        let report = try RenPyArchive.unpackAll(in: gameDir, cancel: cancel)
        var notes: [String] = []
        if report.archives > 0 {
            notes.append("Unpacked \(report.archives) Ren'Py archive(s) (\(report.files) files) so the game loads only what it needs.")
            AppLog.log("ren'py import: unpacked \(report.archives) archive(s), \(report.files) files")
        }
        for line in report.skipped {
            notes.append("Kept \(line). It is loaded whole into memory, which can be too much for big archives.")
            AppLog.log("ren'py import: kept \(line)")
        }
        let version = gameVersion(base: base)
        if let picked = RenPyRuntime.runtime(for: version, override: nil) {
            notes.append("Ren'Py \(version?.description ?? "(version unknown)") game: it runs on the bundled Ren'Py \(picked) web runtime. The first start prepares the game and takes a little longer.")
        } else {
            notes.append(RenPyError.noRuntime.errorDescription ?? "")
        }
        if FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("python-packages").path) {
            notes.append("Ships extra Python packages: ones that need compiled (desktop) code won't work.")
        }
        return notes
    }
}
