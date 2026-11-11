import SwiftUI
import UniformTypeIdentifiers

struct GameDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID
    /// Called with the game when the user taps Play.
    let onPlay: (Game) -> Void

    @State private var sizeText = "…"
    @State private var saveInfo = SaveInfo()
    @State private var confirmDelete = false
    @State private var confirmWipe = false
    @State private var confirmDeleteSaves = false
    @State private var shareURL: URL?
    @State private var pickingZip = false
    @State private var pendingRestore: URL?
    @State private var message: String?
    @State private var backupList: [BackupEntry] = []
    @State private var pendingBackupRestore: BackupEntry?
    @State private var showPlugins = false

    private var game: Game? { store.game(id: gameID) }

    private func binding<T>(_ keyPath: WritableKeyPath<Game, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { game?[keyPath: keyPath] ?? fallback },
            set: { value in store.mutate(gameID) { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        NavigationStack {
            if let game {
                Form {
                    Section {
                        HStack(spacing: 14) {
                            CoverView(game: game).frame(width: 84)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.engine.title).font(.subheadline).foregroundStyle(.secondary)
                                Text(sizeText).font(.caption).foregroundStyle(.secondary)
                                Text("Played \(game.playCount)× · \(formatDuration(game.playSeconds))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            dismiss()
                            onPlay(game)
                        } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    }

                    Section("Name") {
                        TextField("Name", text: binding(\.name, default: ""))
                    }

                    Section("Play") {
                        Picker("Orientation", selection: binding(\.orientation, default: .auto)) {
                            ForEach(OrientationMode.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("On-screen controls", isOn: binding(\.gamepad, default: false))
                        Toggle("Stats overlay (FPS, battery)", isOn: Binding(
                            get: { game.statsOverlay ?? false },
                            set: { value in store.mutate(gameID) { $0.statsOverlay = value } }
                        ))
                        Toggle("Block internet", isOn: binding(\.blockNetwork, default: false))
                        if game.engine.isRPGMaker {
                            Stepper("Fast-forward button: \(game.fastForwardSpeed ?? 2)×", value: Binding(
                                get: { game.fastForwardSpeed ?? 2 },
                                set: { value in store.mutate(gameID) { $0.fastForwardSpeed = value } }
                            ), in: 2...9)
                            Button("Plugins…") { showPlugins = true }
                            Button("Use Default Touch Layout") { LayoutStore.reset(gameID) }
                                .disabled(!LayoutStore.hasGameLayout(gameID))
                        }
                    }

                    Section("Organize") {
                        Toggle("Hidden (Face ID)", isOn: Binding(
                            get: { privacy.isHidden(gameID) },
                            set: { privacy.setHidden(gameID, $0) }
                        ))
                        ForEach(collections.collections) { collection in
                            Toggle(collection.name, isOn: Binding(
                                get: { collection.gameIDs.contains(gameID) },
                                set: { _ in collections.toggle(gameID, in: collection.id) }
                            ))
                        }
                    }

                    if game.engine.isRPGMaker {
                        Section {
                            Toggle("NW.js mode (saves as files)", isOn: Binding(
                                get: { game.usesNWMode },
                                set: { value in store.mutate(gameID) { $0.nwMode = value } }
                            ))
                            if game.nwMode != nil {
                                Button("Use the app setting") { store.mutate(gameID) { $0.nwMode = nil } }
                            }
                        } footer: {
                            Text("In NW.js mode the game runs as on a PC and keeps its saves as files in save/. The first start in this mode copies old browser saves into files; the old data is kept.")
                        }
                    }

                    if game.usesNWMode {
                        savesSection(game)
                        backupsSection(game)
                    }

                    Section {
                        Button("Delete Browser Data", role: .destructive) { confirmWipe = true }
                        Button("Delete Game", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deleting a game moves its save files to Rescued Saves; importing the same game again offers to put them back. Browser data (saves of games not in NW.js mode) is deleted with the game: back it up from the game menu first.")
                    }
                }
                .navigationTitle(game.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
                }
                .task { await refresh(game) }
                .sheet(item: Binding(
                    get: { shareURL.map { ShareItem(url: $0) } },
                    set: { if $0 == nil { shareURL = nil } }
                )) { item in
                    ActivityView(items: [item.url])
                }
                .fileImporter(isPresented: $pickingZip, allowedContentTypes: [.zip]) { result in
                    if case .success(let url) = result { pendingRestore = url }
                }
                .confirmationDialog("Restore saves into \(game.name)?", isPresented: Binding(
                    get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }
                ), titleVisibility: .visible) {
                    Button("Restore") {
                        if let url = pendingRestore { restore(url, into: game) }
                        pendingRestore = nil
                    }
                } message: {
                    Text("Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.")
                }
                .confirmationDialog("Delete the save files of \(game.name)?", isPresented: $confirmDeleteSaves, titleVisibility: .visible) {
                    Button("Delete Saves", role: .destructive) { deleteSaves(of: game) }
                } message: {
                    Text("A backup ZIP is kept in the app's Backups folder.")
                }
                .confirmationDialog("Delete browser data for \(game.name)?", isPresented: $confirmWipe, titleVisibility: .visible) {
                    Button("Delete Browser Data", role: .destructive) {
                        Task { await DataStores.wipe(for: game) }
                    }
                } message: {
                    Text("This removes the game's web storage (browser-mode saves). Save files are not touched. This can't be undone.")
                }
                .confirmationDialog("Delete \(game.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Game", role: .destructive) {
                        Task {
                            await store.delete(game)
                            collections.forget(game.id)
                            privacy.setHidden(game.id, false)
                            LayoutStore.delete(for: game.id)
                            dismiss()
                        }
                    }
                } message: {
                    Text("The game, its layout and its backups are removed. Its save files are kept in Rescued Saves.")
                }
                .sheet(isPresented: $showPlugins) { PluginListView(game: game) }
                .confirmationDialog("Restore this backup into \(game.name)?", isPresented: Binding(
                    get: { pendingBackupRestore != nil },
                    set: { if !$0 { pendingBackupRestore = nil } }
                ), titleVisibility: .visible) {
                    Button("Restore") {
                        if let entry = pendingBackupRestore { restore(entry.url, into: game) }
                        pendingBackupRestore = nil
                    }
                } message: {
                    Text("Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.")
                }
                .alert("Saves", isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(message ?? "")
                }
            }
        }
    }

    @ViewBuilder
    private func savesSection(_ game: Game) -> some View {
        Section {
            LabeledContent("Save files", value: "\(saveInfo.count)")
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: saveInfo.bytes, countStyle: .file))
            if let newest = saveInfo.newest {
                LabeledContent("Last save", value: newest.formatted(date: .abbreviated, time: .shortened))
            }
            if saveInfo.displaced > 0 {
                LabeledContent("Displaced copies", value: "\(saveInfo.displaced)")
            }
            Button { export(game) } label: { Label("Export Saves (ZIP)", systemImage: "square.and.arrow.up") }
                .disabled(saveInfo.count == 0)
            Button { pickingZip = true } label: { Label("Import Saves (ZIP)", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { confirmDeleteSaves = true } label: { Label("Delete Saves", systemImage: "trash") }
                .disabled(saveInfo.count == 0)
        } header: {
            Text("Saves")
        } footer: {
            if saveInfo.displaced > 0 {
                Text("Displaced copies (.nex-displaced.bak) are older saves kept when a restore replaced them.")
            }
        }
    }

    @ViewBuilder
    private func backupsSection(_ game: Game) -> some View {
        Section {
            Button { backUpNow(game) } label: { Label("Back Up Now", systemImage: "clock.arrow.circlepath") }
                .disabled(saveInfo.count == 0)
            ForEach(backupList) { entry in
                Button { pendingBackupRestore = entry } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        Text(entry.name.hasPrefix("before-") ? "Safety copy · \(entry.name)" : ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            Text(backupList.isEmpty ? "No backups yet." : "Tap a backup to restore it.")
        }
    }

    private func backUpNow(_ game: Game) {
        Task {
            _ = await Task.detached { AutoBackup.run(game, force: true) }.value
            await refresh(game)
        }
    }

    private func refresh(_ game: Game) async {
        let folder = Paths.folder(for: game)
        let target = game
        let result = await Task.detached { (GameScanner.size(of: folder), SaveArchive.info(for: target)) }.value
        sizeText = ByteCountFormatter.string(fromByteCount: result.0, countStyle: .file)
        saveInfo = result.1
        backupList = await Task.detached { SaveArchive.backups(for: target) }.value
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
            await refresh(game)
        }
    }

    private func deleteSaves(of game: Game) {
        Task {
            do {
                try await Task.detached { try SaveArchive.deleteSaves(of: game) }.value
            } catch {
                message = error.localizedDescription
            }
            await refresh(game)
        }
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
