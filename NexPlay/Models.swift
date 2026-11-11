import Foundation
import SwiftUI

enum OrientationMode: String, Codable, CaseIterable, Identifiable {
    case auto, portrait, landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: return .allButUpsideDown
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}

enum GameEngine: String, Codable {
    case rpgMV, rpgMZ, web

    var badge: String {
        switch self {
        case .rpgMV: return "MV"
        case .rpgMZ: return "MZ"
        case .web: return "HTML"
        }
    }

    var title: String {
        switch self {
        case .rpgMV: return "RPG Maker MV"
        case .rpgMZ: return "RPG Maker MZ"
        case .web: return "HTML5 game"
        }
    }

    /// RPG Maker MV or MZ (web engines with the NexPlay runtime).
    var isRPGMaker: Bool {
        switch self {
        case .rpgMV, .rpgMZ: return true
        case .web: return false
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, added

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recently Played"
        case .name: return "Name"
        case .added: return "Recently Added"
        }
    }
}

struct Game: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var engine: GameEngine
    /// Path of the page that starts the game, relative to the game's folder (for example "www/index.html").
    var entry: String
    var addedAt: Date = Date()
    var lastPlayed: Date?
    var playCount: Int = 0
    var playSeconds: Double = 0
    var isFavorite: Bool = false
    var orientation: OrientationMode = .auto
    /// Shows the on-screen controller (arrows and buttons) over the game.
    var gamepad: Bool = true
    /// Blocks all http(s)/ws(s) requests so the game runs fully offline.
    var blockNetwork: Bool = false
    /// Shows a small overlay with frame rate, battery and time.
    var statsOverlay: Bool?
    /// Per-game NW.js mode override (nil follows the app setting). RPG Maker only.
    var nwMode: Bool?
    /// True once browser-mode saves were copied into save/ files.
    var savesMigrated: Bool?
    /// Speed the fast-forward button switches to (2...9). nil means 2.
    var fastForwardSpeed: Int?

    /// The hostname used in nexplay://<host>/ URLs. Unique per game, so every game has its own web storage.
    var host: String { id.uuidString.lowercased() }

    /// RPG Maker games run with the NW.js shim and keep saves as files in save/ when this is true.
    var usesNWMode: Bool {
        guard engine.isRPGMaker else { return false }
        return nwMode ?? UserDefaults.standard.bool(forKey: SettingsKey.nwMode)
    }
}

enum SettingsKey {
    static let librarySort = "librarySort"
    static let silentModeAudio = "silentModeAudio"
    static let showMenuButton = "showMenuButton"
    static let keepScreenAwake = "keepScreenAwake"
    /// RPG Maker games see a desktop browser (default on). Turn off if a game misbehaves.
    static let desktopMode = "desktopMode"
    /// Sharp pixels instead of smoothed scaling for RPG Maker games (default off).
    static let pixelatedScaling = "pixelatedScaling"
    /// RPG Maker games run as under NW.js and keep saves as files (default on).
    static let nwMode = "nwMode"
    /// Haptic feedback on on-screen control presses (default on) and its strength (0 light, 1 medium, 2 heavy).
    static let hapticsEnabled = "hapticsEnabled"
    static let hapticStrength = "hapticStrength"
    /// "keys" (controllers send keys, default) or "gamepadAPI" (leave controllers to the game).
    static let controllerMode = "controllerMode"
}
