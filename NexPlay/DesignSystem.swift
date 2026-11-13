// NexPlay 8.1.0 design system: colour profiles with semantic tokens, Liquid Glass surfaces, type scale,
// motion presets, haptics and placeholder covers. 8.1.1 applies them to Home, Library, the tab bar,
// Settings and Setup Center.
//
// Adapted from BCD (https://github.com/thebcd69/bcd-games), GPL-3.0-only:
// - colour profiles and the profile generator: BCDThemeCore.swift / BCDTheme.swift, copyright 2026 creeper4004;
// - the glass surface (glass for controls, opaque cards for reading, material and Reduce Transparency fallbacks):
//   BCDStyle.swift, copyright 2026 Paulo Eduardo Correa (pauloec) and thebcd69;
// - the preset colours: BCDThemes.json.
// Modified for NexPlay, 2026-11-13: own type names (BCD's files stay untouched and compile only with the
// Windows engine), a NexPlay Nebula default profile, light-mode variants, NexPlay's type scale, motion,
// haptics and placeholder covers.

import SwiftUI
import UIKit
import Observation

extension SettingsKey {
    /// The selected colour profile id ("nebula" default; "custom" = generated from `colorProfileSeed`).
    static let colorProfile = "colorProfile"
    /// The main colour of the custom profile, "#RRGGBB".
    static let colorProfileSeed = "colorProfileSeed"
}

// MARK: - RGB helper

