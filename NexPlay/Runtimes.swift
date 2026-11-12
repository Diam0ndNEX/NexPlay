import SwiftUI
import UIKit

// 6.2.0: how a game is run, kept apart from what the game is (`GameEngine`).
// Screens ask `GameRuntimes` instead of branching on isRuby / isWebGame themselves.

/// How a game is run.
enum RuntimeKind: String, Codable, CaseIterable, Identifiable {
    /// The web view (MV/MZ runtime, HTML5, Godot/Ren'Py/Ruffle web runtimes).
    case web
    /// The mkxp core (RPG Maker XP/VX/Ace).
    case ruby
    /// Wine + FEX + DXMT (from BCD's runtime, BCDCore.framework).
    case windows
    /// 7.1.1: EasyRPG Player's libretro core (RPG Maker 2000/2003).
    case easyrpg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web: return "Native (web)"
        case .ruby: return "Native (mkxp)"
        case .windows: return "Windows"
        case .easyrpg: return "Native (EasyRPG)"
        }
    }

    var symbol: String {
        switch self {
        case .web: return "globe"
        case .ruby: return "shield.lefthalf.filled"
        case .windows: return "pc"
        case .easyrpg: return "map"
        }
    }
}

/// The owner's verdict on how well a game runs.
enum CompatStatus: String, Codable, CaseIterable, Identifiable {
    case untested, works, playable, broken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .untested: return "Untested"
        case .works: return "Works"
        case .playable: return "Playable"
        case .broken: return "Broken"
        }
    }

    var color: Color {
        switch self {
        case .untested: return .gray
        case .works: return .green
        case .playable: return .yellow
        case .broken: return .red
        }
    }
}

/// Where a game came from.
enum GameSource: String, Codable, CaseIterable, Identifiable {
    case imported, steam, gog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imported: return "Imported"
        case .steam: return "Steam"
        case .gog: return "GOG"
        }
    }
}

/// What a runtime can do for a game. Screens use this instead of engine checks.
struct RuntimeCapabilities: Equatable {
    var needsJIT = false
    var saveStates = false
    var gameSpeed = false
    var pause = false
    var touchMouse = false
    var cheats = false
}

/// One way of running games.
@MainActor
protocol GameRuntime {
    var kind: RuntimeKind { get }
    /// True when this build can run games with this runtime.
    var isAvailable: Bool { get }
    /// A short reason shown when the runtime is missing from this build.
    var unavailableReason: String { get }
    func capabilities(for game: Game) -> RuntimeCapabilities
    func makeViewController(game: Game, store: LibraryStore, onExit: @escaping () -> Void) -> UIViewController
}

@MainActor
enum GameRuntimes {
    static let web: GameRuntime = WebGameRuntime()
    static let ruby: GameRuntime = RubyGameRuntime()
    static let windows: GameRuntime = WindowsGameRuntime()
    static let easyrpg: GameRuntime = EasyRPGGameRuntime()

    /// The runtime an engine runs on natively.
    nonisolated static func nativeKind(for engine: GameEngine) -> RuntimeKind {
        if engine == .windows { return .windows }
        if engine == .rpg2k { return .easyrpg }
        return engine.isRuby ? .ruby : .web
    }

    /// How this game runs (7.1.0 routing). A runtime chosen in Game Settings wins. Automatic: the runtime the game last
    /// ran well on, else its native runtime; a native runtime missing from this build hands over to Windows when the
    /// game has a Windows program and the Windows runtime is here.
    static func kind(for game: Game) -> RuntimeKind {
        if let chosen = game.runtime { return chosen }
        let native = nativeKind(for: game.engine)
        if let good = game.lastGoodRuntime, good == native || canRunOnWindows(game) { return good }
        if !runtime(of: native).isAvailable, canRunOnWindows(game) { return .windows }
        return native
    }

