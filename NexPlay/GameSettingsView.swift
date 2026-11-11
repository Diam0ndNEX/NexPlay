import SwiftUI
import UniformTypeIdentifiers

// Game settings, saves and gallery pages opened from the game page. Section ideas from RPGPlayer screenshots
// (touch controls, gamepad, controller mapping, screen scaling, collection, colour, status, notes, cover);
// NexPlay's own code.

// MARK: - Game settings

struct GameSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID
    /// Called after the game was deleted, so the game page closes too.
    let onDeleted: () -> Void

    @State private var cover: UIImage?
    @State private var pickingFile = false
    @State private var pickingPhoto = false
    @State private var pickingFromGame = false
    @State private var showControllerMap = false
    @State private var confirmDelete = false
    @State private var confirmWipe = false
    @State private var message: String?

    private var game: Game? { store.game(id: gameID) }

    private func binding<T>(_ keyPath: WritableKeyPath<Game, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { game?[keyPath: keyPath] ?? fallback },
            set: { value in store.mutate(gameID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func textBinding(_ keyPath: WritableKeyPath<Game, String?>) -> Binding<String> {
        Binding(
            get: { game?[keyPath: keyPath] ?? "" },
            set: { value in store.mutate(gameID) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let game { form(game) } else { Color.clear }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Game Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await loadCover() }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { setCover(fromFile: url) }
        }
        .sheet(isPresented: $pickingPhoto) {
            PhotoPicker { image in
                pickingPhoto = false
                if let image, let game { CoverStore.setCover(image, for: game); Task { await loadCover() } }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $pickingFromGame) {
            if let game {
                GameFolderCoverPicker(game: game) { Task { await loadCover() } }
            }
        }
        .sheet(isPresented: $showControllerMap) {
            if let game { ControllerMapView(gameID: game.id, gameName: game.name) }
        }
        .alert("Game Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func form(_ game: Game) -> some View {
        Form {
            detailsSection(game)
            coverSection(game)
            progressSection(game)
            organizationSection(game)
            controlsSection(game)
            screenSection(game)
            if game.engine.isRPGMaker { engineSection(game) }
            notesSection
            dangerSection(game)
        }
        .confirmationDialog("Delete \(game.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Game", role: .destructive) { delete(game) }
        } message: {
            Text("The game, its layout, cover, gallery and backups are removed. Its save files are kept in Rescued Saves.")
        }
        .confirmationDialog("Delete browser data for \(game.name)?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete Browser Data", role: .destructive) {
                Task { await DataStores.wipe(for: game) }
            }
        } message: {
            Text("This removes the game's web storage (browser-mode saves). Save files are not touched. This can't be undone.")
        }
    }

    // MARK: Sections

    private func detailsSection(_ game: Game) -> some View {
        Section {
            TextField("Name", text: binding(\.name, default: ""))
                .font(.headline)
            TextField("Developer", text: textBinding(\.developer))
            TextField("Version", text: textBinding(\.version))
            LabeledContent("Game Type", value: game.engine.title)
        } header: {
            SettingsHeader(title: "Game Details", symbol: "info.circle.fill", color: .blue)
        }
    }

    private func coverSection(_ game: Game) -> some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().interpolation(.none).scaledToFill()
                    } else {
                        CoverView(game: game)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cover Image").font(.headline)
                    Text(CoverStore.hasCustomCover(game) ? "Custom" : "Default")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button { pickingFile = true } label: { Label("From Files", systemImage: "folder.fill.badge.plus") }
            Button { pickingPhoto = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
            Button { pickingFromGame = true } label: { Label("From Game Folder", systemImage: "shippingbox.fill") }
            if CoverStore.hasCustomCover(game) {
                Button(role: .destructive) {
                    CoverStore.resetCover(for: game)
                    Task { await loadCover() }
                } label: { Label("Use Default Cover", systemImage: "arrow.uturn.backward") }
            }
        } header: {
            SettingsHeader(title: "Cover", symbol: "photo.fill", color: .pink)
        } footer: {
            Text("Choose a cover from your files, your photo library, or an image inside the game, without leaving the app.")
        }
    }

    private func progressSection(_ game: Game) -> some View {
        Section {
            Picker(selection: Binding(
                get: { game.playStatus },
                set: { value in store.mutate(gameID) { $0.status = value } }
            )) {
                ForEach(GameStatus.allCases) { status in
                    Label(status.title, systemImage: status.symbol).tag(status)
                }
            } label: {
                Label("Status", systemImage: "flag.fill")
            }
            Toggle(isOn: binding(\.isFavorite, default: false)) { Label("Favorite", systemImage: "heart.fill") }
            LabeledContent("Play Time", value: formatDuration(game.playSeconds))
            LabeledContent("Times Played", value: "\(game.playCount)")
            LabeledContent("Added", value: game.addedAt.formatted(date: .abbreviated, time: .omitted))
        } header: {
            SettingsHeader(title: "Progress", symbol: "chart.bar.fill", color: .green)
        }
    }

    private func organizationSection(_ game: Game) -> some View {
        Section {
            ForEach(collections.collections) { collection in
                Toggle(collection.name, isOn: Binding(
                    get: { collection.gameIDs.contains(gameID) },
                    set: { _ in collections.toggle(gameID, in: collection.id) }
                ))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Color")
                colorRow(game)
            }
            .padding(.vertical, 4)
            Toggle(isOn: Binding(get: { privacy.isHidden(gameID) }, set: { privacy.setHidden(gameID, $0) })) {
                Label("Hidden (Face ID)", systemImage: "eye.slash.fill")
            }
        } header: {
            SettingsHeader(title: "Organization", symbol: "folder.fill", color: .indigo)
        } footer: {
            if collections.collections.isEmpty {
                Text("Make collections from the library's menu to sort games into folders.")
            }
        }
    }

    private func colorRow(_ game: Game) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                colorDot(nil, selected: game.colorTag == nil)
                ForEach(GameColor.allCases) { tag in
                    colorDot(tag, selected: game.colorTag == tag.rawValue)
                }
            }
            .padding(4)
        }
    }

    private func colorDot(_ tag: GameColor?, selected: Bool) -> some View {
        Button {
            store.mutate(gameID) { $0.colorTag = tag?.rawValue }
        } label: {
            ZStack {
                if let tag {
                    Circle().fill(tag.color)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 2)
                    Image(systemName: "slash.circle").foregroundStyle(.secondary)
                }
                if selected {
                    Circle().strokeBorder(Color.white, lineWidth: 3).padding(-4)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag?.rawValue.capitalized ?? "No color")
    }

    private func controlsSection(_ game: Game) -> some View {
        Section {
            Toggle(isOn: binding(\.gamepad, default: true)) { Label("On-Screen Controls", systemImage: "gamecontroller.fill") }
            Button { showControllerMap = true } label: { Label("Controller Mapping", systemImage: "gamecontroller") }
            Button {
                LayoutStore.reset(gameID)
                message = "This game uses the default touch layout again."
            } label: { Label("Use Default Touch Layout", systemImage: "arrow.counterclockwise") }
            .disabled(!LayoutStore.hasGameLayout(gameID))
        } header: {
            SettingsHeader(title: "Controls", symbol: "dpad.fill", color: .purple)
        } footer: {
            Text("To move, resize or add buttons, open the game, tap your game's bubble and then the pencil.")
        }
    }

    private func screenSection(_ game: Game) -> some View {
        Section {
            Picker(selection: binding(\.orientation, default: OrientationMode.auto)) {
                ForEach(OrientationMode.allCases) { mode in Text(mode.title).tag(mode) }
            } label: { Label("Orientation", systemImage: "rotate.right.fill") }
            if game.engine.isRPGMaker {
                Picker(selection: Binding(
                    get: { game.screenScaling ?? "global" },
                    set: { value in store.mutate(gameID) { $0.screenScaling = value == "global" ? nil : value } }
                )) {
                    Text("Use Global (\(ScreenScaling.global.title))").tag("global")
                    ForEach(ScreenScaling.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue)
                    }
                } label: { Label("Screen Scaling", systemImage: "aspectratio.fill") }
                Stepper(value: Binding(
                    get: { game.fastForwardSpeed ?? 2 },
                    set: { value in store.mutate(gameID) { $0.fastForwardSpeed = value } }
                ), in: 2...9) {
                    Label("Fast Forward: \(game.fastForwardSpeed ?? 2)×", systemImage: "forward.fill")
                }
            }
            Toggle(isOn: Binding(
                get: { game.statsOverlay ?? false },
                set: { value in store.mutate(gameID) { $0.statsOverlay = value } }
            )) { Label("FPS Overlay", systemImage: "speedometer") }
            Toggle(isOn: binding(\.blockNetwork, default: false)) { Label("Block Internet", systemImage: "wifi.slash") }
        } header: {
            SettingsHeader(title: "Screen & Play", symbol: "display", color: .orange)
        } footer: {
            Text("Screen Scaling: Fit keeps black bars, Fill crops the edges to cover the screen, Stretch fills it and changes the shape. Applies on next launch.")
        }
    }

    private func engineSection(_ game: Game) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { game.usesNWMode },
                set: { value in store.mutate(gameID) { $0.nwMode = value } }
            )) { Label("NW.js Mode (Saves as Files)", systemImage: "doc.fill") }
            if game.nwMode != nil {
                Button("Use the App Setting") { store.mutate(gameID) { $0.nwMode = nil } }
            }
        } header: {
            SettingsHeader(title: "Engine", symbol: "cpu.fill", color: .teal)
        } footer: {
            Text("In NW.js mode the game runs as on a PC and keeps its saves as files in save/. The first start in this mode copies old browser saves into files; the old data is kept.")
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: textBinding(\.notes))
                .frame(minHeight: 110)
        } header: {
            SettingsHeader(title: "Notes", symbol: "note.text", color: .yellow)
        }
    }

    private func dangerSection(_ game: Game) -> some View {
        Section {
            Button(role: .destructive) { confirmWipe = true } label: { Label("Delete Browser Data", systemImage: "globe") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Game", systemImage: "trash.fill") }
        } footer: {
            Text("Deleting a game moves its save files to Rescued Saves; importing the same game again offers to put them back. Browser data (saves of games not in NW.js mode) is deleted with the game.")
        }
    }

    // MARK: Actions

    private func loadCover() async {
        guard let game else { return }
        CoverCache.forget(game)
        cover = await CoverCache.load(for: game)
    }

    private func setCover(fromFile url: URL) {
        guard let game else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            message = "That file isn't an image NexPlay can read."
            return
        }
        CoverStore.setCover(image, for: game)
        Task { await loadCover() }
    }

    private func delete(_ game: Game) {
        Task {
            await store.delete(game)
            collections.forget(game.id)
            privacy.setHidden(game.id, false)
            LayoutStore.delete(for: game.id)
            dismiss()
            onDeleted()
        }
    }
}

