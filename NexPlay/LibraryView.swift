import SwiftUI

enum CoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for game: Game) -> UIImage? {
        let key = game.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Paths.coverURL(for: game), let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CoverView: View {
    let game: Game

    private var hue: Double {
        let sum = game.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double(sum % 360) / 360
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = CoverCache.image(for: game) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                                Color(hue: hue, saturation: 0.7, brightness: 0.25)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text(String(game.name.prefix(1)).uppercased())
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    if total < 60 { return total == 0 ? "Not played yet" : "Under a minute" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

struct GameCard: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(game: game)
                .overlay(alignment: .top) {
                    HStack {
                        Text(game.engine.badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        if game.isFavorite {
                            Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                        }
                    }
                    .padding(8)
                }
            Text(game.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(formatDuration(game.playSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage(SettingsKey.librarySort) private var sortRaw = LibrarySort.recent.rawValue

    @State private var search = ""
    @State private var playing: Game?
    @State private var detail: Game?
    @State private var showSettings = false

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }

    private var visible: [Game] {
        var list = store.games
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .recent:
            list.sort { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .added:
            list.sort { $0.addedAt > $1.addedAt }
        }
        return list.filter { $0.isFavorite } + list.filter { !$0.isFavorite }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if store.games.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                            ForEach(visible) { game in
                                GameCard(game: game)
                                    .contentShape(Rectangle())
                                    .onTapGesture { playing = game }
                                    .contextMenu { contextMenu(for: game) }
                            }
                        }
                        .padding()
                    }
                }

                if store.isImporting {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle("NexPlay")
            .searchable(text: $search, prompt: "Search games")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { importFiles() } label: { Label("Files or ZIP…", systemImage: "doc.zipper") }
                        Button { importFolders() } label: { Label("Folder…", systemImage: "folder") }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
        .fullScreenCover(item: $playing) { game in
            PlayerScreen(game: game, store: store, onExit: { playing = nil })
                .ignoresSafeArea()
        }
        .sheet(item: $detail) { game in
            GameDetailView(gameID: game.id) { detail = nil; playing = $0 }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Import problem", isPresented: Binding(
            get: { store.importMessage != nil },
            set: { if !$0 { store.importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("No games yet").font(.title2.bold())
            Text("Add an RPG Maker MV/MZ or HTML5 game as a ZIP or a folder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { importFiles() } label: { Label("Add a Game", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        Button { playing = game } label: { Label("Play", systemImage: "play.fill") }
        Button { store.toggleFavorite(game) } label: {
            Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "heart.slash" : "heart")
        }
        Button { detail = game } label: { Label("Details", systemImage: "info.circle") }
        Button(role: .destructive) {
            Task { await store.delete(game) }
        } label: { Label("Delete", systemImage: "trash") }
    }

    private func importFiles() {
        ImportPicker.pickFiles { urls in
            Task {
                await store.importItems(urls)
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    private func importFolders() {
        ImportPicker.pickFolders { urls in
            Task { await store.importItems(urls) }
        }
    }
}
