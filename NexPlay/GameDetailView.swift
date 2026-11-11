import SwiftUI
import UniformTypeIdentifiers

/// Pages the game page opens.
enum GameRoute: String, Identifiable {
    case settings, saves, gallery, plugins
    var id: String { rawValue }
}

/// The page before a game starts: big cover over a blurred copy of it, title, engine and status, stats, Play,
/// and tiles for Saves, Gallery, Plugins and Settings. Layout idea from RPGPlayer; NexPlay's own code.
struct GameDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID
    /// Called with the game when the user taps Play.
    let onPlay: (Game) -> Void

    @State private var cover: UIImage?
    @State private var sizeText = "…"
    @State private var saveCount = 0
    @State private var shotCount = 0
    @State private var route: GameRoute?
    @State private var appeared = false

    private var game: Game? { store.game(id: gameID) }

    var body: some View {
        ZStack {
            if let game {
                backdrop(game)
                page(game)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await refresh() }
        .sheet(item: $route, onDismiss: { Task { await refresh() } }) { page in
            if let game {
                routeView(page, game)
                    .environmentObject(store)
                    .environmentObject(collections)
                    .environmentObject(privacy)
            }
        }
    }

    @ViewBuilder
    private func routeView(_ page: GameRoute, _ game: Game) -> some View {
        switch page {
        case .settings:
            GameSettingsView(gameID: game.id) {
                route = nil
                dismiss()
            }
        case .saves:
            GameSavesView(gameID: game.id)
        case .gallery:
            GalleryView(game: game)
        case .plugins:
            PluginListView(game: game)
        }
    }

    // MARK: - Pieces

    private func backdrop(_ game: Game) -> some View {
        ZStack {
            AppBackground()
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .opacity(0.55)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func page(_ game: Game) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                topBar
                coverCard(game)
                titleBlock(game)
                statsRow(game)
                playButton(game)
                tiles(game)
                if let notes = game.notes, !notes.isEmpty {
                    notesCard(notes)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var topBar: some View {
        HStack {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            circleButton("gearshape.fill", label: "Game settings") { route = .settings }
        }
        .padding(.top, 12)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(NexStyle.cardStroke))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    private func coverCard(_ game: Game) -> some View {
        let glow = game.tagColor ?? NexStyle.accent
        return CoverView(game: game)
            .frame(maxWidth: 300)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(game.tagColor ?? NexStyle.cardStroke,
                                                                                 lineWidth: game.tagColor == nil ? 1 : 2))
            .shadow(color: glow.opacity(0.45), radius: 24, y: 10)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            }
    }

    private func titleBlock(_ game: Game) -> some View {
        VStack(spacing: 10) {
            Text(game.name)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let subtitle = subtitle(game) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 8) {
                Text(game.engine.badge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                statusMenu(game)
                Button {
                    store.toggleFavorite(game)
                } label: {
                    Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(game.isFavorite ? .pink : .white)
                        .padding(8)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel(game.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    private func subtitle(_ game: Game) -> String? {
        var parts: [String] = []
        if let developer = game.developer, !developer.isEmpty { parts.append(developer) }
        if let version = game.version, !version.isEmpty { parts.append("v" + version) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func statusMenu(_ game: Game) -> some View {
        Menu {
            ForEach(GameStatus.allCases) { status in
                Button {
                    store.mutate(game.id) { $0.status = status }
                } label: {
                    Label(status.title, systemImage: status.symbol)
                }
            }
        } label: {
            Label(game.playStatus.title, systemImage: game.playStatus.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(game.playStatus.color.opacity(0.35), in: Capsule())
        }
    }

    private func statsRow(_ game: Game) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatChip(symbol: "clock.fill", text: formatDuration(game.playSeconds))
                if let last = game.lastPlayed {
                    StatChip(symbol: "calendar", text: last.formatted(.relative(presentation: .named)))
                }
                StatChip(symbol: "internaldrive.fill", text: sizeText)
                if game.usesNWMode {
                    StatChip(symbol: "square.and.arrow.down.fill", text: saveCount == 1 ? "1 save" : "\(saveCount) saves")
                }
                if game.playCount > 0 {
                    StatChip(symbol: "play.fill", text: "\(game.playCount)×")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func playButton(_ game: Game) -> some View {
        Button {
            dismiss()
            onPlay(game)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text(game.lastPlayed == nil ? "Play" : "Continue")
            }
        }
        .buttonStyle(PlayButtonStyle())
        .padding(.top, 4)
    }

    private func tiles(_ game: Game) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                       GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ActionTile(title: "Saves", symbol: "externaldrive.fill", tint: NexStyle.accent,
                       badge: saveCount > 0 ? "\(saveCount)" : nil) { route = .saves }
            ActionTile(title: "Gallery", symbol: "photo.on.rectangle.angled", tint: .cyan,
                       badge: shotCount > 0 ? "\(shotCount)" : nil) { route = .gallery }
            if game.engine.isRPGMaker {
                ActionTile(title: "Plugins", symbol: "puzzlepiece.extension.fill", tint: .orange) { route = .plugins }
            } else {
                ActionTile(title: "Settings", symbol: "slider.horizontal.3", tint: .orange) { route = .settings }
            }
        }
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notes", systemImage: "note.text").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            Text(notes).font(.subheadline).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { route = .settings }
    }

    private func refresh() async {
        guard let game else { return }
        let target = game
        cover = await CoverCache.load(for: target)
        let folder = Paths.folder(for: target)
        let result = await Task.detached { () -> (Int64, Int, Int) in
            (GameScanner.size(of: folder), SaveArchive.info(for: target).count, Gallery.count(for: target))
        }.value
        sizeText = ByteCountFormatter.string(fromByteCount: result.0, countStyle: .file)
        saveCount = result.1
        shotCount = result.2
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet for SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
