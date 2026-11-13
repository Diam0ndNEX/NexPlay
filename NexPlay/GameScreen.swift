import SwiftUI
import UIKit

/// The full-screen player for any game. `GameRuntimes` (Runtimes.swift) picks how it runs: the web player for
/// MV/MZ/HTML5 and the web runtimes, the Ruby core for XP/VX/Ace, Windows when chosen for the game.
struct GameScreen: UIViewControllerRepresentable {
    let game: Game
    let store: LibraryStore
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        // 7.10.0: crash-safe launch. Cleared after 20 seconds or when the game closes.
        LaunchGuard.begin(game, runtime: GameRuntimes.kind(for: game))
        let id = game.id
        let exit = onExit
        return GameRuntimes.runtime(for: game).makeViewController(game: game, store: store, onExit: {
            LaunchGuard.end(id)
            exit()
        })
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        if let player = uiViewController as? PlayerViewController {
            player.shutdown()
        }
        if let easyrpg = uiViewController as? EasyRPGViewController {
            easyrpg.shutdown()
        }
        if let ruby = uiViewController as? RubyPlayerControlling {
            ruby.shutdownRuby()
        }
    }
}

/// What the app needs from a Ruby (RPG Maker XP/VX/Ace) core. Builds without the core use `RubyCoreStub`.
@MainActor
protocol RubyGameRunner {
    /// True when this build contains a working core.
    var isAvailable: Bool { get }
    /// A short reason shown when the core is missing or can't start another game.
    var unavailableReason: String { get }
    func makeViewController(game: Game, onExit: @escaping () -> Void) -> UIViewController
}

/// A view controller that runs a Ruby game and must be told when the player closes.
@MainActor
protocol RubyPlayerControlling: AnyObject {
    func shutdownRuby()
}

enum RubyCore {
    /// The runner of this build. Builds with `NEXPLAY_MKXP` replace the stub (see NexPlay/MKXP/).
    @MainActor static var runner: RubyGameRunner = {
        #if NEXPLAY_MKXP
        return MkxpRunner()
        #else
        return RubyCoreStub()
        #endif
    }()
}

/// Used when the app is built without the mkxp core.
struct RubyCoreStub: RubyGameRunner {
    var isAvailable: Bool { false }

    var unavailableReason: String {
        "This build has no mkxp core, so RPG Maker XP, VX and VX Ace games can't start yet. They stay in your library and will run once a build with the core is installed."
    }

    func makeViewController(game: Game, onExit: @escaping () -> Void) -> UIViewController {
        RuntimeUnavailableController.make(title: game.name, reason: unavailableReason, onExit: onExit)
    }
}
