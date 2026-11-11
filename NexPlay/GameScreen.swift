import SwiftUI
import UIKit

/// The full-screen player for any game: the web player for MV/MZ/HTML5, the Ruby core for XP/VX/Ace.
struct GameScreen: UIViewControllerRepresentable {
    let game: Game
    let store: LibraryStore
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if game.engine.isRuby {
            return RubyCore.runner.makeViewController(game: game, onExit: onExit)
        }
        return PlayerViewController(game: game, store: store, onExit: onExit)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        if let player = uiViewController as? PlayerViewController {
            player.shutdown()
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
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let label = UILabel()
        label.text = "\(game.name)\n\n\(unavailableReason)"
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
