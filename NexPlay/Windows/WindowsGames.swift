import UIKit

// 7.0.0: Windows games in NexPlay's library. A game's files stay in NexPlay's Games/<id> folder; a link to that folder
// sits on BCD's Windows drive as C:\NexPlay\<id>, the game is added to BCD's library (nexplay_bcd_add_game) and started
// with BCD's own play link (madeira://play?exe=C:\NexPlay\<id>\...). BCD runs it with its JIT, Wine, FEX and DXMT.
// BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

enum WindowsGameFiles {
    /// Program names that are never the game: installers, redistributables, crash reporters, helpers.
    private static let skipped = ["unins", "uninstall", "setup", "install", "vcredist", "vc_redist", "dxsetup", "dxwebsetup",
                                  "directx", "dotnet", "netfx", "ndp4", "oalinst", "physx", "crashhandler", "crashreport",
                                  "crashpad", "unitycrashhandler", "ue4prereq", "ueprereq", "prereq", "notification_helper",
                                  "cefsharp", "cefprocess", "subprocess", "steamerrorreporter", "easyanticheat", "be_service",
                                  "dowser", "zsync", "7z", "winrar", "update", "patch"]

    /// The game's main program, relative to its folder: the shallowest .exe that isn't a helper, the biggest at that
    /// depth. Nil when the folder has no Windows program or holds a Java game.
    static func mainExecutable(in root: URL) -> String? {
        let fm = FileManager.default
        var level = [root]
        var best: [(size: Int, url: URL)] = []
        var hasJava = false
        for _ in 0...4 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    let values = try? kid.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true {
                        next.append(kid)
                        continue
                    }
                    let ext = kid.pathExtension.lowercased()
                    if ext == "jar" { hasJava = true }
                    guard ext == "exe" else { continue }
                    let name = kid.deletingPathExtension().lastPathComponent.lowercased()
                    if skipped.contains(where: { name.hasPrefix($0) || name.contains("crash") }) { continue }
                    best.append((values?.fileSize ?? 0, kid))
                }
            }
            if !best.isEmpty { break }
            level = next
        }
        if hasJava { return nil }
        guard let pick = best.max(by: { $0.size < $1.size }) else { return nil }
        return GameScanner.relativePath(of: pick.url, in: root)
    }

    /// Every .exe in the game's folder (four levels deep), relative to it, sorted.
    static func allExecutables(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if walker.level > 5 { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe" { found.append(GameScanner.relativePath(of: url, in: root)) }
            if found.count >= 200 { break }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func detect(in root: URL) -> DetectedGame? {
        mainExecutable(in: root).map { DetectedGame(engine: .windows, entry: $0) }
    }

    /// The title from the program's name ("Hollow_Knight.exe" -> "Hollow Knight").
    static func title(for entry: String) -> String {
        let name = ((entry as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// The program a game starts: its chosen .exe, else its entry when that is an .exe, else a fresh look.
    static func program(for game: Game) -> String? {
        if let exe = game.exePath, !exe.isEmpty { return exe }
        if game.entry.lowercased().hasSuffix(".exe") { return game.entry }
        return mainExecutable(in: Paths.folder(for: game))
    }
}

/// The link from BCD's Windows drive to a NexPlay game folder.
enum WindowsLibraryLink {
    /// BCD's C: drive (Documents/wine/drive_c, as BCD's LibraryModel.drive).
    static var drive: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c", isDirectory: true)
    }

    /// True once BCD has set up its Windows drive (its first start in Windows Games).
    static var driveReady: Bool {
        FileManager.default.fileExists(atPath: drive.appendingPathComponent("windows", isDirectory: true).path)
    }

    static func linkURL(for game: Game) -> URL {
        drive.appendingPathComponent("NexPlay", isDirectory: true).appendingPathComponent(game.id.uuidString)
    }

    /// The program's path on BCD's drive ("NexPlay/<id>/Game/game.exe") and its Windows path.
    static func paths(for game: Game, program: String) -> (relative: String, windows: String) {
        let relative = "NexPlay/\(game.id.uuidString)/\(program)"
        return (relative, "C:\\" + relative.replacingOccurrences(of: "/", with: "\\"))
    }

    /// Makes (or repairs) C:\NexPlay\<id> pointing at the game's folder.
    static func make(for game: Game) throws {
        let fm = FileManager.default
        let link = linkURL(for: game)
        let target = Paths.folder(for: game)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path { return }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    static func remove(for game: Game) {
        let link = linkURL(for: game)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? FileManager.default.removeItem(at: link)
        }
    }
}

/// What the player sees while a Windows game runs in BCD's screen: a black page that starts it, and returns to the
/// library when BCD's screen is closed.
@MainActor
final class WindowsLaunchController: UIViewController {
    private let game: Game
    private let onExit: () -> Void
    private let label = UILabel()
    private var started = false

    init(game: Game, onExit: @escaping () -> Void) {
        self.game = game
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.text = "Starting \(game.name)…"
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let back = UIButton(type: .system)
        back.setTitle("Back to Library", for: .normal)
        back.addAction(UIAction { [weak self] _ in self?.onExit() }, for: .touchUpInside)
        back.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        view.addSubview(back)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            back.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
            back.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        start()
    }

    private func fail(_ message: String) {
        AppLog.log("windows: \(game.name): \(message)")
        label.text = "\(game.name)\n\n\(message)"
    }

    private func start() {
        AppLog.noteGame(game.name)
        guard let program = WindowsGameFiles.program(for: game) else {
            fail("No Windows program (.exe) was found in this game's folder.")
            return
        }
        do {
            try BCDRuntimeInfo.load()
            guard WindowsLibraryLink.driveReady else {
                // BCD sets up its Windows drive on its first start; the game can be added after that.
                try BCDBridge.show(onClose: { [weak self] in self?.label.text = "Windows Games is set up. Tap Back to Library, then Play again." })
                fail("Windows Games sets up its Windows drive first. When it's done, close it and press Play again.")
                return
            }
            try WindowsLibraryLink.make(for: game)
            let paths = WindowsLibraryLink.paths(for: game, program: program)
            guard try BCDBridge.addGame(relativePath: paths.relative, title: game.name) else {
                fail("Windows Games couldn't add this game to its library.")
                return
            }
            var link = URLComponents()
            link.scheme = "madeira"
            link.host = "play"
            link.queryItems = [URLQueryItem(name: "exe", value: paths.windows)]
            guard let url = link.url else { fail("The game's path can't be made into a link."); return }
            AppLog.log("windows: starting \(paths.windows)")
            try BCDBridge.open(url, onClose: { [weak self] in self?.onExit() })
        } catch {
            fail((error as? WindowsRuntimeError)?.message ?? error.localizedDescription)
        }
    }
}
