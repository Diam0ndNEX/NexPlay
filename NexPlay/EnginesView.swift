import SwiftUI

/// The bundled runtimes a game can run on (Godot, Ren'Py), for Game Settings and the in-game menu.
enum EngineRuntimes {
    /// Versions the game can pick, newest first.
    static func choices(for game: Game) -> [String] {
        switch game.engine {
        case .godot:
            guard game.isGodotDesktop,
                  let version = GodotRuntime.packVersion(Paths.folder(for: game).appendingPathComponent(game.entry)) else { return [] }
            return GodotRuntime.compatible(with: version).reversed().map { $0.description }
        case .renpy:
            return RenPyRuntime.bundled.reversed().map { $0.description }
        default:
            return []
        }
    }

    /// The runtime "Automatic" picks, and the version the game was made with.
    static func automatic(for game: Game) -> (runtime: String?, made: String?) {
        switch game.engine {
        case .godot:
            guard game.isGodotDesktop,
                  let version = GodotRuntime.packVersion(Paths.folder(for: game).appendingPathComponent(game.entry)) else { return (nil, nil) }
            return (GodotRuntime.runtime(for: version)?.description, version.description)
        case .renpy:
            let version = RenPyRuntime.gameVersion(base: RenPyRuntime.baseFolder(for: game))
            return (RenPyRuntime.runtime(for: version, override: nil)?.description, version?.description)
        default:
            return (nil, nil)
        }
    }

    static func engineName(_ engine: GameEngine) -> String {
        engine == .renpy ? "Ren'Py" : "Godot"
    }
}

/// Settings > Advanced > Engines & Runtimes: what this build can run, and the space unpacked runtimes take.
struct EnginesSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false

    private var cacheFolders: [URL] {
        ["GodotRuntimes", "RenPyRuntimes", "RenPyCache"].map { Paths.support.appendingPathComponent($0, isDirectory: true) }
    }

    var body: some View {
        Form {
            Section {
                engineRow("RPG Maker MV / MZ", symbol: GameEngine.rpgMV.symbol, detail: "Built in. NW.js mode keeps saves as files.", ok: true)
                engineRow("RPG Maker XP / VX / Ace", symbol: GameEngine.rpgVXAce.symbol,
                          detail: RubyCore.runner.isAvailable ? "mkxp core included in this build." : "Needs a build with the mkxp core.",
                          ok: RubyCore.runner.isAvailable)
                engineRow("Ren'Py", symbol: GameEngine.renpy.symbol,
                          detail: list(RenPyRuntime.bundled.map { $0.description }, empty: "No runtime in this build."),
                          ok: !RenPyRuntime.bundled.isEmpty)
                engineRow("Godot (desktop .pck / .exe)", symbol: GameEngine.godot.symbol,
                          detail: list(GodotRuntime.bundled.map { $0.description }, empty: "No runtime in this build."),
                          ok: !GodotRuntime.bundled.isEmpty)
                engineRow("Flash (.swf)", symbol: GameEngine.flash.symbol,
                          detail: FlashRuntime.version.map { "Ruffle \($0)" } ?? "Ruffle is not in this build.",
                          ok: FlashRuntime.folder != nil)
                engineRow("HTML5, Godot web, Construct, Twine, Tyrano", symbol: GameEngine.web.symbol,
                          detail: "Built in.", ok: true)
            } header: {
                SettingsHeader(title: "Engines in This Build", symbol: "cpu.fill", color: .teal)
            } footer: {
                Text("Ren'Py and Godot games pick a runtime automatically. To try another one, open the game's settings (Engine) or the Runtime entry in the in-game menu.")
            }
            Section {
                LabeledContent("Unpacked runtimes and Ren'Py packages", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear Runtime Cache", systemImage: "trash")
                }
                .disabled(cacheSize == 0)
            } footer: {
                Text("Runtimes are unpacked on first use and Ren'Py games get a package on their first start. Clearing them frees space; they are made again when needed. Saves are not touched.")
            }
            Section {
                ForEach(engineCounts) { item in
                    LabeledContent(item.id, value: "\(item.count)")
                }
            } header: {
                Text("Your Library")
            }
        }
        .navigationTitle("Engines & Runtimes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .confirmationDialog("Clear the runtime cache?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                for folder in cacheFolders { try? FileManager.default.removeItem(at: folder) }
                Task { await measure() }
            }
        }
    }

    private struct CountRow: Identifiable {
        let id: String
        let count: Int
    }

    private var engineCounts: [CountRow] {
        var counts: [String: Int] = [:]
        for game in store.games { counts[game.engine.title, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { CountRow(id: $0.key, count: $0.value) }
    }

    private func list(_ versions: [String], empty: String) -> String {
        versions.isEmpty ? empty : "Runtimes: " + versions.joined(separator: ", ")
    }

    private func engineRow(_ title: String, symbol: String, detail: String, ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(ok ? Color.teal : Color.gray, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private func measure() async {
        let folders = cacheFolders
        cacheSize = await Task.detached(priority: .utility) {
            folders.reduce(Int64(0)) { $0 + GameScanner.size(of: $1) }
        }.value
    }
}
