import SwiftUI
import UIKit

// 8.15.0: small tools around the touch controls and support, shared by every in-game panel:
// - ControlsTestView: what every on-screen button presses, for the portrait and the landscape layout.
// - LayoutCopyView: copies this game's touch layout to other games.
// - ProblemReport: makes the logs ZIP and opens the share sheet (one tap instead of the Settings > Diagnostics trail).

struct ControlsTestView: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss

    private func what(_ item: ControlItem) -> String {
        if item.action.isDirectional {
            let keys = item.wasd == true ? "W A S D" : "Arrow keys"
            return keys + ((item.eightWay ?? true) ? ", 8 directions" : ", 4 directions")
        }
        if let key = item.padKey { return key.title }
        return item.action.title
    }

    private func name(_ item: ControlItem) -> String {
        let label = item.action.isDirectional ? "" : item.displayLabel
        return label.isEmpty ? item.action.title : label
    }

    private func rows(_ items: [ControlItem]) -> some View {
        ForEach(items) { item in
            LabeledContent(name(item), value: what(item) + (item.hidden ? " (hidden)" : ""))
        }
    }

    var body: some View {
        let profile = LayoutStore.load(for: game)
        NavigationStack {
            List {
                Section("Portrait") { rows(profile.portrait) }
                Section("Landscape") { rows(profile.landscape) }
                Section {
                    Text("Each line is a button on the screen and the key it presses in the game. Change a button with Edit Touch Controls.")
                        .font(.footnote)
                }
            }
            .navigationTitle("What Each Button Does")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct LayoutCopyView: View {
    let source: Game
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<UUID>()
    @State private var games: [Game] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(games) { game in
                        Button {
                            if picked.contains(game.id) { picked.remove(game.id) } else { picked.insert(game.id) }
                        } label: {
                            HStack {
                                Text(game.name).foregroundStyle(.primary)
                                Spacer()
                                if picked.contains(game.id) { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                    }
                } footer: {
                    Text("Replaces the touch buttons of the games you pick with the ones of \(source.name).")
                }
            }
            .navigationTitle("Copy Layout To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        let profile = LayoutStore.load(for: source)
                        for id in picked { LayoutStore.save(profile, for: id) }
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
            .onAppear {
                games = (LibraryStore.current?.games ?? []).filter { $0.id != source.id }
            }
        }
    }
}

@MainActor
enum ProblemReport {
    /// Makes the logs ZIP and shows the share sheet over whatever is on screen. Returns an error text, or nil.
    static func share() -> String? {
        do {
            let url = try SelfTest.exportLogsZIP(selfTest: [])
            // 8.20.2: through TopController (a visible window, waits while the menu closes, never twice).
            guard TopController.find() != nil else { return "Couldn't open the share sheet." }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            TopController.present(sheet)
            return nil
        } catch {
            return "Couldn't make the logs: \(error.localizedDescription)"
        }
    }
}
