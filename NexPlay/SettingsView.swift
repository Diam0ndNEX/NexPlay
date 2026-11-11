import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.silentModeAudio) private var silentModeAudio = true
    @AppStorage(SettingsKey.showMenuButton) private var showMenuButton = true
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = true

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

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Supports", value: "RPG Maker MV/MZ, HTML5")
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