struct NexRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.red = bounded(red)
        self.green = bounded(green)
        self.blue = bounded(blue)
    }

    init?(hex: String) {
        guard hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }

    static let black = NexRGB(red: 0, green: 0, blue: 0)
    static let white = NexRGB(red: 1, green: 1, blue: 1)

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    func mixed(with other: NexRGB, amount: Double) -> NexRGB {
        NexRGB(red: red * (1 - amount) + other.red * amount,
               green: green * (1 - amount) + other.green * amount,
               blue: blue * (1 - amount) + other.blue * amount)
    }

    private var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
    }

    func contrast(with other: NexRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    /// Darkened until white text on it reaches `ratio`.
    func darkened(toContrastWithWhite ratio: Double) -> NexRGB {
        var color = self
        var steps = 0
        while color.contrast(with: .white) < ratio && steps < 60 {
            color = color.mixed(with: .black, amount: 0.04)
            steps += 1
        }
        return color
    }

    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

// MARK: - Profiles

/// The semantic colour roles every NexPlay screen uses (the same roles as BCD's profiles).
enum NexRole: String, CaseIterable {
    case ground, groundTop, surface, surfaceRaised, stroke, text, textSoft
    case accent, accentSecondary, accentSoft, success, warning, danger, panel, onAccent
}

/// A colour profile: dark colours for every role. Light mode is derived from them (`lightColor`).
struct NexThemeProfile: Equatable, Identifiable {
    var id: String
    var name: String
    var seed: String?
    var colors: [String: String]

    func dark(_ role: NexRole) -> NexRGB {
        NexRGB(hex: colors[role.rawValue] ?? "")
            ?? NexRGB(hex: NexThemeProfile.nebula.colors[role.rawValue] ?? "")
            ?? .white
    }

    /// Light-mode colour for a role: tinted near-white grounds, white cards, dark tinted text, deeper accents.
    func light(_ role: NexRole) -> NexRGB {
        let accent = dark(.accent)
        switch role {
        case .ground: return accent.mixed(with: .white, amount: 0.95)
        case .groundTop: return accent.mixed(with: .white, amount: 0.86)
        case .surface: return accent.mixed(with: .white, amount: 0.975)
        case .surfaceRaised: return .white
        case .panel: return accent.mixed(with: .white, amount: 0.92)
        case .stroke: return accent.mixed(with: .white, amount: 0.78)
        case .text: return accent.mixed(with: .black, amount: 0.86)
        case .textSoft: return accent.mixed(with: .black, amount: 0.55).mixed(with: NexRGB(red: 0.45, green: 0.45, blue: 0.5), amount: 0.4)
        case .accent: return accent.darkened(toContrastWithWhite: 4.5)
        case .accentSecondary: return dark(.accentSecondary).darkened(toContrastWithWhite: 4.5)
        case .accentSoft: return accent.darkened(toContrastWithWhite: 5.5)
        case .success: return NexRGB(red: 0.06, green: 0.55, blue: 0.38)
        case .warning: return NexRGB(red: 0.66, green: 0.42, blue: 0.0)
        case .danger: return NexRGB(red: 0.80, green: 0.18, blue: 0.27)
        case .onAccent: return .white
        }
    }

    /// NexPlay's own default: the violet of 2.2-8.0 (NexStyle) on a deep nebula ground.
    static let nebula = NexThemeProfile(id: "nebula", name: "Nebula", seed: nil, colors: [
        "ground": "#08061A", "groundTop": "#1B1240", "surface": "#161233", "surfaceRaised": "#211A47",
        "stroke": "#30285A", "text": "#F5F2FF", "textSoft": "#B9B0D6", "accent": "#734DF2",
        "accentSecondary": "#B04DE0", "accentSoft": "#9E7AFF", "success": "#34D399", "warning": "#FFC24A",
        "danger": "#FF7588", "panel": "#0F0C24", "onAccent": "#FFFFFF"
    ])

    /// BCD's presets (BCDThemes.json).
    static let presets: [NexThemeProfile] = [
        nebula,
        NexThemeProfile(id: "violet", name: "Violet", seed: nil, colors: [
            "ground": "#0B0816", "groundTop": "#1A0F33", "surface": "#1A1430", "surfaceRaised": "#231B3F",
            "stroke": "#2F2350", "text": "#F4F1FF", "textSoft": "#B7AECF", "accent": "#7C3AED",
            "accentSecondary": "#D946EF", "accentSoft": "#C9B7FF", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#100C1F", "onAccent": "#FFFFFF"
        ]),
        NexThemeProfile(id: "ocean", name: "Ocean", seed: "#38BDF8", colors: [
            "ground": "#02080A", "groundTop": "#091E28", "surface": "#06151B", "surfaceRaised": "#0A222D",
            "stroke": "#265164", "text": "#F7FCFF", "textSoft": "#C7EDFD", "accent": "#257EA5",
            "accentSecondary": "#5A6CAB", "accentSoft": "#C3EBFD", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#030B0F", "onAccent": "#FFFFFF"
        ]),
        NexThemeProfile(id: "forest", name: "Forest", seed: "#34D399", colors: [
            "ground": "#020806", "groundTop": "#082218", "surface": "#061711", "surfaceRaised": "#09261C",
            "stroke": "#255845", "text": "#F7FDFB", "textSoft": "#C6F3E2", "accent": "#20815E",
            "accentSecondary": "#3E6E7B", "accentSoft": "#C2F2E0", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#030D09", "onAccent": "#FFFFFF"
        ]),
        NexThemeProfile(id: "ember", name: "Ember", seed: "#FB923C", colors: [
            "ground": "#0A0602", "groundTop": "#28170A", "surface": "#1C1007", "surfaceRaised": "#2D1A0B",
            "stroke": "#654328", "text": "#FFFBF7", "textSoft": "#FEE0C8", "accent": "#A76128",
            "accentSecondary": "#777338", "accentSoft": "#FEDEC4", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#0F0904", "onAccent": "#FFFFFF"
        ]),
        NexThemeProfile(id: "rose", name: "Rose", seed: "#F472B6", colors: [
            "ground": "#0A0507", "groundTop": "#27121D", "surface": "#1B0D14", "surfaceRaised": "#2C1521",
            "stroke": "#62394F", "text": "#FFF9FC", "textSoft": "#FCD8EB", "accent": "#B05283",
            "accentSecondary": "#97686C", "accentSoft": "#FCD5E9", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#0F070B", "onAccent": "#FFFFFF"
        ]),
        NexThemeProfile(id: "graphite", name: "Graphite", seed: "#A1A1AA", colors: [
            "ground": "#060607", "groundTop": "#1A1A1B", "surface": "#121213", "surfaceRaised": "#1D1D1F",
            "stroke": "#48484B", "text": "#FBFBFC", "textSoft": "#E5E5E7", "accent": "#74747B",
            "accentSecondary": "#737175", "accentSoft": "#E3E3E5", "success": "#34D399", "warning": "#FFC24A",
            "danger": "#FF7588", "panel": "#0A0A0A", "onAccent": "#FFFFFF"
        ])
    ]

    /// One main colour tints every surface (BCD's generator); action fills stay readable for yellow or white seeds.
    static func generated(main: NexRGB) -> NexThemeProfile {
        let accent = main.darkened(toContrastWithWhite: 4.5)
        let secondary = accent.mixed(with: NexRGB(red: main.blue, green: main.red, blue: main.green), amount: 0.25)
            .darkened(toContrastWithWhite: 4.6)
        var result = nebula
        result.id = "custom"
        result.name = "My Colour"
        result.seed = main.hex
        let generated: [String: String] = [
            "ground": main.mixed(with: .black, amount: 0.96).hex,
            "groundTop": main.mixed(with: .black, amount: 0.84).hex,
            "surface": main.mixed(with: .black, amount: 0.89).hex,
            "surfaceRaised": main.mixed(with: .black, amount: 0.82).hex,
            "panel": main.mixed(with: .black, amount: 0.94).hex,
            "stroke": main.mixed(with: .white, amount: 0.20).mixed(with: .black, amount: 0.60).hex,
            "text": main.mixed(with: .white, amount: 0.96).hex,
            "textSoft": main.mixed(with: .white, amount: 0.72).hex,
            "accent": accent.hex,
            "accentSecondary": secondary.hex,
            "accentSoft": main.mixed(with: .white, amount: 0.70).hex
        ]
        result.colors.merge(generated) { _, new in new }
        return result
    }
}

/// The selected profile. Views that read `NexColor` (through `current`) redraw when it changes.
@Observable final class NexTheme {
    static let shared = NexTheme()

    private(set) var current: NexThemeProfile = NexThemeProfile.nebula

    init() {
        reload()
    }

    var profiles: [NexThemeProfile] {
        var list = NexThemeProfile.presets
        if let seed = UserDefaults.standard.string(forKey: SettingsKey.colorProfileSeed), let rgb = NexRGB(hex: seed) {
            list.append(NexThemeProfile.generated(main: rgb))
        }
        return list
    }

    /// Reads the saved choice again (after Reset).
    func reload() {
        let id = UserDefaults.standard.string(forKey: SettingsKey.colorProfile) ?? "nebula"
        current = profiles.first { $0.id == id } ?? NexThemeProfile.nebula
    }

    func select(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: SettingsKey.colorProfile)
        current = profile
    }

    /// Makes (or replaces) the custom profile from one colour and selects it.
    func setMainColor(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let rgb = NexRGB(red: Double(r), green: Double(g), blue: Double(b))
        UserDefaults.standard.set(rgb.hex, forKey: SettingsKey.colorProfileSeed)
        UserDefaults.standard.set("custom", forKey: SettingsKey.colorProfile)
        current = NexThemeProfile.generated(main: rgb)
    }
}

