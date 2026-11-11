import SwiftUI

struct GameDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID
    /// Called with the game when the user taps Play.
    let onPlay: (Game) -> Void

    @State private var sizeText = "…"
    @State private var confirmDelete = false
    @State private var confirmWipe = false

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
                    }

                    Section {
                        Button("Delete Saves and Game Data", role: .destructive) { confirmWipe = true }
                        Button("Delete Game", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deleting a game also deletes its saves. Back them up from the in-game menu first.")
                    }
                }
                .navigationTitle(game.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
                }
                .task {
                    let folder = Paths.folder(for: game)
                    let bytes = await Task.detached { GameScanner.size(of: folder) }.value
                    sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                }
                .confirmationDialog("Delete saves and data for \(game.name)?", isPresented: $confirmWipe, titleVisibility: .visible) {
                    Button("Delete Saves", role: .destructive) {
                        Task { await DataStores.wipe(for: game) }
                    }
                } message: {
                    Text("This can't be undone.")
                }
                .confirmationDialog("Delete \(game.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Game", role: .destructive) {
                        Task {
                            await store.delete(game)
                            dismiss()
                        }
                    }
                } message: {
                    Text("The game and its saves will be removed. This can't be undone.")
                }
            }
        }
    }
}
