import Foundation
import ZIPFoundation

// Import invariants (stage first, zip-slip check by path components, cancellation in every long phase, clear
// out-of-space error, no half-imported card, one atomic move into place, update in place with a swap that keeps
// saves and archives colliding files as displaced copies, crash leftovers restored before sweeping) follow
// Empo's ios/Empo/docs/import-pipeline.md, GameImporter.swift and SaveMigration.swift.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

/// What the import is doing right now, for the progress card.
enum ImportStage: String {
    case downloading, preparing, copying, extracting, scanning, installing, updating

    var title: String {
        switch self {
        case .downloading: return "Downloading"
        case .preparing: return "Preparing"
        case .copying: return "Copying Game"
        case .extracting: return "Extracting Archive"
        case .scanning: return "Finding the Game"
        case .installing: return "Installing"
        case .updating: return "Updating"
        }
    }

    var symbol: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .preparing: return "hourglass"
        case .copying: return "doc.on.doc.fill"
        case .extracting: return "archivebox.fill"
        case .scanning: return "magnifyingglass"
        case .installing: return "square.and.arrow.down.fill"
        case .updating: return "arrow.triangle.2.circlepath"
        }
    }

    /// The share of the whole import this stage covers (start, end).
    var span: (Double, Double) {
        switch self {
        case .downloading: return (0, 1)
        case .preparing: return (0, 0.02)
        case .copying, .extracting: return (0.02, 0.88)
        case .scanning: return (0.88, 0.93)
        case .installing, .updating: return (0.93, 1)
        }
    }
}

/// One progress report: the stage, a detail line (usually a file name) and how far the whole import is (0...1).
struct ImportProgress: Equatable {
    var stage: ImportStage = .preparing
    var detail: String = ""
    /// Overall fraction, nil while unknown.
    var fraction: Double?
    /// Which of several picked items this is (1-based) and how many there are.
    var item: Int = 1
    var itemCount: Int = 1
    var itemName: String = ""
}

/// A cancel flag that background import work checks. It also carries the progress callback.
final class ImportCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var progressHandler: ((ImportStage, String, Double?) -> Void)?
    private var lastReport = Date.distantPast

    /// Set once, before any work starts. Called on background threads.
    func onProgress(_ handler: @escaping (ImportStage, String, Double?) -> Void) {
        lock.lock(); progressHandler = handler; lock.unlock()
    }

    /// Reports progress inside a stage (`fraction` is 0...1 of that stage, nil when unknown). Throttled to about
    /// 15 reports a second unless `force` is set, so huge archives don't flood the main thread.
    func report(_ stage: ImportStage, _ detail: String, _ fraction: Double?, force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force && now.timeIntervalSince(lastReport) < 0.066 {
            lock.unlock()
            return
        }
        lastReport = now
        let handler = progressHandler
        lock.unlock()
        var overall: Double?
        if let fraction {
            let span = stage.span
            overall = span.0 + (span.1 - span.0) * min(max(fraction, 0), 1)
        }
        handler?(stage, detail, overall)
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func check() throws {
        if isCancelled { throw PipelineError.cancelled }
    }
}

enum PipelineError: LocalizedError {
    case cancelled
    case outOfSpace
    case unsafePath(String)
    case archive(String)
    case archiveFailed(String, String)
    case unknownType(String)
    case emptyFolder
    case desktopGodot
    case unsupportedEngine(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The import was cancelled."
        case .outOfSpace: return "Not enough free space on this iPhone. Free some space and import again."
        case .unsafePath(let path): return "The archive holds a file that would land outside the game folder (\(path)). Nothing was imported."
        case .archive(let ext):
            return "NexPlay can't open .\(ext) archives. Unpack it in the Files app (or another app) and import the folder, or make a ZIP."
        case .archiveFailed(let name, let detail):
            return "Couldn't unpack \(name) (\(detail)). The archive may be damaged, password-protected or split into parts (part1, part2…). Join or unpack it in another app and import the folder."
        case .unknownType(let ext):
            let kind = ext.isEmpty ? "This file" : "A .\(ext) file"
            return "\(kind) can't be imported. Import a ZIP, 7z or RAR archive, a game folder, or an HTML file."
        case .desktopGodot:
            return "This Godot game's .pck couldn't be read (it may be encrypted or damaged), so NexPlay can't tell which Godot version runs it."
        case .emptyFolder:
            return "The folder is empty or its files couldn't be read. If it's in iCloud Drive, long-press it in the Files app, tap Download Now, then import it again."
        case .unsupportedEngine(let reason):
            return reason
        }
    }
}