// MARK: - Cover from the game folder

struct GameFolderCoverPicker: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game
    let onPicked: () -> Void

    @State private var urls: [URL] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(40)
                } else if urls.isEmpty {
                    Text("No readable images in this game. RPG Maker games with encrypted images (.rpgmvp, .png_) can't offer covers.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(urls, id: \.self) { url in
                            Button { pick(url) } label: { Thumbnail(url: url) }
                                .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(14)
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("From Game Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            let target = game
            urls = await Task.detached(priority: .userInitiated) { CoverStore.candidates(in: target) }.value
            loading = false
        }
    }

    private func pick(_ url: URL) {
        guard let image = UIImage(contentsOfFile: url.path) else { return }
        CoverStore.setCover(image, for: game)
        onPicked()
        dismiss()
    }
}

/// A square thumbnail of an image file, decoded off the main thread.
struct Thumbnail: View {
    let url: URL
    var aspect: CGFloat = 1
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: url) {
                let path = url.path
                image = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let full = UIImage(contentsOfFile: path) else { return nil }
                    return full.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? full
                }.value
            }
    }
}

// MARK: - Saves

struct GameSavesView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var saveInfo = SaveInfo()
    @State private var backupList: [BackupEntry] = []
    @State private var shareURL: URL?
    @State private var pickingZip = false
    @State private var pendingRestore: URL?
    @State private var pendingBackupRestore: BackupEntry?
    @State private var confirmDeleteSaves = false
    @State private var message: String?

    private var game: Game? { store.game(id: gameID) }

    var body: some View {
        NavigationStack {
            Group {
                if let game { content(game) } else { Color.clear }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Saves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await refresh() }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { item in
            ActivityView(items: [item.url])
        }
        .fileImporter(isPresented: $pickingZip, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { pendingRestore = url }
        }
        .alert("Saves", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    @ViewBuilder
    private func content(_ game: Game) -> some View {
        if game.usesNWMode {
            fileSaves(game)
        } else {
            Form {
                Section {
                    Label("This game keeps its saves in web storage (browser mode).", systemImage: "globe")
                    Text("Back them up from the game: open the game, tap its bubble, then the gear, then Saves. Turn on NW.js mode in Game Settings to keep saves as files that NexPlay can export, back up and rescue.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fileSaves(_ game: Game) -> some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    summaryTile("\(saveInfo.count)", "Saves", "doc.fill")
                    summaryTile(ByteCountFormatter.string(fromByteCount: saveInfo.bytes, countStyle: .file), "Size", "internaldrive.fill")
                    summaryTile(saveInfo.newest.map { $0.formatted(.relative(presentation: .named)) } ?? "—", "Last Save", "clock.fill")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Button { export(game) } label: { Label("Export Saves (ZIP)", systemImage: "square.and.arrow.up") }
                    .disabled(saveInfo.count == 0)
                Button { pickingZip = true } label: { Label("Import Saves (ZIP)", systemImage: "square.and.arrow.down") }
                Button { backUpNow(game) } label: { Label("Back Up Now", systemImage: "clock.arrow.circlepath") }
                    .disabled(saveInfo.count == 0)
                Button(role: .destructive) { confirmDeleteSaves = true } label: { Label("Delete Saves", systemImage: "trash") }
                    .disabled(saveInfo.count == 0)
            } header: {
                SettingsHeader(title: "Manage", symbol: "externaldrive.fill", color: .purple)
            } footer: {
                if saveInfo.displaced > 0 {
                    Text("\(saveInfo.displaced) displaced copies (.nex-displaced.bak) are older saves kept when a restore replaced them.")
                }
            }
            Section {
                if backupList.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(backupList) { entry in
                    Button { pendingBackupRestore = entry } label: {
                        HStack {
                            Image(systemName: entry.name.hasPrefix("before-") ? "shield.lefthalf.filled" : "archivebox.fill")
                                .foregroundStyle(NexStyle.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                                Text(entry.name.hasPrefix("before-") ? "Safety copy" : ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                SettingsHeader(title: "Backups", symbol: "clock.arrow.circlepath", color: .blue)
            } footer: {
                Text("Tap a backup to restore it. Current saves are backed up first.")
            }
        }
        .confirmationDialog("Restore saves into \(game.name)?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), titleVisibility: .visible) {
            Button("Restore") {
                if let url = pendingRestore { restore(url, into: game) }
                pendingRestore = nil
            }
        } message: {
            Text("Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.")
        }
        .confirmationDialog("Restore this backup into \(game.name)?", isPresented: Binding(
            get: { pendingBackupRestore != nil }, set: { if !$0 { pendingBackupRestore = nil } }
        ), titleVisibility: .visible) {
            Button("Restore") {
                if let entry = pendingBackupRestore { restore(entry.url, into: game) }
                pendingBackupRestore = nil
            }
        } message: {
            Text("Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.")
        }
        .confirmationDialog("Delete the save files of \(game.name)?", isPresented: $confirmDeleteSaves, titleVisibility: .visible) {
            Button("Delete Saves", role: .destructive) { deleteSaves(of: game) }
        } message: {
            Text("A backup ZIP is kept in the app's Backups folder.")
        }
    }

    private func summaryTile(_ value: String, _ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(NexStyle.accent)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func refresh() async {
        guard let game else { return }
        let target = game
        saveInfo = await Task.detached { SaveArchive.info(for: target) }.value
        backupList = await Task.detached { SaveArchive.backups(for: target) }.value
    }

    private func backUpNow(_ game: Game) {
        Task {
            _ = await Task.detached { AutoBackup.run(game, force: true) }.value
            await refresh()
        }
    }

    private func export(_ game: Game) {
        Task {
            do {
                shareURL = try await Task.detached { try SaveArchive.exportZip(for: game) }.value
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func restore(_ url: URL, into game: Game) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try await Task.detached { try SaveArchive.restore(zip: url, into: game) }.value
                message = "Restored \(count) save file(s)."
            } catch {
                message = "Restore failed: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func deleteSaves(of game: Game) {
        Task {
            do {
                try await Task.detached { try SaveArchive.deleteSaves(of: game) }.value
            } catch {
                message = error.localizedDescription
            }
            await refresh()
        }
    }
}

// MARK: - Gallery

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game

    @State private var shots: [GalleryShot] = []
    @State private var viewing: GalleryShot?

    var body: some View {
        NavigationStack {
            ScrollView {
                if shots.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 44)).foregroundStyle(NexStyle.accent)
                        Text("No screenshots yet").font(.headline)
                        Text("In a game, tap its bubble and then the camera. Screenshots land here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(shots) { shot in
                            Button { viewing = shot } label: {
                                Thumbnail(url: shot.url, aspect: 16.0 / 10.0)
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(14)
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { reload() }
        .fullScreenCover(item: $viewing) { shot in
            ShotViewer(game: game, shot: shot) {
                viewing = nil
                reload()
            }
        }
    }

    private func reload() {
        shots = Gallery.shots(for: game)
    }
}

private struct ShotViewer: View {
    let game: Game
    let shot: GalleryShot
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var share = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                ProgressView()
            }
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                if let note {
                    Text(note).font(.footnote.weight(.semibold)).padding(10).background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 14) {
                    viewerButton("square.and.arrow.up", "Share") { share = true }
                    viewerButton("photo.fill", "Set as Cover") {
                        if let image {
                            CoverStore.setCover(image, for: game)
                            note = "Cover updated."
                        }
                    }
                    viewerButton("trash.fill", "Delete") {
                        Gallery.delete(shot)
                        onClose()
                    }
                }
            }
            .padding(20)
        }
        .environment(\.colorScheme, .dark)
        .task { image = UIImage(contentsOfFile: shot.url.path) }
        .sheet(isPresented: $share) { ActivityView(items: [shot.url]) }
    }

    private func viewerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: 86, height: 58)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
