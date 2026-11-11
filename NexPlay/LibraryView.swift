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
            guard let url = Paths.coverURL(for: target), let image = UIImage(contentsOfFile: url.path) else { return nil }
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

    private var hue: Double {
        let sum = game.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double(sum % 360) / 360
    }

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
        Text(engine.badge)
            .font(.caption2.bold())
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
            CoverView(game: game)
                .overlay(alignment: .top) {
                    HStack {
                        EngineBadge(engine: game.engine)
                        Spacer()
                        if game.isFavorite {
                            Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    if !titleUnder {
                        Text(game.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selected ? Color.accentColor : .white)
                            .padding(8)
                    }
                }
            if titleUnder {
                Text(game.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(formatDuration(game.playSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            CoverView(game: game).frame(width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(game.engine.title) · \(formatDuration(game.playSeconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if game.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A filter chip at the top of the library: everything, an engine, favorites, or a collection.
enum LibraryFilter: Hashable {
    case all, favorites, engine(GameEngine), collection(UUID)
}

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
    @State private var showSettings = false
    @State private var showCollections = false
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: [Game] = []
    @State private var sizes: [UUID: Int64] = [:]
    @State private var shareURL: URL?

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
        guard showContinue, filter == .all, search.isEmpty, !selecting else { return nil }
        return store.games.filter(isVisible).filter { $0.lastPlayed != nil }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
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
        NavigationStack {
            ZStack(alignment: .bottom) {
                if store.games.isEmpty && !store.isImporting {
                    emptyState
                } else {
                    content
                }
                if selecting { selectionBar }
                if store.isImporting {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(store.importStatus.isEmpty ? "Importing…" : store.importStatus)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("Cancel", role: .cancel) { store.cancelImport() }
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle("NexPlay")
            .searchable(text: $search, prompt: "Search games")
            .toolbar { toolbar }
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
        .sheet(item: $detail) { game in
            GameDetailView(gameID: game.id) { detail = nil; playing = $0 }
                .environmentObject(collections)
                .environmentObject(privacy)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .sheet(isPresented: $showCollections) {
            CollectionsManagerView().environmentObject(collections)
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

    private var deleteTitle: String {
        if pendingDelete.count == 1, let game = pendingDelete.first { return "Delete \(game.name)?" }
        return "Delete \(pendingDelete.count) games?"
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                chips
                if let game = continueGame { continueCard(game) }
                if visible.isEmpty {
                    Text(search.isEmpty ? "Nothing here yet." : "No games match \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if layout == "list" {
                    LazyVStack(spacing: 10) {
                        ForEach(visible) { game in
                            GameRow(game: game, selected: selecting ? selection.contains(game.id) : nil)
                                .onTapGesture { tap(game) }
                                .contextMenu { contextMenu(for: game) }
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                        ForEach(visible) { game in
                            GameCard(game: game, titleUnder: titleUnder, selected: selecting ? selection.contains(game.id) : nil)
                                .contentShape(Rectangle())
                                .onTapGesture { tap(game) }
                                .contextMenu { contextMenu(for: game) }
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, selecting ? 70 : 0)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", color: .gray, active: filter == .all) { filter = .all }
                chip("Favorites", color: .pink, active: filter == .favorites) { filter = .favorites }
                ForEach(engines, id: \.self) { engine in
                    chip(engine.badge, color: .indigo, active: filter == .engine(engine)) { filter = .engine(engine) }
                }
                ForEach(visibleCollections) { collection in
                    chip(collection.name, color: collection.color, active: filter == .collection(collection.id),
                         locked: collection.isHidden) { filter = .collection(collection.id) }
                }
                Button { showCollections = true } label: {
                    Image(systemName: "folder.badge.plus").padding(.horizontal, 8)
                }
                .accessibilityLabel("Manage collections")
            }
        }
    }

    private func chip(_ title: String, color: Color, active: Bool, locked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if locked { Image(systemName: "lock.fill").font(.caption2) }
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(active ? color.opacity(0.85) : color.opacity(0.22), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func continueCard(_ game: Game) -> some View {
        Button { playing = game } label: {
            HStack(spacing: 14) {
                CoverView(game: game).frame(width: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue playing").font(.caption).foregroundStyle(.secondary)
                    Text(game.name).font(.headline).lineLimit(2)
                    Text(formatDuration(game.playSeconds)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.system(size: 36))
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
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
        .padding()
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
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
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort and view")
            Menu {
                Button { importFiles() } label: { Label("Files or ZIP…", systemImage: "doc.zipper") }
                Button { importFolders() } label: { Label("Folder…", systemImage: "folder") }
            } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add games")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("No games yet").font(.title2.bold())
            Text("Add an RPG Maker MV/MZ or HTML5 game as a ZIP or a folder. XP/VX/Ace games can be added too; they need a build with the mkxp core to start. Tip: open a ZIP from the Files app with NexPlay.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { importFiles() } label: { Label("Add a Game", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func tap(_ game: Game) {
        if selecting {
            if selection.contains(game.id) { selection.remove(game.id) } else { selection.insert(game.id) }
        } else {
            playing = game
        }
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        Button { playing = game } label: { Label("Play", systemImage: "play.fill") }
        Button { detail = game } label: { Label("Info & Settings", systemImage: "info.circle") }
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
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
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