/// A game unpacked into the staging folder, not yet in the library.
struct StagedImport {
    let folder: URL
    let found: DetectedGame
    let title: String
    let warnings: [String]
    let encodingNote: String?
}

enum ImportPipeline {
    static let staging: URL = {
        let dir = Paths.support.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// At launch: puts back a game left in "old-<uuid>" by an interrupted update, then removes other leftovers.
    static func sweepStaging() {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        for kid in kids {
            let name = kid.lastPathComponent
            if name.hasPrefix("old-") {
                let id = String(name.dropFirst(4))
                let installed = Paths.games.appendingPathComponent(id, isDirectory: true)
                if !fm.fileExists(atPath: installed.path) {
                    try? fm.moveItem(at: kid, to: installed)
                    AppLog.log("restored \(id) from an interrupted update")
                    continue
                }
            }
            try? fm.removeItem(at: kid)
        }
    }

    // MARK: - Stage

    static func stage(_ url: URL, cancel: ImportCancel, status: @escaping (String) -> Void) throws -> StagedImport {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw ImportError.missing }

        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let ext = url.pathExtension.lowercased()
            var fallbackName = url.deletingPathExtension().lastPathComponent
            var encodingNote: String?

            if isDirectory.boolValue {
                fallbackName = url.lastPathComponent
                status("Copying \(url.lastPathComponent)…")
                cancel.report(.copying, "Counting files…", nil, force: true)
                let total = max(countFiles(in: url), 1)
                var copied = 0
                try copyFolder(url, to: folder, cancel: cancel, status: status, copied: &copied, total: total)
                if copied == 0 { throw PipelineError.emptyFolder }
            } else if ext == "zip" || ext == "jgp" {
                status("Unpacking \(url.lastPathComponent)…")
                cancel.report(.extracting, url.lastPathComponent, 0, force: true)
                do {
                    encodingNote = try extractZip(url, to: folder, cancel: cancel)
                } catch ImportError.unsupported(_) {
                    // A ZIP that ZIPFoundation can't open (or a renamed archive): let libarchive try.
                    try ArchiveExtractor.extract(url, to: folder, cancel: cancel, status: status)
                }
            } else if ["html", "htm", "swf"].contains(ext) {
                try mapSpace { try fm.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
            } else if ArchiveExtractor.extensions.contains(ext) {
                status("Unpacking \(url.lastPathComponent)…")
                cancel.report(.extracting, url.lastPathComponent, 0, force: true)
                try ArchiveExtractor.extract(url, to: folder, cancel: cancel, status: status)
            } else {
                throw PipelineError.unknownType(ext)
            }

            try cancel.check()
            status("Looking for the game…")
            cancel.report(.scanning, "Detecting the engine…", 0, force: true)
            GameScanner.tidy(folder)
            // Godot games that ship as one .exe carry their .pck inside it.
            try GodotRuntime.extractEmbeddedPacks(in: folder, cancel: cancel)
            guard let found = detect(in: folder) else {
                if GameScanner.isDesktopGodot(folder) { throw PipelineError.desktopGodot }
                if let reason = UnsupportedEngine.identify(folder) { throw PipelineError.unsupportedEngine(reason) }
                throw ImportError.noGame
            }
            var notes: [String] = []
            if found.engine == .renpy {
                // Big archives are unpacked so the web runtime loads only what it needs.
                let base = folder.appendingPathComponent(found.entry).deletingLastPathComponent()
                notes += try RenPyRuntime.prepareImport(base: base, cancel: cancel)
            }
            let title = gameTitle(found, in: folder) ?? fallbackName
            return StagedImport(folder: folder, found: found, title: title,
                                warnings: notes + warnings(for: found, in: folder), encodingNote: encodingNote)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Copies a picked folder file by file. Folders in iCloud Drive or another storage provider can hold files that
    /// are not downloaded yet (iCloud shows them as hidden ".name.icloud" placeholders); each file is read through
    /// NSFileCoordinator, which downloads it first.
    private static func copyFolder(_ source: URL, to target: URL, cancel: ImportCancel,
                                   status: (String) -> Void, copied: inout Int, total: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let kids = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for kid in kids {
            try cancel.check()
            var name = kid.lastPathComponent
            var item = kid
            if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 {
                name = String(name.dropFirst().dropLast(7))
                item = source.appendingPathComponent(name)
            }
            if name == ".DS_Store" || name == "__MACOSX" { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let destination = target.appendingPathComponent(name)
            if isDirectory {
                try copyFolder(item, to: destination, cancel: cancel, status: status, copied: &copied, total: total)
            } else {
                try coordinatedCopy(item, to: destination)
                copied += 1
                if copied % 50 == 0 { status("Copying… \(copied) files") }
                cancel.report(.copying, "\(name) · \(copied)/\(total)", Double(copied) / Double(total))
            }
        }
    }

    /// Counts the files in a picked folder (iCloud placeholders included) so copying can show a percentage.
    private static func countFiles(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [], errorHandler: { _, _ in true }) else { return 0 }
        var count = 0
        for case let item as URL in walker {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory { count += 1 }
        }
        return count
    }

    private static func coordinatedCopy(_ source: URL, to target: URL) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: source)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try mapSpace { try FileManager.default.copyItem(at: readable, to: target) }
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
    }

