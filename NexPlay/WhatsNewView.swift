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

    static let version = "4.1"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "link.badge.plus", color: .cyan, title: "Download from Link",
             text: "Tap + > Download from Link and paste a direct download link: NexPlay downloads the game with progress and imports it."),
        Item(symbol: "externaldrive.fill", color: .mint, title: "Ren'Py Saves",
             text: "In a Ren'Py game, the game menu has Ren'Py Saves: export them, back them up, or import .save files from a PC."),
        Item(symbol: "internaldrive", color: .gray, title: "Storage",
             text: "Settings > Advanced > Storage shows what takes space and clears runtimes, packages and leftovers. Rescued saves can be deleted there."),
        Item(symbol: "link", color: .yellow, title: "Play Links",
             text: "Long-press a game > Copy Play Link. Open it from the Shortcuts app or a Home Screen shortcut to start the game right away."),
        Item(symbol: "bubble.left.and.text.bubble.right.fill", color: .pink, title: "Ren'Py",
             text: "Visual novels made with Ren'Py 6, 7 and 8 run on Ren'Py's own web engine. Big games load their pictures and music only when needed, and .rpa archives are unpacked when you import."),
        Item(symbol: "bolt.fill", color: .orange, title: "Flash",
             text: "Flash games (.swf) run on Ruffle. Import the .swf, a folder or an archive."),
        Item(symbol: "cpu", color: .teal, title: "Choose the Runtime",
             text: "Ren'Py and Godot games can switch runtime in Game Settings or from the game menu. If a game fails to start, NexPlay offers the other runtimes."),
        Item(symbol: "cube.fill", color: .indigo, title: "Godot Fixes",
             text: "Godot 4.0-4.2 games use a runtime that works on iPhone, and the game log shows what the game's pack contains."),
        Item(symbol: "square.and.arrow.up", color: .blue, title: "Files from Games",
             text: "When a game saves a file (save exports in Twine, Ren'Py and other web games), the share sheet opens so you can keep it."),
        Item(symbol: "sparkles.rectangle.stack.fill", color: .purple, title: "New Library",
             text: "A bigger Continue card, a Recently Added shelf, engine icons in the filters, and Play Stats."),
        Item(symbol: "square.and.arrow.down.on.square", color: .green, title: "Save Import",
             text: "Import loose .rpgsave / .rmmzsave files, folders or ZIPs, several at once."),
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