// MARK: - Colour tokens

/// Semantic colours of the selected profile, adapting to light and dark mode.
enum NexColor {
    static func role(_ role: NexRole) -> Color {
        let profile = NexTheme.shared.current
        let dark = profile.dark(role).uiColor
        let light = profile.light(role).uiColor
        return Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    /// The dark-mode colour, for screens that are always dark (game page, loading screen, in-game panels).
    static func dark(_ role: NexRole) -> Color {
        Color(uiColor: NexTheme.shared.current.dark(role).uiColor)
    }

    static var ground: Color { role(.ground) }
    static var groundTop: Color { role(.groundTop) }
    static var surface: Color { role(.surface) }
    static var surfaceRaised: Color { role(.surfaceRaised) }
    static var panel: Color { role(.panel) }
    static var stroke: Color { role(.stroke) }
    static var text: Color { role(.text) }
    static var textSoft: Color { role(.textSoft) }
    static var accent: Color { role(.accent) }
    static var accentSecondary: Color { role(.accentSecondary) }
    static var accentSoft: Color { role(.accentSoft) }
    static var success: Color { role(.success) }
    static var warning: Color { role(.warning) }
    static var danger: Color { role(.danger) }
    static var onAccent: Color { role(.onAccent) }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary], startPoint: .leading, endPoint: .trailing)
    }
    static var backdrop: LinearGradient {
        LinearGradient(colors: [groundTop, ground, ground], startPoint: .top, endPoint: .bottom)
    }
}

