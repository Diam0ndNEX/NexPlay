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
    case rpgMV, rpgMZ, web, rpgXP, rpgVX, rpgVXAce, godot, construct, twine, tyrano, renpy, flash
    /// 7.0.0: a Windows program, run by the Windows runtime (BCD).
    case windows

    var badge: String {
        switch self {
        case .rpgMV: return "MV"
        case .rpgMZ: return "MZ"
        case .web: return "HTML"
        case .rpgXP: return "XP"
        case .rpgVX: return "VX"
        case .rpgVXAce: return "Ace"
        case .godot: return "Godot"
        case .construct: return "Construct"
        case .twine: return "Twine"
        case .tyrano: return "Tyrano"
        case .renpy: return "Ren'Py"
        case .flash: return "Flash"
        case .windows: return "PC"
        }
    }

    var title: String {
        switch self {
        case .rpgMV: return "RPG Maker MV"
        case .rpgMZ: return "RPG Maker MZ"
        case .web: return "HTML5 game"
        case .rpgXP: return "RPG Maker XP"
        case .rpgVX: return "RPG Maker VX"
        case .rpgVXAce: return "RPG Maker VX Ace"
        case .godot: return "Godot"
        case .construct: return "Construct"
        case .twine: return "Twine story"
        case .tyrano: return "TyranoBuilder / TyranoScript"
        case .renpy: return "Ren'Py visual novel"
        case .flash: return "Flash (Ruffle)"
        case .windows: return "Windows game"
        }
    }

    /// An SF Symbol for chips and badges.
    var symbol: String {
        switch self {
        case .rpgMV, .rpgMZ: return "map.fill"
        case .rpgXP, .rpgVX, .rpgVXAce: return "shield.lefthalf.filled"
        case .web: return "globe"
        case .godot: return "cube.fill"
        case .construct: return "square.stack.3d.up.fill"
        case .twine: return "text.book.closed.fill"
        case .tyrano: return "text.bubble.fill"
        case .renpy: return "bubble.left.and.text.bubble.right.fill"
        case .flash: return "bolt.fill"
        case .windows: return "pc"
        }
    }

    /// RPG Maker MV or MZ (web engines with the NexPlay runtime).
    var isRPGMaker: Bool {
        switch self {
        case .rpgMV, .rpgMZ: return true
        case .web, .rpgXP, .rpgVX, .rpgVXAce, .godot, .construct, .twine, .tyrano, .renpy, .flash, .windows: return false
        }
    }

    /// RPG Maker XP, VX or VX Ace: Ruby games that need the mkxp core, not the web view.
    var isRuby: Bool {
        switch self {
        case .rpgXP, .rpgVX, .rpgVXAce: return true
        case .rpgMV, .rpgMZ, .web, .godot, .construct, .twine, .tyrano, .renpy, .flash, .windows: return false
        }
    }

    /// Games in the web view without the RPG Maker runtime or the NW.js shim (HTML5, Godot, Construct, Twine,
    /// Tyrano, and Ren'Py and Flash on their bundled web runtimes).
    var isWebGame: Bool {
        switch self {
        case .web, .godot, .construct, .twine, .tyrano, .renpy, .flash: return true
        case .rpgMV, .rpgMZ, .rpgXP, .rpgVX, .rpgVXAce, .windows: return false
        }
    }

    /// Served from a loopback HTTP server instead of the nexplay:// scheme. Godot 4 needs a secure origin with
    /// cross-origin isolation (SharedArrayBuffer for threads), which http://127.0.0.1 gets and a custom scheme may not.
    /// Ren'Py and Flash run on bundled runtimes the server also serves.
    var usesLocalServer: Bool { self == .godot || self == .renpy || self == .flash }

    /// Engines that run on a runtime bundled with NexPlay, which a game can choose in Game Settings.
    var hasRuntimeChoice: Bool { self == .godot || self == .renpy }
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
    /// Per-game screen scaling (ScreenScaling raw value); nil follows the app setting.
    var screenScaling: String?
    /// Where the player is with this game; nil means backlog.
    var status: GameStatus?
    /// A colour tag (GameColor raw value) shown on the card; nil means none.
    var colorTag: String?
    /// Free text the player keeps about the game.
    var notes: String?
    /// The game's version, as the player typed it.
    var version: String?
    /// Developer or publisher, as the player typed it.
    var developer: String?
    /// Save profiles (NW.js-mode RPG Maker games); nil means one implicit "Profile 1".
    var profiles: [SaveProfile]?
    /// The profile whose saves are in save/ right now.
    var activeProfile: UUID?
    /// The bundled runtime version this game runs on (Godot, Ren'Py); nil picks one automatically.
    var runtimeVersion: String?

    // 6.2.0: how the game runs (Runtimes.swift). All optional, so old libraries still load.
    /// The runtime chosen for this game; nil = automatic (its engine's native runtime).
    var runtime: RuntimeKind?
    /// Windows games: the main .exe, relative to the game's folder.
    var exePath: String?
    /// Windows games: the Wine prefix (C: drive) id; nil = the shared "Default" prefix.
    var prefixID: String?
    /// The owner's compatibility vote.
    var compatibility: CompatStatus?
    /// Where the game came from; nil = imported.
    var source: GameSource?
    /// The store's id for the game (Steam app id, GOG product id).
    var storeID: String?
    /// 7.1.0: the Windows program's PE scan (graphics API, 32/64-bit), made at import or first start.
    var windowsInfo: WindowsInfo?
    /// 7.1.0: the runtime the game last ran on for a while (two minutes or more); Automatic prefers it.
    var lastGoodRuntime: RuntimeKind?

    /// The hostname used in nexplay://<host>/ URLs. Unique per game, so every game has its own web storage.
    var host: String { id.uuidString.lowercased() }

    /// RPG Maker games run with the NW.js shim and keep saves as files in save/ when this is true.
    var usesNWMode: Bool {
        guard engine.isRPGMaker else { return false }
        return nwMode ?? UserDefaults.standard.bool(forKey: SettingsKey.nwMode)
    }
}

