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

    static let version = "6.0"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "slider.horizontal.below.rectangle", color: .indigo, title: "Game Tools",
             text: "Every game now has Game Tools in the game menu: a volume control (or mute) that is kept per game."),
        Item(symbol: "speedometer", color: .orange, title: "Game Speed for Every Engine",
             text: "HTML5, Godot, Construct, Twine, Tyrano, Ren'Py and Flash games can run at 0.5× to 4×. Grind faster, or slow down a hard part. Works for games that time themselves with the browser clock."),
        Item(symbol: "pause.fill", color: .gray, title: "Pause Any Game",
             text: "Pause and resume games that have no pause of their own. These games now also pause when you leave the app."),
        Item(symbol: "square.stack.3d.down.right.fill", color: .purple, title: "Twine Save States",
             text: "SugarCube stories (Degrees of Lewdity and others) get save states, quick save/load and auto states, plus Story: Back and Forward."),
        Item(symbol: "bubble.left.and.text.bubble.right.fill", color: .pink, title: "Ren'Py Tools",
             text: "Quick Save, Auto-Forward, Text Speed (instant to slow) and Skip Unseen Text, right from the game menu."),
        Item(symbol: "sparkles", color: .teal, title: "Play Assist (5.0)",
             text: "RPG Maker MV/MZ: save states, quick save/load, auto states, rewind up to 5 minutes, message log, instant text and auto-advance."),
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
