import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.silentModeAudio) private var silentModeAudio = true
    @AppStorage(SettingsKey.showMenuButton) private var showMenuButton = true
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKey.desktopMode) private var desktopMode = true
    @AppStorage(SettingsKey.pixelatedScaling) private var pixelatedScaling = false
    @AppStorage(SettingsKey.nwMode) private var nwMode = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Play sound in silent mode", isOn: $silentModeAudio)
                    Toggle("Keep screen awake while playing", isOn: $keepScreenAwake)
                    Toggle("Menu button fully visible", isOn: $showMenuButton)
                } header: {
                    Text("Playing")
                } footer: {
                    Text("With the menu button off it fades almost completely but still works. Drag it anywhere.")
                }

                Section {
                    Toggle("Desktop mode", isOn: $desktopMode)
                    Toggle("Sharp pixels", isOn: $pixelatedScaling)
                    Toggle("NW.js mode (saves as files)", isOn: $nwMode)
                } header: {
                    Text("RPG Maker games")
                } footer: {
                    Text("Desktop mode lets MV and MZ games run as they do on a PC: normal audio files, full update rate, full screen height. Turn it off if a game misbehaves. Sharp pixels stops smoothing when the picture is scaled. NW.js mode keeps saves as files in the game's save folder (like on a PC), so they can be exported as a ZIP and survive deleting the game; old browser saves are copied over the first time. Each game can override it in its details. All apply the next time a game starts.")
                }

                Section("Advanced") {
                    NavigationLink("App Log") { AppLogView() }
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Supports", value: "RPG Maker MV/MZ, HTML5")
                }

                Section {
                    Text("Parts of the RPG Maker runtime, the NW.js shim, the game file server and the save rescue/displaced-copy handling are adapted from Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app, and mvmz-apple-mobile, https://github.com/mateo-m/mvmz-apple-mobile. GPL-3.0 with additional terms.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Credits")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Shows the app log (imports, backups, crash notes) with a share button.
struct AppLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing logged yet." : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("App Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share log")
            }
        }
        .onAppear { text = AppLog.shared.text }
    }
}
