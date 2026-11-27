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

    static let version = "9.0"

    private struct Item: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    // 9.0.0: iPad and hardware keyboards first; the NexPlay 8 items follow.
    private let items: [Item] = [
        Item(symbol: "ipad.landscape", color: .indigo, title: "Made for iPad",
             text: "A sidebar for the library's filters, engines and collections, bigger Home cards, Settings with its pages beside the list, and the library turns with your iPad."),
        Item(symbol: "keyboard.fill", color: .gray, title: "Hardware Keyboards",
             text: "Every key reaches web games, touch controls hide while a keyboard is connected, and ⌘ shortcuts: G Game Panel, S/L Quick Save/Load, F Fast Forward, I HUD, P Screenshot, W Exit. In the library ⌘1–3, ⌘F, ⌘O."),
        Item(symbol: "cursorarrow.motionlines", color: .teal, title: "Pointer and Drag & Drop",
             text: "Cards lift under the trackpad pointer, and games dragged in from Files (Split View, Stage Manager) are imported."),
        Item(symbol: "dpad.fill", color: .green, title: "Touch Controls Fit Bigger Screens",
             text: "On iPad the D-pad and buttons keep their phone distance from the edges, so they stay under your thumbs. One layout works on both."),
        Item(symbol: "pc", color: .blue, title: "One App for Windows Games",
             text: "BCD's Windows engine is part of NexPlay now: Windows games start from your library with NexPlay's loading screen, menu, HUD and game page. One JIT and one pairing file for everything."),
        Item(symbol: "paintpalette.fill", color: .indigo, title: "New Design",
             text: "Colour profiles, Liquid Glass on controls, rounded type, engine-tinted covers, a fading tab bar, and Settings pages on your profile's cards."),
        Item(symbol: "gamecontroller.fill", color: .green, title: "Two Control Styles",
             text: "NexPlay Pad or PC Controls (BCD's touch layer) for any game, plus a key bar, radial menu, turbo, gyro aim, gestures, a magnifier and Pencil. Controllers: players, rumble and a live tester."),
        Item(symbol: "slider.horizontal.below.rectangle", color: .purple, title: "One In-Game Menu",
             text: "The Game Panel and the Windows menu share BCD's layout, and one Performance HUD (Pulse, Strip, Tune, Report) works in every engine."),
        Item(symbol: "rectangle.on.rectangle", color: .teal, title: "New Game Page",
             text: "Art across the screen, Play and chips, How It Runs, and only the sections the game can use. Windows games get PC Setup: AutoTune, recommended settings, graphics, Windows tools and saves."),
        Item(symbol: "memorychip", color: .cyan, title: "Settings › Windows Games",
             text: "Memory, graphics, Wine Mono, Visual C++, MFC and Wine Gecko, storage and external drives, logs, every engine option, and optional helper memory for big games."),
        Item(symbol: "checklist", color: .pink, title: "Setup Center Checks",
             text: "Windows components with a Download button, and a check of every Windows game for missing Windows files."),
        Item(symbol: "arrow.clockwise", color: .orange, title: "Restart and Play",
             text: "Windows runs once per launch. After Close NexPlay, opening NexPlay again brings you back to the game's page."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's New").font(NexType.display(30)).foregroundStyle(NexColor.text)
                    Text("NexPlay \(WhatsNewView.version)").font(NexType.heading).foregroundStyle(NexColor.accentSoft)
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
                            Text(item.title).font(NexType.heading).foregroundStyle(NexColor.text)
                            Text(item.text).font(NexType.body).foregroundStyle(NexColor.textSoft)
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
                    .buttonStyle(NexPrimaryButtonStyle())
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