    /// True when the Windows runtime is in this build and the game's folder has a Windows program.
    static func canRunOnWindows(_ game: Game) -> Bool {
        windows.isAvailable && WindowsGameFiles.program(for: game) != nil
    }

    /// The runtimes a game can be set to in Game Settings (besides Automatic).
    nonisolated static func choices(for game: Game) -> [RuntimeKind] {
        let native = nativeKind(for: game.engine)
        var list = [native]
        if native != .windows, WindowsGameFiles.program(for: game) != nil { list.append(.windows) }
        return list
    }

    static func runtime(of kind: RuntimeKind) -> GameRuntime {
        switch kind {
        case .web: return web
        case .ruby: return ruby
        case .windows: return windows
        case .easyrpg: return easyrpg
        }
    }

    static func runtime(for game: Game) -> GameRuntime {
        runtime(of: kind(for: game))
    }

    static func capabilities(for game: Game) -> RuntimeCapabilities {
        runtime(for: game).capabilities(for: game)
    }
}

/// The web view player (PlayerViewController).
struct WebGameRuntime: GameRuntime {
    var kind: RuntimeKind { .web }
    var isAvailable: Bool { true }
    var unavailableReason: String { "" }

    func capabilities(for game: Game) -> RuntimeCapabilities {
        let engine = game.engine
        var caps = RuntimeCapabilities()
        caps.saveStates = engine.isRPGMaker || engine == .twine
        caps.gameSpeed = engine.isRPGMaker || engine.isWebGame
        caps.pause = caps.gameSpeed
        caps.cheats = engine.isRPGMaker
        return caps
    }

    func makeViewController(game: Game, store: LibraryStore, onExit: @escaping () -> Void) -> UIViewController {
        PlayerViewController(game: game, store: store, onExit: onExit)
    }
}

/// The mkxp core, through `RubyCore.runner` (a stub in builds without NEXPLAY_MKXP).
struct RubyGameRuntime: GameRuntime {
    var kind: RuntimeKind { .ruby }
    var isAvailable: Bool { RubyCore.runner.isAvailable }
    var unavailableReason: String { RubyCore.runner.unavailableReason }

    func capabilities(for game: Game) -> RuntimeCapabilities {
        RuntimeCapabilities()
    }

    func makeViewController(game: Game, store: LibraryStore, onExit: @escaping () -> Void) -> UIViewController {
        RubyCore.runner.makeViewController(game: game, onExit: onExit)
    }
}

/// Windows games (Wine + FEX + DXMT): BCD's runtime (BCDBridge.swift), started from the library (WindowsGames.swift).
struct WindowsGameRuntime: GameRuntime {
    var kind: RuntimeKind { .windows }
    var isAvailable: Bool { BCDRuntimeInfo.unavailableReason == nil }

    var unavailableReason: String {
        BCDRuntimeInfo.unavailableReason
            ?? "This build has no Windows runtime, so Windows games can't start yet. They stay in your library and will run once a build with the runtime is installed."
    }

    func capabilities(for game: Game) -> RuntimeCapabilities {
        var caps = RuntimeCapabilities()
        caps.needsJIT = true
        caps.touchMouse = true
        return caps
    }

    func makeViewController(game: Game, store: LibraryStore, onExit: @escaping () -> Void) -> UIViewController {
        guard isAvailable else {
            return RuntimeUnavailableController.make(title: game.name, reason: unavailableReason, onExit: onExit)
        }
        return WindowsLaunchController(game: game, store: store, onExit: onExit)
    }
}

/// A black screen with a message and a Back to Library button, for runtimes missing from this build.
enum RuntimeUnavailableController {
    @MainActor
    static func make(title: String, reason: String, onExit: @escaping () -> Void) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let label = UILabel()
        label.text = "\(title)\n\n\(reason)"
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.setTitle("Back to Library", for: .normal)
        button.addAction(UIAction { _ in onExit() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        controller.view.addSubview(button)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -32),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
            button.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
        ])
        return controller
    }
}
