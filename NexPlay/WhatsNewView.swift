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

    static let version = "5.0"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "square.stack.3d.down.right.fill", color: .purple, title: "Save States",
             text: "RPG Maker MV/MZ games: game menu > Play Assist > Save States. Save anywhere on the map, even where the game doesn't allow it, and load any time. Each state has a picture, the place, playtime and party leader. The game's own saves are never touched."),
        Item(symbol: "bolt.circle.fill", color: .orange, title: "Quick Save & Quick Load",
             text: "One tap in Play Assist. Quick Load works from the title screen too."),
        Item(symbol: "backward.fill", color: .pink, title: "Rewind",
             text: "NexPlay keeps a snapshot every 15 seconds on the map. Lost a fight or took a wrong turn? Go back up to 5 minutes. Every load can be undone the same way."),
        Item(symbol: "clock.arrow.circlepath", color: .teal, title: "Auto Save States",
             text: "A state every 10 minutes (change it per game) and when you leave the app, so iOS closing the game doesn't cost you progress. The last 3 are kept."),
        Item(symbol: "text.bubble.fill", color: .blue, title: "Message Log",
             text: "Missed a line? Play Assist > Message Log shows what was said, who said it and which choices you picked."),
        Item(symbol: "text.alignleft", color: .green, title: "Instant Text & Auto-Advance",
             text: "Show messages at once, and let them go on by themselves after 1.5, 3 or 5 seconds. Set per game."),
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