/// Spacing and corner radii.
enum NexMetrics {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let cornerS: CGFloat = 10
    static let cornerM: CGFloat = 16
    static let cornerL: CGFloat = 22
    static let rowHeight: CGFloat = 52
    /// Space kept free under scrolling content so the floating tab bar never covers the last rows.
    static let tabBarClearance: CGFloat = 96
}

// MARK: - Type

/// NexPlay's type scale: the pixel font only for big titles, SF Rounded for everything people read.
enum NexType {
    /// Big screen and game titles. Pixel font when it is on, else heavy rounded.
    static func display(_ size: CGFloat = 30) -> Font {
        if NexFont.enabled { return Font.pixel(size, relativeTo: .largeTitle) }
        return .system(size: size, weight: .heavy, design: .rounded)
    }
    static func title(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static var heading: Font { .system(.headline, design: .rounded).weight(.bold) }
    static var body: Font { .system(.body, design: .rounded) }
    static var label: Font { .system(.subheadline, design: .rounded).weight(.semibold) }
    static var caption: Font { .system(.caption, design: .rounded) }
    static var captionStrong: Font { .system(.caption, design: .rounded).weight(.semibold) }
    static var number: Font { .system(.body, design: .rounded).weight(.semibold).monospacedDigit() }
}

// MARK: - Glass

/// Glass belongs to the control layer (bars, buttons, panels); reading cards stay opaque (`nexCard`).
/// iOS 26+: Liquid Glass. Older: material. Reduce Transparency: opaque raised surface.
private struct NexGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var enabled

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(NexColor.surfaceRaised, in: shape)
                .overlay(shape.stroke(NexColor.stroke, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive && enabled), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(NexColor.stroke.opacity(0.6), lineWidth: 1))
        }
    }
}

/// An opaque reading surface with a hairline border.
private struct NexCardSurface: ViewModifier {
    var padding: CGFloat
    var raised: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: NexMetrics.cornerL, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(raised ? NexColor.surfaceRaised : NexColor.surface, in: shape)
            .overlay(shape.strokeBorder(NexColor.stroke, lineWidth: 1))
    }
}

extension View {
    func nexGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NexGlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    func nexGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NexGlassSurface(shape: Capsule(), tint: tint, interactive: interactive))
    }

    func nexCard(padding: CGFloat = NexMetrics.spacingL, raised: Bool = false) -> some View {
        modifier(NexCardSurface(padding: padding, raised: raised))
    }
}

/// The main action: accent glass on iOS 26+, an accent gradient capsule before.
struct NexPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(NexType.label)
                .foregroundStyle(NexColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .nexGlassCapsule(tint: NexColor.accent, interactive: true)
                .opacity(enabled ? 1 : 0.45)
        } else {
            configuration.label
                .font(NexType.label)
                .foregroundStyle(NexColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(NexColor.accentGradient, in: Capsule())
                .shadow(color: NexColor.accent.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 12, y: 4)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(NexMotion.press, value: configuration.isPressed)
        }
    }
}

