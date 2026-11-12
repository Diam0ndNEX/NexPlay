import SwiftUI

/// Settings > Advanced > Storage: what takes space (games, backups, rescued saves, runtimes, caches) and ways to
/// free it. Saves are only removed when the user deletes a rescued-saves folder explicitly.
struct StorageView: View {
    @EnvironmentObject private var store: LibraryStore

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let url: URL
        let bytes: Int64
    }

    @State private var games: [Item] = []
    @State private var rescued: [Item] = []
    @State private var backupsBytes: Int64 = 0
    @State private var runtimeBytes: Int64 = 0
    @State private var tempBytes: Int64 = 0
    @State private var freeBytes: Int64?
    @State private var loading = true
    @State private var pendingRescued: Item?
    @State private var confirmRuntime = false

    private var runtimeFolders: [URL] {
        ["GodotRuntimes", "RenPyRuntimes", "RenPyCache"].map { Paths.support.appendingPathComponent($0, isDirectory: true) }
    }

    private var gamesBytes: Int64 { games.reduce(0) { $0 + $1.bytes } }
    private var rescuedBytes: Int64 { rescued.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { ProgressView(); Text("Measuring…").foregroundStyle(.secondary) }
                } else {
                    usageBar
                    row("Games", gamesBytes, color: .purple)
                    row("Save Backups", backupsBytes, color: .green)
                    row("Rescued Saves", rescuedBytes, color: .orange)
                    row("Runtimes and Ren'Py Packages", runtimeBytes, color: .teal)
                    row("Temporary Files", tempBytes, color: .gray)
                    if let freeBytes {
                        LabeledContent("Free on This iPhone", value: format(freeBytes))
                    }
                }
            } header: {
                SettingsHeader(title: "Storage", symbol: "internaldrive.fill", color: .indigo)
            }

            Section {
                Button(role: .destructive) { confirmRuntime = true } label: {
                    Label("Clear Runtimes and Ren'Py Packages", systemImage: "cpu")
                }
                .disabled(runtimeBytes == 0)
                Button {
                    clearTemporary()
                } label: {
                    Label("Clear Temporary Files", systemImage: "trash")
                }
                .disabled(tempBytes == 0 || store.isImporting)
            } footer: {
                Text("Runtimes are unpacked again and Ren'Py games are packed again on their next start. Temporary files are leftovers from imports, exports and shared files. Neither holds saves.")
            }

            if !games.isEmpty {
                Section("Games by Size") {
                    ForEach(games) { item in
                        LabeledContent {
                            Text(format(item.bytes)).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section {
                if rescued.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(rescued) { item in
                    LabeledContent {
                        Text(format(item.bytes)).monospacedDigit()
                    } label: {
                        Text(item.title).lineLimit(2)
                    }
                    .swipeActions {
                        Button(role: .destructive) { pendingRescued = item } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Rescued Saves")
            } footer: {
                Text("Saves kept from deleted games. Importing the same game again offers to put them back. Swipe to delete one for good.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .refreshable { await measure() }
        .confirmationDialog("Clear runtimes and Ren'Py packages?", isPresented: $confirmRuntime, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                for folder in runtimeFolders { try? FileManager.default.removeItem(at: folder) }
                Task { await measure() }
            }
        }
        .confirmationDialog("Delete these rescued saves for good?", isPresented: Binding(
            get: { pendingRescued != nil }, set: { if !$0 { pendingRescued = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = pendingRescued {
                    try? FileManager.default.removeItem(at: item.url)
                    AppLog.log("deleted rescued saves \(item.title)")
                }
                pendingRescued = nil
                Task { await measure() }
            }
        } message: {
            Text(pendingRescued?.title ?? "")
        }
    }

    private var usageBar: some View {
        let parts: [(Int64, Color)] = [(gamesBytes, .purple), (backupsBytes, .green), (rescuedBytes, .orange),
                                       (runtimeBytes, .teal), (tempBytes, .gray)]
        let total = max(parts.reduce(Int64(0)) { $0 + $1.0 }, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("NexPlay uses \(format(total))").font(.headline)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(0..<parts.count, id: \.self) { index in
                        let share = Double(parts[index].0) / Double(total)
                        if share > 0 {
                            Rectangle().fill(parts[index].1).frame(width: max(3, proxy.size.width * share))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, _ bytes: Int64, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
            Spacer()
            Text(format(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearTemporary() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        for url in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        Task { await measure() }
    }

    private func measure() async {
        let list = store.games
        let runtime = runtimeFolders
        let result = await Task.detached(priority: .utility) { () -> ([Item], [Item], Int64, Int64, Int64, Int64?) in
            let fm = FileManager.default
            let gameItems = list.map { game in
                Item(id: game.id.uuidString, title: game.name, detail: game.engine.title, url: Paths.folder(for: game),
                     bytes: GameScanner.size(of: Paths.folder(for: game)))
            }
            .sorted { $0.bytes > $1.bytes }
            let rescuedFolders = (try? fm.contentsOfDirectory(at: Paths.rescuedSaves, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? []
            let rescuedItems = rescuedFolders.map { url in
                Item(id: url.path, title: url.lastPathComponent, detail: nil, url: url, bytes: GameScanner.size(of: url))
            }
            .sorted { $0.title < $1.title }
            let backups = GameScanner.size(of: Paths.backups)
            let runtimes = runtime.reduce(Int64(0)) { $0 + GameScanner.size(of: $1) }
            let temp = GameScanner.size(of: fm.temporaryDirectory)
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values?.volumeAvailableCapacityForImportantUsage
            return (gameItems, rescuedItems, backups, runtimes, temp, free)
        }.value
        games = result.0
        rescued = result.1
        backupsBytes = result.2
        runtimeBytes = result.3
        tempBytes = result.4
        freeBytes = result.5
        loading = false
    }
}
