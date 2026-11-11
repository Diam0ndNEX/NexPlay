import SwiftUI

// Animated library and settings backgrounds are an idea from RPGPlayer's background themes; the drawing is
// NexPlay's own (blurred drifting colour clouds plus stars, snow or sparks on a Canvas).

extension SettingsKey {
    static let animatedBackground = "animatedBackground"
    static let backgroundTheme = "backgroundTheme"   // BackgroundTheme raw value
    static let backgroundKeys: [String] = [animatedBackground, backgroundTheme]
}

enum BackgroundTheme: String, CaseIterable, Identifiable {
    case nebula, frost, ember, aurora, plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nebula: return "Cosmic Nebula"
        case .frost: return "Frost"
        case .ember: return "Ember"
        case .aurora: return "Aurora"
        case .plain: return "Plain"
        }
    }

    var symbol: String {
        switch self {
        case .nebula: return "sparkles"
        case .frost: return "snowflake"
        case .ember: return "flame"
        case .aurora: return "moon.stars"
        case .plain: return "circle.lefthalf.filled"
        }
    }

    fileprivate var base: [Color] {
        switch self {
        case .nebula: return [Color(red: 0.07, green: 0.04, blue: 0.16), Color(red: 0.02, green: 0.01, blue: 0.06)]
        case .frost: return [Color(red: 0.11, green: 0.15, blue: 0.23), Color(red: 0.03, green: 0.05, blue: 0.10)]
        case .ember: return [Color(red: 0.12, green: 0.06, blue: 0.02), Color(red: 0.02, green: 0.01, blue: 0.0)]
        case .aurora: return [Color(red: 0.02, green: 0.07, blue: 0.11), Color(red: 0.0, green: 0.02, blue: 0.04)]
        case .plain: return [Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.02, green: 0.02, blue: 0.03)]
        }
    }

    fileprivate var clouds: [Color] {
        switch self {
        case .nebula:
            return [Color(red: 0.45, green: 0.2, blue: 0.75).opacity(0.55), Color(red: 0.95, green: 0.55, blue: 0.3).opacity(0.42),
                    Color(red: 0.3, green: 0.12, blue: 0.6).opacity(0.5)]
        case .frost:
            return [Color(red: 0.4, green: 0.6, blue: 0.85).opacity(0.32), Color(red: 0.75, green: 0.82, blue: 0.95).opacity(0.18)]
        case .ember:
            return [Color(red: 0.9, green: 0.45, blue: 0.1).opacity(0.42), Color(red: 0.6, green: 0.15, blue: 0.05).opacity(0.45)]
        case .aurora:
            return [Color(red: 0.1, green: 0.8, blue: 0.6).opacity(0.38), Color(red: 0.2, green: 0.4, blue: 0.9).opacity(0.34),
                    Color(red: 0.6, green: 0.3, blue: 0.9).opacity(0.28)]
        case .plain:
            return []
        }
    }

    fileprivate var particle: Color {
        self == .ember ? Color(red: 1, green: 0.65, blue: 0.3) : .white
    }

    /// Screen heights a particle moves per second: positive falls (snow), negative rises (sparks).
    fileprivate var drift: Double {
        switch self {
        case .frost: return 0.025
        case .ember: return -0.02
        case .nebula, .aurora, .plain: return 0
        }
    }

    fileprivate var particleCount: Int {
        switch self {
        case .nebula, .aurora: return 110
        case .frost: return 80
        case .ember: return 45
        case .plain: return 0
        }
    }
}

/// The app background: the chosen theme, animated unless turned off. Light mode uses the plain system colour.
struct AppBackground: View {
    @AppStorage(SettingsKey.backgroundTheme) private var themeRaw = "nebula"
    @AppStorage(SettingsKey.animatedBackground) private var animated = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = BackgroundTheme(rawValue: themeRaw) ?? .nebula
        if colorScheme == .light {
            Color(UIColor.systemGroupedBackground)
        } else if animated && theme != .plain {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                BackgroundCanvas(theme: theme, time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            BackgroundCanvas(theme: theme, time: 0)
        }
    }
}

/// One frame of a background theme at `time` seconds.
struct BackgroundCanvas: View {
    let theme: BackgroundTheme
    let time: Double

    var body: some View {
        Canvas { context, size in
            BackgroundCanvas.draw(theme, time: time, in: &context, size: size)
        }
    }

    private static func fract(_ x: Double) -> Double {
        x - floor(x)
    }

    static func draw(_ theme: BackgroundTheme, time: Double, in context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > 0, height > 0 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: theme.base), startPoint: .zero,
                                           endPoint: CGPoint(x: size.width * 0.4, y: size.height)))

        let side = min(width, height)
        var glow = context
        glow.addFilter(.blur(radius: CGFloat(side * 0.18)))
        for (index, color) in theme.clouds.enumerated() {
            let i = Double(index)
            let x = width * (0.5 + 0.42 * sin(time * 0.045 * (1 + i * 0.35) + i * 2.1))
            let y = height * (0.5 + 0.40 * cos(time * 0.038 * (1 + i * 0.3) + i * 1.3))
            let r = side * (0.42 + 0.08 * sin(time * 0.06 + i))
            glow.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
        }

        for index in 0..<theme.particleCount {
            let seed = Double(index) + 1
            let px = fract(sin(seed * 12.9898) * 43758.5453)
            let start = fract(sin(seed * 78.233) * 12543.1234)
            let speed = 0.5 + fract(seed * 0.618)
            let py = fract(start + time * theme.drift * speed)
            let twinkle = 0.35 + 0.65 * abs(sin(time * (0.6 + speed) + seed))
            let dot = 0.8 + fract(seed * 0.37) * 1.8
            let rect = CGRect(x: px * width, y: py * height, width: dot, height: dot)
            context.fill(Path(ellipseIn: rect), with: .color(theme.particle.opacity(twinkle * 0.85)))
        }
    }
}