    /// Runs file work and turns "disk full" into a clear error.
    private static func mapSpace(_ work: () throws -> Void) throws {
        do {
            try work()
        } catch {
            let ns = error as NSError
            if ns.code == NSFileWriteOutOfSpaceError || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
                throw PipelineError.outOfSpace
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
                throw PipelineError.outOfSpace
            }
            throw error
        }
    }

    // MARK: - ZIP with name encoding repair

    /// Extracts a ZIP entry by entry. Names that are not UTF-8 are decoded with the encoding that fits all of them
    /// (Shift-JIS, GBK/GB18030, Big5, EUC-KR, then CP437). Every path is checked by components before writing.
    /// Returns a note when the names were re-decoded.
    static func extractZip(_ url: URL, to destination: URL, cancel: ImportCancel) throws -> String? {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ImportError.unsupported("zip")
        }
        let entries = Array(archive)
        let (encoding, label) = chooseEncoding(entries)
        let fm = FileManager.default
        var count = 0
        let total = max(entries.count, 1)
        for entry in entries {
            if count % 50 == 0 { try cancel.check() }
            count += 1
            var path = entry.path(using: encoding)
            if path.isEmpty { path = entry.path }
            path = path.replacingOccurrences(of: "\\", with: "/")
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            if parts.contains("..") || path.hasPrefix("/") { throw PipelineError.unsafePath(path) }
            if parts.first == "__MACOSX" || parts.last == ".DS_Store" { continue }
            var target = destination
            for part in parts { target.appendPathComponent(part) }
            cancel.report(.extracting, "\(parts.last ?? "") · \(count)/\(total)", Double(count) / Double(total))
            switch entry.type {
            case .directory:
                try mapSpace { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
            case .file:
                try mapSpace {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    _ = try archive.extract(entry, to: target)
                }
            case .symlink:
                continue
            }
        }
        if encoding != .utf8 {
            return "File names were decoded as \(label)."
        }
        return nil
    }

    private static func cfEncoding(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    private static func chooseEncoding(_ entries: [Entry]) -> (String.Encoding, String) {
        // Names marked UTF-8, or plain ASCII, decode as UTF-8.
        if entries.allSatisfy({ !$0.path(using: .utf8).isEmpty }) { return (.utf8, "UTF-8") }
        let candidates: [(String.Encoding, String)] = [
            (.shiftJIS, "Shift-JIS"),
            (cfEncoding(.GB_18030_2000), "GBK"),
            (cfEncoding(.big5), "Big5"),
            (cfEncoding(.EUC_KR), "EUC-KR"),
        ]
        func decodes(_ encoding: String.Encoding) -> [String]? {
            var names: [String] = []
            for entry in entries {
                let name = entry.path(using: encoding)
                if name.isEmpty { return nil }
                names.append(name)
            }
            return names
        }
        func hasKana(_ names: [String]) -> Bool {
            names.contains { $0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } }
        }
        let decoded = candidates.map { ($0.0, $0.1, decodes($0.0)) }
        // Japanese names nearly always contain kana; Chinese names never do.
        if let sjis = decoded.first, let names = sjis.2, hasKana(names) { return (sjis.0, sjis.1) }
        if decoded.count > 1, decoded[1].2 != nil { return (decoded[1].0, decoded[1].1) }
        for item in decoded where item.2 != nil { return (item.0, item.1) }
        return (cfEncoding(.dosLatinUS), "CP437")
    }

    // MARK: - Detection

    /// MV/MZ/HTML5 through GameScanner; otherwise RPG Maker XP/VX/Ace (Game.ini plus Data/Scripts or an RGSS archive).
    static func detect(in root: URL) -> DetectedGame? {
        let web = GameScanner.detect(in: root)
        if let web, web.engine.isRPGMaker || web.engine == .godot { return web }
        if let ruby = detectRuby(in: root) { return ruby }
        // Ren'Py: a folder with game/ holding scripts or archives; it runs on the bundled RenPyWeb runtime.
        if let base = RenPyRuntime.findBase(in: root) {
            let game = base.appendingPathComponent("game", isDirectory: true)
            return DetectedGame(engine: .renpy, entry: GameScanner.relativePath(of: game, in: root))
        }
        // A desktop Godot game: its .pck runs on the bundled Godot web runtime (GodotRuntime.swift).
        if let pack = GodotRuntime.mainPack(in: root), GodotRuntime.packVersion(pack) != nil {
            return DetectedGame(engine: .godot, entry: GameScanner.relativePath(of: pack, in: root))
        }
        // Flash: a .swf with no page, or with a page that only wraps the .swf.
        if let movie = FlashRuntime.mainMovie(in: root) {
            let wrapper = web.map { $0.engine == .web && FlashRuntime.pageEmbedsFlash(root.appendingPathComponent($0.entry)) } ?? true
            if wrapper { return DetectedGame(engine: .flash, entry: GameScanner.relativePath(of: movie, in: root)) }
        }
        // 7.0.0: no web, RPG Maker, Ren'Py, Godot or Flash game, but a Windows program: the Windows runtime runs it.
        // RPG Maker 2000/2003 (RPG_RT) stays unsupported until EasyRPG (7.1.0).
        if web == nil, UnsupportedEngine.isRPG2000(root) == false, let windows = WindowsGameFiles.detect(in: root) {
            return windows
        }
        return web
    }

    private static func children(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private static func find(_ name: String, in dir: URL) -> URL? {
        children(dir).first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func detectRuby(in root: URL) -> DetectedGame? {
        var level = [root]
        for _ in 0...2 {
            var next: [URL] = []
            for dir in level {
                if let ini = find("Game.ini", in: dir), let engine = rubyEngine(in: dir, ini: ini) {
                    let rel = GameScanner.relativePath(of: dir, in: root)
                    return DetectedGame(engine: engine, entry: rel.isEmpty ? ini.lastPathComponent : rel + "/" + ini.lastPathComponent)
                }
                next += children(dir).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            level = next
        }
        return nil
    }

    private static func rubyEngine(in dir: URL, ini: URL) -> GameEngine? {
        let data = find("Data", in: dir)
        func has(_ name: String, _ folder: URL?) -> Bool {
            guard let folder else { return false }
            return find(name, in: folder) != nil
        }
        if has("Scripts.rvdata2", data) || find("Game.rgss3a", in: dir) != nil { return .rpgVXAce }
        if has("Scripts.rvdata", data) || find("Game.rgss2a", in: dir) != nil { return .rpgVX }
        if has("Scripts.rxdata", data) || find("Game.rgssad", in: dir) != nil { return .rpgXP }
        let text = readText(ini) ?? ""
        if text.range(of: "RGSS3", options: .caseInsensitive) != nil { return .rpgVXAce }
        if text.range(of: "RGSS2", options: .caseInsensitive) != nil { return .rpgVX }
        if text.range(of: "RGSS1", options: .caseInsensitive) != nil { return .rpgXP }
        return nil
    }

    /// Text in UTF-8, else Shift-JIS, else CP1252 (old RPG Maker INI files are not UTF-8).
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .shiftJIS) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    static func gameTitle(_ found: DetectedGame, in root: URL) -> String? {
        if found.engine == .renpy {
            return RenPyRuntime.title(base: root.appendingPathComponent(found.entry).deletingLastPathComponent())
        }
        if found.engine == .windows {
            return WindowsGameFiles.title(for: found.entry)
        }
        if found.engine == .flash {
            let name = (found.entry as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        }
        if found.engine.isRuby {
            guard let text = readText(root.appendingPathComponent(found.entry)) else { return nil }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title=") {
                    let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    return title.isEmpty ? nil : title
                }
            }
            return nil
        }
        return GameScanner.title(for: found, in: root)
    }

    // MARK: - Warnings

    static func warnings(for found: DetectedGame, in root: URL) -> [String] {
        var notes: [String] = []
        let dir = root.appendingPathComponent(found.entry).deletingLastPathComponent()
        let names = children(dir).map { $0.lastPathComponent.lowercased() }
        switch found.engine {
        case .web, .construct, .twine, .tyrano:
            if !found.entry.lowercased().hasSuffix("index.html") {
                notes.append("No index.html: the game starts from \(found.entry).")
            }
        case .godot where found.entry.lowercased().hasSuffix(".pck"):
            let pack = root.appendingPathComponent(found.entry)
            if let head = GodotRuntime.header(pack) {
                if head.encrypted {
                    notes.append(GodotRuntime.RuntimeError.encrypted.errorDescription ?? "")
                } else if let runtime = GodotRuntime.runtime(for: head.version) {
                    notes.append("Godot \(head.version) desktop game: it runs on the bundled Godot \(runtime) web runtime. 2D GDScript games work best; some 3D textures may not show.")
                } else {
                    let have = GodotRuntime.bundled.map { $0.description }
                    notes.append(GodotRuntime.RuntimeError.noRuntime(head.version.description, have).errorDescription ?? "")
                }
            }
            if GodotRuntime.usesDotNet(root) || (GodotRuntime.inspect(pack)?.needsDotNet ?? false) {
                notes.append(GodotRuntime.RuntimeError.dotNet((GodotRuntime.header(pack)?.version.description) ?? "").errorDescription ?? "")
            }
        case .godot:
            if !names.contains(where: { $0.hasSuffix(".pck") }) {
                notes.append("No .pck file next to the page: the Godot game may not start.")
            }
            if let html = try? String(contentsOf: root.appendingPathComponent(found.entry), encoding: .utf8),
               html.contains("GDExtension") || html.contains("gdextensionLibs\":[\"") {
                notes.append("Uses GDExtension libraries: they only run if they were built for the web.")
            }
        case .rpgMV, .rpgMZ:
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("js/plugins/Greenworks.js").path)
                || names.contains("greenworks") || names.contains("steam_api.dll") {
                notes.append("Uses Steam (Greenworks): achievements and other Steam features won't work.")
            }
            if names.contains("node_modules") {
                notes.append("Ships Node.js modules: plugins that need real desktop Node.js may fail.")
            }
        case .renpy:
            break
        case .windows:
            notes.append(BCDRuntimeInfo.isPresent
                ? "Windows game: it runs on the Windows runtime (Wine, FEX, DXMT) with JIT on. It starts \(found.entry); pick another program in Game Settings if that's wrong."
                : "Windows game: this build has no Windows runtime, so it stays in your library until a build with the runtime is installed.")
        case .flash:
            if FlashRuntime.folder == nil {
                notes.append(FlashRuntime.FlashError.missing.errorDescription ?? "")
            } else {
                notes.append("Flash game: it runs on Ruffle. Most ActionScript 1/2 games work; ActionScript 3 games work in part.")
            }
        case .rpgXP, .rpgVX, .rpgVXAce:
            let hasArchive = names.contains { $0.hasPrefix("game.rgss") }
            let graphics = find("Graphics", in: dir)
            let graphicsCount = graphics.map { children($0).count } ?? 0
            if !hasArchive && graphicsCount < 3 {
                notes.append("This game probably needs the RPG Maker RTP, which NexPlay can't install. Look for a version with the RTP included.")
            }
        }
        let dlls = names.filter { $0.hasSuffix(".dll") && !$0.hasPrefix("rgss") && !$0.contains("steam") }
        if !dlls.isEmpty && !found.engine.isWebGame && found.engine != .windows {
            notes.append("Contains Windows DLLs (\(dlls.prefix(3).joined(separator: ", "))): features that need them may not work.")
        }
        return notes
    }

    // MARK: - Install

    /// Moves a staged game into Games/<uuid> in one step and returns its library entry.
    static func install(_ staged: StagedImport) throws -> Game {
        var game = Game(name: staged.title, engine: staged.found.engine, entry: staged.found.entry)
        switch staged.found.engine {
        case .web, .twine, .tyrano:
            game.orientation = staged.found.engine == .twine ? .portrait : .auto
            game.gamepad = false
        case .construct:
            game.orientation = .auto
            game.gamepad = false
        case .godot:
            game.orientation = .landscape
            game.gamepad = true
        case .renpy:
            game.orientation = .landscape
            game.gamepad = true
        case .flash:
            game.orientation = .landscape
            game.gamepad = false
        case .windows:
            game.orientation = .landscape
            game.gamepad = false
            game.exePath = staged.found.entry
            game.runtime = .windows
        case .rpgMV, .rpgMZ, .rpgXP, .rpgVX, .rpgVXAce:
            let raw = UserDefaults.standard.string(forKey: SettingsKey.newGameOrientation) ?? "landscape"
            game.orientation = OrientationMode(rawValue: raw) ?? .landscape
            game.gamepad = true
        }
        try mapSpace { try FileManager.default.moveItem(at: staged.folder, to: Paths.folder(for: game)) }
        return game
    }

    /// Replaces an installed game's files with a newer version and keeps its saves and settings.
    /// A file in the new version that sits where a save is gets archived as <name>.nex-displaced.bak.
    /// The old version is put back if anything fails.
    static func update(_ game: Game, with staged: StagedImport) throws -> Game {
        let fm = FileManager.default
        var updated = game
        updated.engine = staged.found.engine
        updated.entry = staged.found.entry

        let oldSaves = Paths.saveFolder(for: game)
        let newEntryDir = staged.folder.appendingPathComponent(staged.found.entry).deletingLastPathComponent()
        let newSaves = newEntryDir.appendingPathComponent("save", isDirectory: true)
        let saveFiles = SaveArchive.files(in: oldSaves)
        if !saveFiles.isEmpty {
            try fm.createDirectory(at: newSaves, withIntermediateDirectories: true)
            for file in saveFiles {
                let target = newSaves.appendingPathComponent(file.relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    let displaced = URL(fileURLWithPath: target.path + SaveArchive.displacedSuffix)
                    try? fm.removeItem(at: displaced)
                    try fm.moveItem(at: target, to: displaced)
                }
                try mapSpace { try fm.copyItem(at: file.url, to: target) }
            }
        }

        let installed = Paths.folder(for: game)
        let old = staging.appendingPathComponent("old-\(game.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: old)
        try fm.moveItem(at: installed, to: old)
        do {
            try fm.moveItem(at: staged.folder, to: installed)
        } catch {
            try? fm.moveItem(at: old, to: installed)
            throw error
        }
        try? fm.removeItem(at: old)
        return updated
    }
}

