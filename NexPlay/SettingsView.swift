import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.silentModeAudio) private var silentModeAudio = true
    @AppStorage(SettingsKey.showMenuButton) private var showMenuButton = true
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKey.desktopMode) private var desktopMode = true
    @AppStorage(SettingsKey.pixelatedScaling) private var pixelatedScaling = false

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
                } header: {
                    Text("RPG Maker games")
                } footer: {
                    Text("Desktop mode lets MV and MZ games run as they do on a PC: normal audio files, full update rate, full screen height. Turn it off if a game misbehaves. Sharp pixels stops smoothing when the picture is scaled. Both apply the next time a game starts.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Supports", value: "RPG Maker MV/MZ, HTML5")
                }

                Section {
                    Text("Parts of the RPG Maker runtime and the game file server are adapted from Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app, and mvmz-apple-mobile, https://github.com/mateo-m/mvmz-apple-mobile. GPL-3.0 with additional terms.")
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
