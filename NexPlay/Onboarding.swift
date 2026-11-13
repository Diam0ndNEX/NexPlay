import SwiftUI

// 7.6.0 (SPEC-7.0-review D4): one welcome flow for NexPlay 7: three slides, then Setup Center. Skippable, shown once,
// and re-openable from Settings > Advanced > Welcome Tour.

extension SettingsKey {
    /// True once the NexPlay 7 welcome tour was finished or skipped (not a user setting; Reset leaves it).
    static let onboarding7Seen = "onboarding7Seen"
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showSetup = false

    private struct Slide {
        let symbol: String
        let color: Color
        let title: String
        let lines: [String]
    }

    private let slides: [Slide] = [
        Slide(symbol: "house.fill", color: .indigo, title: "Welcome to NexPlay 7",
              lines: ["Home shows what you played last, favorites, new games and anything that needs setup.",
                      "Library has every game, with filters like Ready to Play.",
                      "The + button adds files, folders, a whole folder of games, or a download link."]),
        Slide(symbol: "pc", color: .blue, title: "Windows Games",
              lines: ["NexPlay can run Windows games through Wine and FEX, with JIT built in.",
                      "Each game page says how it runs and lets you vote Works, Playable or Broken.",
                      "RPG Maker 2000/2003 runs natively with EasyRPG."]),
        Slide(symbol: "gamecontroller.fill", color: .purple, title: "Play Your Way",
              lines: ["Game Panel: saves, speed, sound, power profiles and input in one place.",
                      "Layout presets, a Trackpad mouse and a PC keyboard with F-keys, Ctrl and Alt.",
                      "Battery Saver caps games at 30 FPS; idle games pause on their own."]),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(slides.indices, id: \.self) { index in
                        slideView(slides[index]).tag(index)
                    }
                    finalSlide.tag(slides.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                bottomButtons
            }
            .background(AppBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Skip") { finish() }
                }
            }
            .navigationDestination(isPresented: $showSetup) {
                SetupCenterView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { finish() } }
                    }
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: slide.symbol)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(slide.color.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: slide.color.opacity(0.5), radius: 18, y: 8)
            Text(slide.title)
                .font(.pixel(26, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(slide.lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(slide.color)
                        Text(line).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 28)
            Spacer(minLength: 40)
        }
    }

    private var finalSlide: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: "checklist")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(Color.pink.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            Text("Setup Center")
                .font(.pixel(26, relativeTo: .largeTitle))
                .foregroundStyle(.white)
            Text("One checklist for the pairing file, LocalDevVPN, JIT, entitlements and runtimes. Web, Ren'Py, Godot and RPG Maker games need none of it.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 40)
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            if page < slides.count {
                Button {
                    withAnimation { page += 1 }
                } label: {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(PlayButtonStyle())
            } else {
                Button {
                    showSetup = true
                } label: {
                    Text("Open Setup Center").frame(maxWidth: .infinity)
                }
                .buttonStyle(PlayButtonStyle())
                Button("Start Playing") { finish() }
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(height: 120, alignment: .top)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKey.onboarding7Seen)
        UserDefaults.standard.set(WhatsNewView.version, forKey: SettingsKey.whatsNewSeen)
        dismiss()
    }
}
