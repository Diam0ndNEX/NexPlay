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

    static let version = "7.6"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "house.fill", color: .indigo, title: "Home, Library and Settings Tabs",
             text: "Home has Continue, Recently Played, Favorites, Recently Added and Needs Setup. Library has filters, including Ready to Play. The floating + also imports a whole folder of games at once."),
        Item(symbol: "pc", color: .blue, title: "Windows Games and Built-in JIT",
             text: "Windows games run through Wine and FEX (BCD's runtime). JIT is built in: import your pairing file in Setup Center, connect LocalDevVPN, and enable it."),
        Item(symbol: "map.fill", color: .green, title: "RPG Maker 2000/2003",
             text: "Runs natively with EasyRPG. Import the RTP once in Setup Center if a game asks for it."),
        Item(symbol: "info.circle.fill", color: .teal, title: "Game Page",
             text: "A How It Runs card tells you which runtime a game uses and lets you vote Works, Playable or Broken. Games that need setup get a Set Up button."),
        Item(symbol: "cursorarrow.click", color: .purple, title: "Input Overhaul",
             text: "Layout presets (Controller, Point & Click, WASD + Mouse, Visual Novel, RPG Maker, Twin-Stick), a Trackpad mouse, a PC keyboard with F-keys, and Quick Save, Quick Load and Game Panel buttons."),
        Item(symbol: "battery.75", color: .orange, title: "Power Profiles",
             text: "Battery Saver (30 FPS), Balanced (60) or Max, per game in the Game Panel. Hot iPhones get a Battery Saver offer, idle games pause."),
        Item(symbol: "stethoscope", color: .mint, title: "Diagnostics Self-Test",
             text: "Settings > Diagnostics > Run All Checks, and Export Logs ZIP for bug reports."),
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