/// A second choice: glass capsule with plain text.
struct NexGlassButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NexType.label)
            .foregroundStyle(NexColor.text)
            .padding(.horizontal, fullWidth ? 0 : NexMetrics.spacingL)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
            .nexGlassCapsule(interactive: true)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(NexMotion.press, value: configuration.isPressed)
    }
}

/// A round glass icon button (close, settings, more).
struct NexGlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(NexColor.text)
            .frame(width: size, height: size)
            .nexGlass(in: Circle(), interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(NexMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Motion

/// Shared spring presets. Use `nexAnimation` so Reduce Motion turns movement into a short fade.
enum NexMotion {
    /// Buttons and small toggles.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.75)
    /// Selection changes, chips, tabs.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.85)
    /// Cards appearing, sheets of content, layout changes.
    static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.9)
    /// Playful moments (favourite, success).
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.62)
    /// Big transitions (card to game page, game page to loading screen).
    static let hero = Animation.spring(response: 0.55, dampingFraction: 0.88)
    /// What Reduce Motion gets instead.
    static let reduced = Animation.easeInOut(duration: 0.15)

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The preset, or a short fade when Reduce Motion is on.
    static func pick(_ animation: Animation) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// `withAnimation` that respects Reduce Motion.
    static func run(_ animation: Animation = smooth, _ body: () -> Void) {
        withAnimation(pick(animation), body)
    }
}

private struct NexAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? NexMotion.reduced : animation, value: value)
    }
}

extension View {
    func nexAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(NexAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Haptics

/// One place for haptics, so every key action feels the same.
enum NexHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func press() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Engine identity

extension GameEngine {
    /// One accent colour per engine (placeholder covers, chips, game page).
    var accent: Color {
        switch self {
        case .rpgMV: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .rpgMZ: return Color(red: 0.55, green: 0.42, blue: 0.98)
        case .rpgXP: return Color(red: 0.86, green: 0.36, blue: 0.36)
        case .rpgVX: return Color(red: 0.25, green: 0.70, blue: 0.62)
        case .rpgVXAce: return Color(red: 0.95, green: 0.55, blue: 0.25)
        case .rpg2k: return Color(red: 0.62, green: 0.68, blue: 0.30)
        case .web: return Color(red: 0.95, green: 0.42, blue: 0.20)
        case .godot: return Color(red: 0.28, green: 0.55, blue: 0.75)
        case .construct: return Color(red: 0.20, green: 0.68, blue: 0.86)
        case .twine: return Color(red: 0.30, green: 0.72, blue: 0.45)
        case .tyrano: return Color(red: 0.92, green: 0.40, blue: 0.62)
        case .renpy: return Color(red: 0.88, green: 0.30, blue: 0.48)
        case .flash: return Color(red: 0.90, green: 0.22, blue: 0.22)
        case .windows: return Color(red: 0.18, green: 0.52, blue: 0.95)
        }
    }
}

// MARK: - Placeholder cover

/// Cover for a game without art: engine-tinted gradient, the engine glyph, the title and the engine badge.
/// Fixed by its frame, so nothing jumps when real art loads later.
struct NexPlaceholderCover: View {
    let title: String
    let engine: GameEngine
    var compact = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let tint = engine.accent
            ZStack {
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55), Color.black.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .topLeading,
                               startRadius: 0, endRadius: side * 0.9)
                Image(systemName: engine.symbol)
                    .font(.system(size: side * 0.62, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .rotationEffect(.degrees(-12))
                    .offset(x: proxy.size.width * 0.24, y: -proxy.size.height * 0.12)
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: engine.symbol)
                        .font(.system(size: max(12, side * 0.14), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                    if !compact {
                        Text(title)
                            .font(.system(size: max(11, side * 0.12), weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Text(engine.badge)
                        .font(.system(size: max(9, side * 0.07), weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.28), in: Capsule())
                }
                .padding(max(8, side * 0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(engine.title)")
    }
}