/// How an RPG Maker game fills a screen whose shape differs from the game's.
enum ScreenScaling: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var symbol: String {
        switch self {
        case .fit: return "rectangle.center.inset.filled"
        case .fill: return "rectangle.inset.filled"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    static var global: ScreenScaling {
        ScreenScaling(rawValue: UserDefaults.standard.string(forKey: SettingsKey.screenScaling) ?? "fit") ?? .fit
    }

    /// The game's own choice, else the app setting.
    static func resolved(for game: Game) -> ScreenScaling {
        if let raw = game.screenScaling, let mode = ScreenScaling(rawValue: raw) { return mode }
        return global
    }
}

/// Play status shown on the card and in the detail page (RPGPlayer has "Backlog"; NexPlay adds the rest).
enum GameStatus: String, Codable, CaseIterable, Identifiable {
    case backlog, playing, onHold, completed, dropped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .playing: return "Playing"
        case .onHold: return "On Hold"
        case .completed: return "Completed"
        case .dropped: return "Dropped"
        }
    }

    var symbol: String {
        switch self {
        case .backlog: return "tray.full.fill"
        case .playing: return "play.circle.fill"
        case .onHold: return "pause.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .dropped: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .backlog: return .gray
        case .playing: return .purple
        case .onHold: return .orange
        case .completed: return .green
        case .dropped: return .red
        }
    }
}

/// Colour tags for games.
enum GameColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, cyan, blue, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return Color(red: 1, green: 0.27, blue: 0.3)
        case .orange: return Color(red: 1, green: 0.58, blue: 0.2)
        case .yellow: return Color(red: 1, green: 0.84, blue: 0.1)
        case .green: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .mint: return Color(red: 0.1, green: 0.85, blue: 0.75)
        case .cyan: return Color(red: 0.1, green: 0.8, blue: 0.95)
        case .blue: return Color(red: 0.25, green: 0.5, blue: 1)
        case .purple: return Color(red: 0.62, green: 0.45, blue: 1)
        case .pink: return Color(red: 1, green: 0.4, blue: 0.7)
        }
    }
}

extension Game {
    var playStatus: GameStatus { status ?? .backlog }
    /// Added in the last week and never started: the card shows "NEW".
    var isNew: Bool { playCount == 0 && lastPlayed == nil && Date().timeIntervalSince(addedAt) < 7 * 86_400 }
    var tagColor: Color? { colorTag.flatMap { GameColor(rawValue: $0) }?.color }
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
    /// Screen scaling for RPG Maker games: "fit" (default), "fill" or "stretch".
    static let screenScaling = "screenScaling"
    /// Screenshots also go to the Photos library (default on); they always go to the game's gallery.
    static let screenshotsToPhotos = "screenshotsToPhotos"
    /// The Departure Mono pixel font for the interface (default on).
    static let pixelFont = "pixelFont"
    /// Tapping a game opens its game page (default on); off starts it right away.
    static let tapOpensGamePage = "tapOpensGamePage"
}
