import SwiftUI
import UIKit
import PhotosUI
import CoreText

// Shared look for NexPlay 2.2: the progress ring and floating import card, glass tiles, the gallery store and the
// cover/photo pickers. Layout ideas (ring with percent, pre-launch page, tiles) come from RPGPlayer screenshots;
// the code is NexPlay's own.

enum NexStyle {
    static let accent = Color(red: 0.62, green: 0.48, blue: 1)
    static let accentDeep = Color(red: 0.45, green: 0.3, blue: 0.95)
    static let accentGradient = LinearGradient(colors: [accentDeep, accent], startPoint: .leading, endPoint: .trailing)
    static let cardStroke = Color.white.opacity(0.12)
}

// MARK: - Progress ring

/// A ring that fills with progress. A nil fraction spins an arc instead.
struct ProgressRing: View {
    var fraction: Double?
    var lineWidth: CGFloat = 6
    var showsPercent = true
    var percentFont: Font = .system(size: 15, weight: .bold, design: .rounded)

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(fraction, 0.001), 1)))
                    .stroke(NexStyle.accentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: NexStyle.accent.opacity(0.6), radius: 4)
                    .animation(.easeOut(duration: 0.25), value: fraction)
                if showsPercent {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%")
                        .font(percentFont)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(NexStyle.accentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
    }
}

// MARK: - Import card

/// The floating import card: ring with the percentage, the stage, the file being worked on, and Cancel.
/// It sits above the library instead of covering it, and folds into a small pill when tapped.
struct ImportProgressCard: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    @State private var compact = false

    var body: some View {
        Group {
            if compact { pill } else { card }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: compact)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var card: some View {
        HStack(spacing: 14) {
            ProgressRing(fraction: progress.fraction, lineWidth: 5)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Label(progress.stage.title, systemImage: progress.stage.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(progress.detail.isEmpty ? progress.itemName : progress.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.itemCount > 1 {
                    Text("Item \(progress.item) of \(progress.itemCount)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(NexStyle.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("Cancel import")
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexStyle.cardStroke))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .contentShape(Rectangle())
        .onTapGesture { compact = true }
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
    }

    private var pill: some View {
        HStack(spacing: 8) {
            ProgressRing(fraction: progress.fraction, lineWidth: 3, showsPercent: false)
                .frame(width: 18, height: 18)
            Text(progress.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "…")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(progress.stage.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(NexStyle.cardStroke))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onTapGesture { compact = false }
    }
}

// MARK: - Tiles and chips

/// A square-ish glass button with an icon and a title (Saves, Gallery, Cheats, Plugins...).
struct ActionTile: View {
    let title: String
    let symbol: String
    var tint: Color = NexStyle.accent
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(NexStyle.accentDeep, in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexStyle.cardStroke))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A small label with an icon, for stats under the title.
struct StatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1), in: Capsule())
    }
}

/// Shrinks a little while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The big Play button.
struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(NexStyle.accentGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: NexStyle.accent.opacity(configuration.isPressed ? 0.2 : 0.5), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Gallery

/// Screenshots taken in a game, kept in Gallery/<game-uuid>/.
struct GalleryShot: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: String { url.path }
}

enum Gallery {
    static func add(_ image: UIImage, for game: Game) {
        let folder = Paths.galleryFolder(for: game)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = image.pngData() else { return }
        let url = folder.appendingPathComponent("\(Paths.timestamp()).png")
        try? data.write(to: url, options: .atomic)
    }

    static func shots(for game: Game) -> [GalleryShot] {
        let folder = Paths.galleryFolder(for: game)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return GalleryShot(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    static func count(for game: Game) -> Int {
        let folder = Paths.galleryFolder(for: game)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".png") }.count
    }

    static func delete(_ shot: GalleryShot) {
        try? FileManager.default.removeItem(at: shot.url)
    }

    static func removeAll(for game: Game) {
        try? FileManager.default.removeItem(at: Paths.galleryFolder(for: game))
    }
}

// MARK: - Covers

enum CoverStore {
    /// Saves `image` as the game's cover (square-cropped, at most 768 px) and refreshes the cache.
    static func setCover(_ image: UIImage, for game: Game) {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return }
        let target = min(side, 768)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target))
        let square = renderer.image { _ in
            let scale = target / side
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (target - width) / 2, y: (target - height) / 2, width: width, height: height))
        }
        if let data = square.pngData() {
            try? data.write(to: Paths.customCoverURL(for: game), options: .atomic)
        }
        CoverCache.forget(game)
    }

    static func resetCover(for game: Game) {
        try? FileManager.default.removeItem(at: Paths.customCoverURL(for: game))
        CoverCache.forget(game)
    }

    static func hasCustomCover(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: Paths.customCoverURL(for: game).path)
    }

    /// Images inside the game folder worth offering as a cover: the icon, title screens, pictures, faces...
    /// Skips encrypted RPG Maker files (.rpgmvp, .png_), which the app can't show.
    static func candidates(in game: Game, limit: Int = 120) -> [URL] {
        let root = Paths.folder(for: game)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var preferred: [URL] = []
        var other: [URL] = []
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { continue }
            let path = url.path.lowercased()
            if path.contains("/titles1/") || path.contains("/icon/") || path.contains("/pictures/") || path.contains("/parallaxes/") {
                preferred.append(url)
            } else if path.contains("/faces/") || path.contains("/titles2/") || path.contains("/sv_actors/") || !path.contains("/img/") {
                other.append(url)
            }
            if preferred.count >= limit { break }
        }
        return Array((preferred + other).prefix(limit))
    }
}

/// Picks one photo from the library (no permission prompt: PHPicker runs out of process).
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            let done = onPick
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async { done(image) }
            }
        }
    }
}

// MARK: - Pixel font

/// Departure Mono (Helena Zhang, SIL Open Font License 1.1, NexPlay/Fonts/DepartureMono-LICENSE.txt): the pixel
/// font the app uses for titles, buttons and controls when "Pixel Font" is on (default).
enum NexFont {
    static let name = "DepartureMono-Regular"
    private static var registered = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.pixelFont) as? Bool ?? true
    }

    /// Registers the bundled font with the process and styles UIKit bars. Call once at launch.
    static func setUp() {
        if !registered, let url = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf") {
            registered = true
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        guard enabled, UIFont(name: name, size: 12) != nil else { return }
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: ui(17)]
        bar.largeTitleTextAttributes = [.font: ui(32)]
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: ui(16)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: ui(13)], for: .normal)
    }

    static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if enabled, let font = UIFont(name: name, size: size) { return font }
        return .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    /// The pixel font at `size`, scaled with Dynamic Type; the rounded system font when Pixel Font is off.
    static func pixel(_ size: CGFloat, relativeTo style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        if NexFont.enabled, UIFont(name: NexFont.name, size: size) != nil {
            return .custom(NexFont.name, size: size, relativeTo: style)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }
}
