import SwiftUI

extension SettingsKey {
    /// The app version whose What's New was shown last (not a user setting; Reset leaves it).
    static let whatsNewSeen = "whatsNewSeen"
}

/// What changed in this version. Shown once after an update, and from Settings > Advanced.
struct WhatsNewView: View {
    /// True when shown as a sheet over the library (with a Continue button).
    let standalone: Bool
    @Environment(\.dismiss) private var dismiss

    static let version = "6.1"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "square.grid.2x2.fill", color: .indigo, title: "Game Panel",
             text: "Every in-game tool in one place: game menu > Game Panel. Big buttons for Quick Save, Quick Load and Save States, a pause button and a speed picker, a volume slider, text options and the safety net, in cards instead of menus inside menus."),
        Item(symbol: "square.stack.3d.down.right.fill", color: .purple, title: "New Save States Screen",
             text: "States are cards with a large picture, place and time. Touch and hold one to delete it."),
        Item(symbol: "text.bubble.fill", color: .blue, title: "Chat-style Message Log",
             text: "Lines show as speech bubbles with the speaker's name; your choices appear on the right."),
        Item(symbol: "bolt.circle.fill", color: .orange, title: "Quick Save in the Menu",
             text: "Quick Save and Quick Load stay right in the game menu, next to Game Panel."),
        Item(symbol: "speedometer", color: .teal, title: "Game Tools (6.0)",
             text: "Volume for every game, pause and 0.5×-4× speed for HTML5, Godot, Construct, Twine, Tyrano, Ren'Py and Flash, Twine save states, Ren'Py text and auto-forward options."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's New").font(.largeTitle.bold())
                    Text("NexPlay \(WhatsNewView.version)").font(.headline).foregroundStyle(NexStyle.accent)
                }
                .padding(.top, standalone ? 30 : 8)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if standalone {
                    Button {
                        dismiss()
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlayButtonStyle())
                    .padding(.top, 10)
                }
            }
            .padding(24)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(standalone ? "" : "What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}
