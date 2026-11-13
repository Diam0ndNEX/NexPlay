import SwiftUI

enum CoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(for game: Game) -> UIImage? {
        cache.object(forKey: game.id.uuidString as NSString)
    }

    /// Decodes the cover off the main thread and keeps it in memory.
    static func load(for game: Game) async -> UIImage? {
        if let image = cached(for: game) { return image }
        let target = game
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let image = GameArt.hero(for: target) else { return nil }
            let side = max(image.size.width, image.size.height)
            if side > 600, let small = image.preparingThumbnail(of: CGSize(width: image.size.width * 600 / side,
                                                                          height: image.size.height * 600 / side)) {
                return small
            }
            return image.preparingForDisplay() ?? image
        }.value
        if let image { cache.setObject(image, forKey: game.id.uuidString as NSString) }
        return image
    }

    static func forget(_ game: Game) {
        cache.removeObject(forKey: game.id.uuidString as NSString)
    }
}

struct CoverView: View {
    let game: Game
    @State private var image: UIImage?
    /// 8.1.1: small covers (shelf thumbnails, list rows) leave the title out of the placeholder.
    var compact = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = image ?? CoverCache.cached(for: game) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                } else {
                    // 8.1.1: engine-tinted placeholder (gradient, glyph, title) instead of a single letter.
                    NexPlaceholderCover(title: game.name, engine: game.engine, compact: compact)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .task(id: game.id) { image = await CoverCache.load(for: game) }
            .accessibilityHidden(true)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    if total < 60 { return total == 0 ? "Not played yet" : "Under a minute" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

struct EngineBadge: View {
    let engine: GameEngine
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: engine.symbol).font(.system(size: 8, weight: .bold))
            Text(engine.badge)
        }
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

struct GameCard: View {
    let game: Game
    var titleUnder = true
    var selected: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(game: game, compact: !titleUnder)
                .overlay(alignment: .top) {
                    HStack {
                        EngineBadge(engine: game.engine)
                        if game.status != nil && game.playStatus != .backlog {
                            Image(systemName: game.playStatus.symbol)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(game.playStatus.color)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Spacer()
                        if game.isNew {
                            Text("NEW")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(NexColor.accent, in: Capsule())
                        }
                        if game.isFavorite {
                            Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    // 7.5.0: compatibility dot and a PC chip when the game runs through Windows.
                    HStack(spacing: 4) {
                        if let compat = game.compatibility, compat != .untested {
                            Circle().fill(compat.color).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.black.opacity(0.4)))
                        }
                        if game.runtime == .windows && game.engine != .windows {
                            Text("PC").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8), in: Capsule())
                        }
                    }
                    .padding(8)
                    .opacity(titleUnder ? 1 : 0)
                }
                .overlay(alignment: .bottomLeading) {
                    if !titleUnder {
                        Text(game.name)
                            .font(NexType.label)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .overlay {
                    if let tint = game.tagColor {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint, lineWidth: 3)
                            .shadow(color: tint.opacity(0.6), radius: 6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selected ? NexColor.accentSoft : .white)
                            .padding(8)
                    }
                }
            if titleUnder {
                Text(game.name)
                    .font(NexType.label)
                    .foregroundStyle(NexColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(formatDuration(game.playSeconds))
                    .font(NexType.caption)
                    .foregroundStyle(NexColor.textSoft)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct GameRow: View {
    let game: Game
    var selected: Bool?

    var body: some View {
        HStack(spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? NexColor.accent : NexColor.textSoft)
            }
            CoverView(game: game, compact: true).frame(width: 52)
                .overlay {
                    if let tint = game.tagColor {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint, lineWidth: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).font(NexType.label).foregroundStyle(NexColor.text).lineLimit(1)
                Text("\(game.engine.title) · \(formatDuration(game.playSeconds))")
                    .font(NexType.caption).foregroundStyle(NexColor.textSoft)
            }
            Spacer()
            if game.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
        }
        // 8.1.1: an opaque reading card per row.
        .padding(10)
        .background(NexColor.surface, in: RoundedRectangle(cornerRadius: NexMetrics.cornerM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NexMetrics.cornerM, style: .continuous).strokeBorder(NexColor.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A filter chip at the top of the library: everything, an engine, favorites, or a collection.
/// 7.4.0: `ready` hides games that need setup first.
enum LibraryFilter: Hashable {
    case all, favorites, ready, engine(GameEngine), collection(UUID)
}

/// 7.4.0: the app's tabs (a floating glass bar at the bottom).
enum RootTab: String, CaseIterable, Identifiable {
    case home, library, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 7.4.0: why a game can't start right now, or nil when it is ready to play.
enum GameReadiness {
    @MainActor
    static func setupReason(for game: Game) -> String? {
        let runtime = GameRuntimes.runtime(for: game)
        if !runtime.isAvailable { return "\(runtime.kind.title) runtime missing" }
        if runtime.capabilities(for: game).needsJIT && !JITManager.shared.pairingPresent {
            return "Needs JIT: import a pairing file"
        }
        return nil
    }
}

/// The floating tab bar.
struct NexTabBar: View {
    @Binding var tab: RootTab
    var badge: Int = 0
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RootTab.allCases) { item in
                Button {
                    if tab != item {
                        NexHaptics.selection()
                        tab = item
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if item == .settings && badge > 0 {
                                    Circle().fill(NexColor.warning).frame(width: 8, height: 8).offset(x: 6, y: -3)
                                }
                            }
                        Text(item.title).font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(tab == item ? NexColor.onAccent : NexColor.textSoft)
                    .frame(width: 84, height: 50)
                    .background {
                        if tab == item {
                            Capsule().fill(NexColor.accentGradient)
                                .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(5)
        // 8.1.1: Liquid Glass (material below iOS 26, opaque with Reduce Transparency).
        .nexGlassCapsule()
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .nexAnimation(NexMotion.snappy, value: tab)
    }
}

/// 8.1.1: fades scrolling content out behind the floating tab bar.
struct NexTabBarEdgeFade: View {
    var body: some View {
        LinearGradient(colors: [NexColor.ground.opacity(0), NexColor.ground.opacity(0.85), NexColor.ground],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @EnvironmentObject private var appState: AppState
    @AppStorage(SettingsKey.librarySortOrder) private var sortRaw = LibrarySortOrder.playedRecent.rawValue
    @AppStorage(SettingsKey.libraryLayout) private var layout = "grid"
    @AppStorage(SettingsKey.titleUnderCard) private var titleUnder = true
    @AppStorage(SettingsKey.showContinueCard) private var showContinue = true

    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @State private var playing: Game?
    @State private var detail: Game?
    @State private var showCollections = false
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: [Game] = []
    @State private var sizes: [UUID: Int64] = [:]
    @State private var shareURL: URL?
    @State private var showStats = false
    @State private var askingLink = false
    @State private var linkText = ""
    @State private var showWhatsNew = false
    @AppStorage(SettingsKey.whatsNewSeen) private var whatsNewSeen = ""
    @State private var tab: RootTab = .home
    @State private var showOnboarding = false
    // 7.8.0: controller navigation.
    @StateObject private var pad = LibraryController()
    @State private var focusID: UUID?
    @State private var gridWidth: CGFloat = 390
    @AppStorage(SettingsKey.onboarding7Seen) private var onboardingSeen = false
    @State private var showSetupCenter = false
    @ObservedObject private var jit = JITManager.shared

    private var sort: LibrarySortOrder { LibrarySortOrder(rawValue: sortRaw) ?? .playedRecent }

    private var hiddenCollectionGames: Set<UUID> {
        Set(collections.collections.filter { $0.isHidden }.flatMap { $0.gameIDs })
    }

    private func isVisible(_ game: Game) -> Bool {
        if privacy.isUnlocked { return true }
        return !privacy.isHidden(game.id) && !hiddenCollectionGames.contains(game.id)
    }

    private var visibleCollections: [GameCollection] {
        collections.collections.filter { privacy.isUnlocked || !$0.isHidden }
    }

    private var visible: [Game] {
        var list = store.games.filter(isVisible)
        switch filter {
        case .all: break
        case .favorites: list = list.filter { $0.isFavorite }
        case .ready: list = list.filter { GameReadiness.setupReason(for: $0) == nil }
        case .engine(let engine): list = list.filter { $0.engine == engine }
        case .collection(let id):
            let ids = collections.collections.first { $0.id == id }?.gameIDs ?? []
            list = ids.compactMap { gid in list.first { $0.id == gid } }
            if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
            return list
        }
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        return sort.sort(list, sizes: sizes)
    }

    private var continueGame: Game? {
        guard showContinue, search.isEmpty, !selecting else { return nil }
        return store.games.filter(isVisible).filter { $0.lastPlayed != nil }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    /// The newest games, for the Recently Added shelf (only on the plain library view with enough games).
    private var recentlyAdded: [Game] {
        let list = store.games.filter(isVisible)
        return Array(list.sorted { $0.addedAt > $1.addedAt }.prefix(10))
    }

    /// Home shelves (7.4.0).
    private var recentlyPlayed: [Game] {
        let skip = continueGame?.id
        let list = store.games.filter { isVisible($0) && $0.lastPlayed != nil && $0.id != skip }
        return Array(list.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(12))
    }

    private var favorites: [Game] {
        store.games.filter { isVisible($0) && $0.isFavorite }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var needsSetup: [Game] {
        _ = jit.pairingPresent
        return store.games.filter { isVisible($0) && GameReadiness.setupReason(for: $0) != nil }
    }

    private var summary: String {
        let list = store.games.filter(isVisible)
        let total = list.reduce(0) { $0 + $1.playSeconds }
        return "\(list.count) game\(list.count == 1 ? "" : "s") · \(formatHours(total)) played"
    }

    private func engineCount(_ engine: GameEngine) -> Int {
        store.games.filter { isVisible($0) && $0.engine == engine }.count
    }

    private var hasHiddenContent: Bool {
        !privacy.hiddenGames.isEmpty || collections.collections.contains { $0.isHidden }
    }

    private var engines: [GameEngine] {
        var seen: [GameEngine] = []
        for game in store.games where !seen.contains(game.engine) { seen.append(game.engine) }
        return seen
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if tab == .settings {
                SettingsView(embedded: true)
                    .environmentObject(store)
                    .environmentObject(privacy)
                    .environment(\.nexTabBarInset, NexMetrics.tabBarClearance)
            } else {
                libraryStack
            }
            if !selecting {
                NexTabBarEdgeFade()
                NexTabBar(tab: $tab)
                    .padding(.bottom, 4)
            }
        }
        .fullScreenCover(item: $playing) { game in
            GameScreen(game: game, store: store, onExit: {
                playing = nil
                if AutoBackup.isEnabled {
                    Task.detached(priority: .utility) { AutoBackup.run(game) }
                }
            })
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $detail) { game in
            GameDetailView(gameID: game.id) { chosen in
                detail = nil
                // Let the game page finish closing before the player opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { playing = chosen }
            }
            .font(.pixel(16))
            .environmentObject(store)
            .environmentObject(collections)
            .environmentObject(privacy)
        }
        .sheet(isPresented: $showCollections) {
            CollectionsManagerView().environmentObject(collections)
        }
        .alert("Download a Game", isPresented: $askingLink) {
            TextField("https://…", text: $linkText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Download") {
                let link = linkText
                Task { await store.importFromLink(link) }
            }
        } message: {
            Text("Paste a direct download link to a ZIP, 7z, RAR, HTML or SWF file. NexPlay downloads it and imports it.")
        }
        .sheet(isPresented: $showStats) {
            NavigationStack {
                StatsView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { showStats = false } }
                    }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: { whatsNewSeen = WhatsNewView.version }) {
            WhatsNewView(standalone: true)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard playing == nil && detail == nil else { return }
            if !onboardingSeen {
                showOnboarding = true
            } else if whatsNewSeen != WhatsNewView.version {
                showWhatsNew = true
            }
        }
        .sheet(item: Binding(
            get: { appState.pendingBackup.map { ShareItem(url: $0) } },
            set: { if $0 == nil { appState.pendingBackup = nil } }
        )) { item in
            BackupTargetPicker(zip: item.url).environmentObject(store)
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ActivityView(items: [item.url])
        }
        .alert("Import", isPresented: Binding(
            get: { store.importMessage != nil },
            set: { if !$0 { store.importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importMessage ?? "")
        }
        .alert("Saves found", isPresented: Binding(
            get: { store.rescueOffer != nil && store.importMessage == nil },
            set: { if !$0 { store.rescueOffer = nil } }
        ), presenting: store.rescueOffer) { offer in
            Button("Put Them Back") {
                Task { await store.acceptRescue(offer) }
            }
            Button("Not Now", role: .cancel) {}
        } message: { offer in
            Text("Saves of a deleted copy of \(offer.gameName) were kept. Put them back into the game you just imported? Files that would be replaced are kept as .nex-displaced.bak copies.")
        }
        .confirmationDialog("\(store.pendingUpdate?.title ?? "This game") is already in your library", isPresented: Binding(
            get: { store.pendingUpdate != nil },
            set: { shown in
                // Runs after a button's own action; only a dismissal without a choice cancels.
                if !shown {
                    Task { @MainActor in
                        await Task.yield()
                        if store.pendingUpdate != nil { store.answerUpdate(.cancel) }
                    }
                }
            }
        ), titleVisibility: .visible) {
            Button("Update It") { store.answerUpdate(.update) }
            Button("Add as New Game") { store.answerUpdate(.addNew) }
            Button("Cancel", role: .cancel) { store.answerUpdate(.cancel) }
        } message: {
            Text("Update keeps its saves, settings and layout and replaces the game files. A file in the new version that sits where a save is gets kept as a .nex-displaced.bak copy.")
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDelete.isEmpty },
            set: { if !$0 { pendingDelete = [] } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteNow(pendingDelete) }
        } message: {
            Text("Save files are kept in Rescued Saves. Browser-mode saves are deleted.")
        }
        .onAppear { startPad() }
        .onChange(of: playing?.id) { id in
            // The player's controller code took the handlers; take them back when the game closes.
            if id == nil { startPad() }
        }
        .onChange(of: appState.pendingPlay) { id in
            guard let id else { return }
            appState.pendingPlay = nil
            // Hidden games only start from a link while hidden games are shown.
            guard let game = store.game(id: id), isVisible(game), playing == nil else { return }
            // 7.10.0: a game that crashed at start opens its page instead of starting again.
            if LaunchGuard.crashedRuntime(for: game.id) != nil {
                detail = game
                return
            }
            detail = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playing = game }
        }
        .task(id: sort) {
            guard sort.needsSizes else { return }
            let games = store.games
            sizes = await Task.detached(priority: .utility) {
                var result: [UUID: Int64] = [:]
                for game in games { result[game.id] = GameScanner.size(of: Paths.folder(for: game)) }
                return result
            }.value
        }
    }

    private var libraryStack: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if store.games.isEmpty && !store.isImporting {
                    emptyState
                } else if tab == .home {
                    homeContent
                } else {
                    content
                }
                if selecting { selectionBar }
                if !selecting {
                    HStack {
                        Spacer()
                        addMenu
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 74)
                }
                if store.isImporting {
                    ImportProgressCard(progress: store.importProgress) { store.cancelImport() }
                        .padding(.bottom, selecting ? 76 : 136)
                }
            }
            .nexAnimation(NexMotion.smooth, value: store.isImporting)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(tab == .home ? "NexPlay" : "Library")
            // 7.13.5: under the title. The default placement on iOS 26+ is a bottom bar, which sat behind NexTabBar.
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search games")
            .toolbar { toolbar }
            .onChange(of: search) { text in
                if !text.isEmpty && tab == .home { tab = .library }
            }
            .sheet(isPresented: $showSetupCenter) {
                NavigationStack {
                    SetupCenterView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { showSetupCenter = false } }
                        }
                }
            }
        }
    }

    // MARK: - Home (7.4.0)

    private var homeContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(summary).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                if let game = continueGame { continueCard(game) }
                if !needsSetup.isEmpty { setupCard }
                if !recentlyPlayed.isEmpty { shelf("Recently Played", symbol: "clock.fill", games: recentlyPlayed) }
                if !favorites.isEmpty { shelf("Favorites", symbol: "heart.fill", games: favorites) }
                if !recentlyAdded.isEmpty { shelf("Recently Added", symbol: "sparkles", games: recentlyAdded) }
                if !needsSetup.isEmpty { shelf("Needs Setup", symbol: "exclamationmark.triangle.fill", games: needsSetup) }
                Button {
                    NexHaptics.tap()
                    tab = .library
                } label: {
                    Label("All \(store.games.filter(isVisible).count) Games", systemImage: "square.grid.2x2.fill")
                }
                .buttonStyle(NexGlassButtonStyle())
            }
            .padding()
            // 8.1.1: room for the + button and the tab bar.
            .padding(.bottom, NexMetrics.tabBarClearance + 56)
        }
        .onChange(of: focusID) { id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private var setupCard: some View {
        Button { showSetupCenter = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "checklist")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(NexColor.warning.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(needsSetup.count) game\(needsSetup.count == 1 ? " needs" : "s need") setup")
                        .font(NexType.heading).foregroundStyle(NexColor.text)
                    Text("Open Setup Center for the pairing file, JIT and runtimes.")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(NexColor.textSoft)
            }
            .padding(14)
            .background(NexColor.surface, in: RoundedRectangle(cornerRadius: NexMetrics.cornerL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NexMetrics.cornerL, style: .continuous).strokeBorder(NexColor.warning.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    private func shelf(_ title: String, symbol: String, games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).foregroundStyle(NexColor.text)
            } icon: {
                Image(systemName: symbol).foregroundStyle(NexColor.accentSoft)
            }
            .font(NexType.heading)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(games) { game in
                        VStack(alignment: .leading, spacing: 6) {
                            CoverView(game: game, compact: true)
                                .frame(width: 112)
                                .focusRing(focusID == game.id)
                                .overlay(alignment: .topTrailing) {
                                    if GameReadiness.setupReason(for: game) != nil {
                                        Circle().fill(NexColor.warning).frame(width: 10, height: 10)
                                            .overlay(Circle().stroke(Color.black.opacity(0.4)))
                                            .padding(7)
                                    }
                                }
                            Text(game.name)
                                .font(NexType.captionStrong)
                                .foregroundStyle(NexColor.text)
                                .lineLimit(2)
                                .frame(width: 112, height: 32, alignment: .topLeading)
                        }
                        .id(game.id)
                        .contentShape(Rectangle())
                        .onTapGesture { tap(game) }
                        .contextMenu { contextMenu(for: game) }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    /// The floating + (Files, Folder, Folder of Games, Link).
    private var addMenu: some View {
        Menu {
            Button { importFiles() } label: { Label("ZIP, 7z, RAR, HTML or SWF File…", systemImage: "doc.zipper") }
            Button { importFolders() } label: { Label("Game Folder…", systemImage: "folder") }
            Button { importBulk() } label: { Label("Folder of Many Games…", systemImage: "folder.badge.gearshape") }
            Button {
                let pasted = UIPasteboard.general.string ?? ""
                linkText = pasted.lowercased().hasPrefix("http") ? pasted : ""
                askingLink = true
            } label: { Label("Download from Link…", systemImage: "link.badge.plus") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(NexColor.accentGradient, in: Circle())
                .shadow(color: NexColor.accent.opacity(0.5), radius: 12, y: 5)
        }
        .accessibilityLabel("Add games")
    }

    // MARK: - Controller navigation (7.8.0)

    /// The games the focus ring moves through on the current tab.
    private var navList: [Game] {
        if tab == .library { return visible }
        var seen = Set<UUID>()
        var list: [Game] = []
        let parts: [[Game]] = [continueGame.map { [$0] } ?? [], recentlyPlayed, favorites, recentlyAdded, needsSetup]
        for game in parts.joined() where !seen.contains(game.id) {
            seen.insert(game.id)
            list.append(game)
        }
        return list
    }

    private var navColumns: Int {
        guard tab == .library, layout != "list" else { return 1 }
        return max(1, Int((gridWidth - 32 + 14) / 164))
    }

    private var focusedGame: Game? {
        guard let focusID else { return nil }
        return store.game(id: focusID)
    }

    private func startPad() {
        pad.onMove = { dx, dy in moveFocus(dx, dy) }
        pad.onButton = { button in padButton(button) }
        pad.start()
    }

    private func moveFocus(_ dx: Int, _ dy: Int) {
        guard playing == nil, detail == nil, tab != .settings, !selecting else { return }
        let list = navList
        guard !list.isEmpty else { return }
        guard let current = focusID, let index = list.firstIndex(where: { $0.id == current }) else {
            focusID = list.first?.id
            return
        }
        let next = min(max(index + dx + dy * navColumns, 0), list.count - 1)
        focusID = list[next].id
    }

    private func padButton(_ button: LibraryController.Button) {
        guard playing == nil else { return }
        switch button {
        case .a:
            if let open = detail {
                detail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { playing = open }
            } else if tab != .settings, let game = focusedGame {
                detail = game
            }
        case .x:
            if let open = detail {
                detail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { playing = open }
            } else if tab != .settings, let game = focusedGame {
                playing = game
            }
        case .b:
            if detail != nil { detail = nil } else { focusID = nil }
        case .y:
            if detail == nil, let game = focusedGame { store.toggleFavorite(game) }
        case .l1, .r1:
            guard detail == nil else { return }
            let all = RootTab.allCases
            let index = all.firstIndex(of: tab) ?? 0
            let step = button == .r1 ? 1 : all.count - 1
            tab = all[(index + step) % all.count]
            focusID = nil
        case .menu:
            guard detail == nil else { return }
            tab = tab == .settings ? .home : .settings
        }
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let game = pendingDelete.first { return "Delete \(game.name)?" }
        return "Delete \(pendingDelete.count) games?"
    }

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !store.games.isEmpty && search.isEmpty {
                    Text(summary).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                }
                chips
                if visible.isEmpty {
                    Text(search.isEmpty ? "Nothing here yet." : "No games match \u{201C}\(search)\u{201D}.")
                        .font(NexType.body)
                        .foregroundStyle(NexColor.textSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if layout == "list" {
                    LazyVStack(spacing: 10) {
                        ForEach(visible) { game in
                            GameRow(game: game, selected: selecting ? selection.contains(game.id) : nil)
                                .focusRing(focusID == game.id)
                                .id(game.id)
                                .onTapGesture { tap(game) }
                                .contextMenu { contextMenu(for: game) }
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                        ForEach(visible) { game in
                            GameCard(game: game, titleUnder: titleUnder, selected: selecting ? selection.contains(game.id) : nil)
                                .focusRing(focusID == game.id)
                                .id(game.id)
                                .contentShape(Rectangle())
                                .onTapGesture { tap(game) }
                                .contextMenu { contextMenu(for: game) }
                        }
                    }
                }
            }
            .padding()
            // 8.1.1: room for the + button and the tab bar.
            .padding(.bottom, selecting ? 70 : NexMetrics.tabBarClearance + 56)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { gridWidth = geo.size.width }
                .onChange(of: geo.size.width) { width in gridWidth = width }
        })
        .onChange(of: focusID) { id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", color: NexColor.accent, active: filter == .all) { filter = .all }
                chip("Favorites", color: .pink, active: filter == .favorites) { filter = .favorites }
                chip("Ready to Play", color: NexColor.success, active: filter == .ready, symbol: "checkmark.seal.fill") { filter = .ready }
                ForEach(engines, id: \.self) { engine in
                    chip("\(engine.badge) \(engineCount(engine))", color: engine.accent, active: filter == .engine(engine),
                         symbol: engine.symbol) { filter = .engine(engine) }
                }
                ForEach(visibleCollections) { collection in
                    chip(collection.name, color: collection.color, active: filter == .collection(collection.id),
                         locked: collection.isHidden) { filter = .collection(collection.id) }
                }
                Button { showCollections = true } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NexColor.text)
                        .frame(width: 40, height: 32)
                        .nexGlassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage collections")
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, color: Color, active: Bool, locked: Bool = false, symbol: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button {
            if !active { NexHaptics.selection() }
            NexMotion.run(NexMotion.snappy) { action() }
        } label: {
            // 8.1.1: active chips are filled with their colour; the others are glass with the colour as a dot.
            HStack(spacing: 5) {
                if locked { Image(systemName: "lock.fill").font(.caption2) }
                if let symbol {
                    Image(systemName: symbol).font(.caption2.weight(.semibold))
                        .foregroundStyle(active ? Color.white : color)
                }
                Text(title).font(NexType.label).lineLimit(1)
            }
            .foregroundStyle(active ? Color.white : NexColor.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                if active { Capsule().fill(color) }
            }
            .modifier(ChipGlass(active: active))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The last played game as a big card over its own blurred cover, with Resume and Details.
    private func continueCard(_ game: Game) -> some View {
        ZStack(alignment: .leading) {
            CoverView(game: game)
                .frame(maxWidth: .infinity)
                .blur(radius: 28)
                .opacity(0.7)
                .frame(height: 176)
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .center, spacing: 16) {
                CoverView(game: game)
                    .frame(width: 104)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Continue Playing", systemImage: "clock.arrow.circlepath")
                        .font(NexType.captionStrong)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(game.name)
                        .font(NexType.title(20))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(continueLine(game))
                        .font(NexType.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Button {
                            NexHaptics.press()
                            playing = game
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                                .font(NexType.label.weight(.bold))
                                .foregroundStyle(NexColor.onAccent)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(NexColor.accentGradient, in: Capsule())
                        }
                        .buttonStyle(PressScaleStyle())
                        Button { detail = game } label: {
                            Image(systemName: "info")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .nexGlass(in: Circle(), interactive: true)
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel("Game page")
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(height: 176)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(game.tagColor ?? NexColor.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .focusRing(focusID == game.id)
        .id(game.id)
        .onTapGesture { detail = game }
        .contextMenu { contextMenu(for: game) }
    }

    private func continueLine(_ game: Game) -> String {
        var parts = [game.engine.badge, formatHours(game.playSeconds)]
        if let last = game.lastPlayed { parts.append(last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var selectionBar: some View {
        HStack {
            Button("Cancel") { selecting = false; selection = [] }
            Spacer()
            Menu {
                ForEach(collections.collections) { collection in
                    Button(collection.name) { collections.add(Array(selection), to: collection.id) }
                }
            } label: { Label("Add to", systemImage: "folder.badge.plus") }
                .disabled(selection.isEmpty || collections.collections.isEmpty)
            Spacer()
            Button(role: .destructive) {
                pendingDelete = store.games.filter { selection.contains($0.id) }
            } label: { Label("Delete (\(selection.count))", systemImage: "trash") }
                .disabled(selection.isEmpty)
        }
        .font(NexType.label)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .nexGlass(in: RoundedRectangle(cornerRadius: NexMetrics.cornerL, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            if hasHiddenContent {
                Button {
                    if privacy.isUnlocked { privacy.lock() } else { Task { await privacy.unlock() } }
                } label: { Image(systemName: privacy.isUnlocked ? "lock.open" : "lock") }
                    .accessibilityLabel(privacy.isUnlocked ? "Hide hidden games" : "Show hidden games")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(LibrarySortOrder.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                    Label("List", systemImage: "list.bullet").tag("list")
                }
                Button { selecting = true; selection = [] } label: { Label("Select", systemImage: "checkmark.circle") }
                Divider()
                Button { showStats = true } label: { Label("Play Stats", systemImage: "chart.bar.fill") }
                Button { surprise() } label: { Label("Surprise Me", systemImage: "dice.fill") }
                    .disabled(store.games.isEmpty)
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort and view")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(NexColor.accentSoft)
            Text("No games yet").font(NexType.display(26)).foregroundStyle(NexColor.text)
            Text("Add a game as a ZIP, 7z or RAR archive, or as a folder. NexPlay plays RPG Maker MV/MZ, Ren'Py, Godot, Flash, Twine, Construct, TyranoBuilder and other HTML5 games. XP/VX/Ace games need a build with the mkxp core. Tip: open an archive from the Files app with NexPlay.")
                .font(NexType.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(NexColor.textSoft)
            Button { importFiles() } label: { Label("Add a Game", systemImage: "plus") }
                .buttonStyle(NexPrimaryButtonStyle())
            Button { importFolders() } label: { Label("Add a Game Folder", systemImage: "folder") }
                .buttonStyle(NexGlassButtonStyle())
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func tap(_ game: Game) {
        if selecting {
            if selection.contains(game.id) { selection.remove(game.id) } else { selection.insert(game.id) }
        } else if UserDefaults.standard.object(forKey: SettingsKey.tapOpensGamePage) as? Bool ?? true {
            detail = game
        } else {
            playing = game
        }
    }

    /// Opens a random game that isn't finished or dropped, preferring ones not played yet.
    private func surprise() {
        let pool = store.games.filter { isVisible($0) && $0.playStatus != .completed && $0.playStatus != .dropped }
        let fresh = pool.filter { $0.playCount == 0 }
        guard let pick = (fresh.isEmpty ? pool : fresh).randomElement() ?? store.games.filter(isVisible).randomElement() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        detail = pick
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        Button { playing = game } label: { Label("Play", systemImage: "play.fill") }
        Button { detail = game } label: { Label("Info & Settings", systemImage: "info.circle") }
        if let link = PlayLink.url(for: game) {
            Button {
                UIPasteboard.general.url = link
            } label: { Label("Copy Play Link (for Shortcuts)", systemImage: "link") }
        }
        Button { store.toggleFavorite(game) } label: {
            Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "heart.slash" : "heart")
        }
        if !collections.collections.isEmpty {
            Menu {
                ForEach(collections.collections) { collection in
                    Button {
                        collections.toggle(game.id, in: collection.id)
                    } label: {
                        if collection.gameIDs.contains(game.id) {
                            Label(collection.name, systemImage: "checkmark")
                        } else {
                            Text(collection.name)
                        }
                    }
                }
            } label: { Label("Collections", systemImage: "folder") }
        }
        Button {
            privacy.setHidden(game.id, !privacy.isHidden(game.id))
        } label: {
            Label(privacy.isHidden(game.id) ? "Unhide" : "Hide", systemImage: privacy.isHidden(game.id) ? "eye" : "eye.slash")
        }
        Button { selecting = true; selection = [game.id] } label: { Label("Select Multiple", systemImage: "checkmark.circle") }
        Button(role: .destructive) { pendingDelete = [game] } label: { Label("Delete", systemImage: "trash") }
    }

    private func deleteNow(_ games: [Game]) {
        Task {
            for game in games {
                await store.delete(game)
                collections.forget(game.id)
                privacy.setHidden(game.id, false)
                LayoutStore.delete(for: game.id)
                ExtrasStore.delete(game.id)
                CoverCache.forget(game)
            }
            selection = []
            selecting = false
            pendingDelete = []
        }
    }

    private func importFiles() {
        ImportPicker.pickFiles { urls in
            Task {
                await store.importItems(urls)
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    private func importBulk() {
        ImportPicker.pickFolders { urls in
            guard let parent = urls.first else { return }
            Task { await store.importFolderOfGames(parent) }
        }
    }

    private func importFolders() {
        ImportPicker.pickFolders { urls in
            Task { await store.importItems(urls) }
        }
    }
}

// MARK: - Collections manager

struct CollectionsManagerView: View {
    @EnvironmentObject private var collections: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renaming: GameCollection?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New collection", text: $newName)
                        Button("Add") {
                            collections.create(name: newName)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(collections.collections) { collection in
                        HStack {
                            Circle().fill(collection.color).frame(width: 14, height: 14)
                            Text(collection.name)
                            if collection.isHidden { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(collection.gameIDs.count)").foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Rename") { renameText = collection.name; renaming = collection }
                            Menu("Color") {
                                ForEach(0..<GameCollection.palette.count, id: \.self) { index in
                                    Button("Color \(index + 1)") { collections.change(collection.id) { $0.colorIndex = index } }
                                }
                            }
                            Button(collection.isHidden ? "Unhide" : "Hide (Face ID)") {
                                collections.change(collection.id) { $0.isHidden.toggle() }
                            }
                            Button("Delete", role: .destructive) { collections.delete(collection.id) }
                        }
                        .swipeActions {
                            Button(role: .destructive) { collections.delete(collection.id) } label: { Label("Delete", systemImage: "trash") }
                            Button { collections.change(collection.id) { $0.colorIndex += 1 } } label: { Label("Color", systemImage: "paintpalette") }
                                .tint(collection.color)
                        }
                    }
                    .onMove { collections.move(from: $0, to: $1) }
                } footer: {
                    Text("Long-press a collection to rename, recolor, hide or delete it. Drag to reorder. Deleting a collection keeps its games.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { dismiss() } }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        collections.change(target.id) { $0.name = renameText }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }
}

// MARK: - Backup opened from Files

/// Picks the game a save backup ZIP (opened from another app) should go into.
struct BackupTargetPicker: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let zip: URL
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.games.filter { $0.engine.isRPGMaker }) { game in
                        Button { restore(into: game) } label: { GameRow(game: game) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("The saves in \(zip.lastPathComponent) go into the game you pick. Its current saves are backed up first and replaced files are kept as .nex-displaced.bak copies.")
                }
            }
            .navigationTitle("Restore Saves Into")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
            .alert("Saves", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil; dismiss() } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func restore(into game: Game) {
        let url = zip
        Task {
            do {
                if game.usesNWMode {
                    let count = try await Task.detached { try SaveArchive.restore(zip: url, into: game) }.value
                    message = "Restored \(count) save file(s) into \(game.name)."
                } else {
                    message = "\(game.name) is not in NW.js mode, so it can't use save files."
                }
            } catch {
                message = "Restore failed: \(error.localizedDescription)"
            }
        }
    }
}

/// 8.1.1: glass behind inactive library chips (active ones are filled with their colour).
private struct ChipGlass: ViewModifier {
    let active: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content
        } else {
            content.nexGlassCapsule(interactive: true)
        }
    }
}