/// Recognizes engines NexPlay can't run, so a failed import says what the game is instead of "No game found".
enum UnsupportedEngine {
    static func isRPG2000(_ names: Set<String>) -> Bool {
        names.contains("rpg_rt.exe") || names.contains("rpg_rt.ldb") || names.contains("rpg_rt.lmt")
    }

    /// RPG Maker 2000/2003 files at the top of the folder or one level down.
    static func isRPG2000(_ root: URL) -> Bool {
        let fm = FileManager.default
        var names: Set<String> = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in top {
            names.insert(item.lastPathComponent.lowercased())
            for kid in (try? fm.contentsOfDirectory(atPath: item.path)) ?? [] { names.insert(kid.lowercased()) }
        }
        return isRPG2000(names)
    }

    static func identify(_ root: URL) -> String? {
        let fm = FileManager.default
        var names: Set<String> = []
        var extensions: Set<String> = []
        var level = [root]
        for _ in 0...3 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    names.insert(kid.lastPathComponent.lowercased())
                    extensions.insert(kid.pathExtension.lowercased())
                    if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(kid) }
                }
            }
            level = next
            if names.count > 20000 { break }
        }
        if isRPG2000(names) {
            return "This is an RPG Maker 2000/2003 game. Those aren't supported yet."
        }
        if extensions.contains("jar") || names.contains("jre") {
            return "This is a Java game (it ships a .jar). iPhone can't run Java desktop games, so NexPlay can't play it. Look for a web or Android version."
        }
        if names.contains("unityplayer.dll") || names.contains("globalgamemanagers") || names.contains("data.unity3d") {
            return "This is a Unity game for Windows. NexPlay can only run Unity games exported for the web (WebGL)."
        }
        if names.contains("data.win") || names.contains("game.unx") || names.contains("game.ios") {
            return "This is a GameMaker game for desktop. NexPlay can't run GameMaker desktop builds."
        }
        if extensions.contains("wolf") {
            return "This is a WOLF RPG Editor game. NexPlay can't run WOLF RPG games."
        }
        if names.contains("paks") && extensions.contains("pak") {
            return "This is an Unreal Engine game for desktop. NexPlay can't run it."
        }
        if extensions.contains("exe") {
            return "Only Windows program files were found: no web game, RPG Maker or Godot files. NexPlay can't run Windows programs."
        }
        return nil
    }
}
