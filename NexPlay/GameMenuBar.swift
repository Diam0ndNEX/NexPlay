import SwiftUI
import UIKit

// 8.18.2 The menu bar a game builds for its PC window (NW.js: win.menu = new nw.Menu({type: 'menubar'}), for
// example the MenuBarAddition plugin). iPhone has no window menu bar, so the NW.js shim keeps it
// (window.__nexMenuJSON) and this sheet shows its items; tapping one runs the game's own click code
// (window.__nexMenuClick). Opened from Game Panel > Tools > Game Menu Bar.

struct GameMenuItem: Decodable, Identifiable {
    let id: Int
    let label: String
    let type: String
    let enabled: Bool
    let checked: Bool
    let key: String
    let children: [GameMenuItem]

    var isSeparator: Bool { type == "separator" }
}

@MainActor
final class GameMenuBarModel: ObservableObject {
    @Published var menus: [GameMenuItem] = []
    @Published var loaded = false
    @Published var message: String?
    private let context: PlayerContext

    init(context: PlayerContext) {
        self.context = context
    }

    func load() async {
        let text = await context.evaluateString("window.__nexMenuJSON ? window.__nexMenuJSON() : '[]'") ?? "[]"
        menus = (try? JSONDecoder().decode([GameMenuItem].self, from: Data(text.utf8))) ?? []
        loaded = true
    }

    func tap(_ item: GameMenuItem) {
        Task {
            let result = await context.evaluateString("window.__nexMenuClick ? window.__nexMenuClick(\(item.id)) : 'The game is not ready.'") ?? "The game didn't answer."
            if result == "ok" {
                context.gameLog.add("game menu bar: \(item.label)")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                message = result
            }
            await load()
        }
    }
}

struct GameMenuBarView: View {
    @StateObject var model: GameMenuBarModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded {
                    ProgressView()
                } else if model.menus.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "menubar.rectangle").font(.system(size: 38)).foregroundStyle(NexStyle.accent)
                        Text("No menu bar").font(.headline)
                        Text("This game didn't build a PC menu bar. Games with a plugin like MenuBarAddition show its menus here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(model.menus) { menu in
                            Section(clean(menu.label)) {
                                if menu.children.isEmpty {
                                    row(menu)
                                } else {
                                    items(menu.children, depth: 0)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Game Menu Bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await model.load() }
        .alert("Game Menu Bar", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
    }

    private func items(_ list: [GameMenuItem], depth: Int) -> AnyView {
        AnyView(ForEach(list) { item in
            if item.isSeparator {
                EmptyView()
            } else if !item.children.isEmpty {
                DisclosureGroup(clean(item.label)) {
                    items(item.children, depth: depth + 1)
                }
            } else {
                row(item)
            }
        })
    }

    private func row(_ item: GameMenuItem) -> some View {
        Button { model.tap(item) } label: {
            HStack {
                if item.type == "checkbox" {
                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.checked ? NexStyle.accent : .secondary)
                }
                Text(clean(item.label)).foregroundStyle(item.enabled ? .primary : .secondary)
                Spacer()
                if !item.key.isEmpty {
                    Text(item.key.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!item.enabled)
    }

    /// PC menu labels mark the shortcut letter with "&".
    private func clean(_ label: String) -> String {
        let text = label.replacingOccurrences(of: "&&", with: "\u{1}").replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "\u{1}", with: "&")
        return text.isEmpty ? "Menu" : text
    }
}
