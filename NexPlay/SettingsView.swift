import SwiftUI

/// Settings, grouped like RPGPlayer/Empo (ideas only): searchable rows in sections with coloured icon tiles.
struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.theme) private var theme = "dark"
    @AppStorage(SettingsKey.libraryLayout) private var layout = "grid"
    @AppStorage(SettingsKey.titleUnderCard) private var titleUnder = true
    @AppStorage(SettingsKey.showContinueCard) private var showContinue = true
    @AppStorage(SettingsKey.hapticsEnabled) private var haptics = true
    @AppStorage(SettingsKey.hapticStrength) private var hapticStrength = 1
    @AppStorage(SettingsKey.controllerMode) private var controllerMode = "keys"
    @AppStorage(SettingsKey.silentModeAudio) private var silentModeAudio = true
    @AppStorage(SettingsKey.showMenuButton) private var showMenuButton = true
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKey.desktopMode) private var desktopMode = true
    @AppStorage(SettingsKey.pixelatedScaling) private var pixelatedScaling = false
    @AppStorage(SettingsKey.nwMode) private var nwMode = true
    @AppStorage(SettingsKey.autoBackup) private var autoBackup = true
    @AppStorage(SettingsKey.backupRetention) private var retention = 10
    @AppStorage(SettingsKey.translationEnabled) private var translation = false

    @State private var search = ""
    @State private var showControllerMap = false
    @State private var confirmReset = false
    @State private var shareURL: URL?
    @State private var message: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// True when the row should show for the current search.
    private func show(_ words: String) -> Bool {
        search.isEmpty || words.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        NavigationStack {
            Form {
                appearance
                controls
                gameplay
                backups
                translationSection
                advanced
                about
                if show("reset defaults") {
                    Section {
                        Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                    } footer: {
                        Text("Resets settings only. Games, saves, layouts and collections stay.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search settings")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showControllerMap) { ControllerMapView(gameID: nil, gameName: nil) }
            .sheet(item: Binding(
                get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } }
            )) { item in ActivityView(items: [item.url]) }
            .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive) { resetDefaults() }
            }
            .alert("NexPlay", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var appearance: some View {
        if show("appearance theme dark light layout grid list title continue") {
            Section {
                if show("theme dark light system") {
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }
                }
                if show("library layout grid list") {
                    Picker("Library layout", selection: $layout) {
                        Text("Grid").tag("grid")
                        Text("List").tag("list")
                    }
                }
                if show("title under inside card") { Toggle("Title under the cover", isOn: $titleUnder) }
                if show("continue playing card") { Toggle("Continue playing card", isOn: $showContinue) }
            } header: { SettingsHeader(title: "Appearance", symbol: "paintbrush.fill", color: .purple) }
        }
    }

    @ViewBuilder private var controls: some View {
        if show("controls haptics vibration controller buttons gamepad layout") {
            Section {
                if show("haptics vibration") {
                    Toggle("Haptics on touch controls", isOn: $haptics)
                    Picker("Haptic strength", selection: $hapticStrength) {
                        Text("Light").tag(0)
                        Text("Medium").tag(1)
                        Text("Heavy").tag(2)
                    }
                    .disabled(!haptics)
                }
                if show("controller mode keys gamepad api") {
                    Picker("Controllers", selection: $controllerMode) {
                        Text("Send keys (remappable)").tag("keys")
                        Text("Game reads them (Gamepad API)").tag("gamepadAPI")
                    }
                }
                if show("controller buttons remap") {
                    Button("Controller Buttons (all games)…") { showControllerMap = true }
                }
                if show("reset default layout touch controls") {
                    Button("Reset Default Touch Layout") {
                        LayoutStore.resetDefault()
                        message = "The default touch layout is back to the built-in one. Games with their own layout keep it."
                    }
                }
            } header: { SettingsHeader(title: "Controls", symbol: "gamecontroller.fill", color: .blue) }
        }
    }

    @ViewBuilder private var gameplay: some View {
        if show("gameplay performance sound silent screen awake menu button desktop sharp pixels nw.js saves") {
            Section {
                if show("sound silent mode") { Toggle("Play sound in silent mode", isOn: $silentModeAudio) }
                if show("keep screen awake") { Toggle("Keep screen awake while playing", isOn: $keepScreenAwake) }
                if show("menu button visible") { Toggle("Menu button fully visible", isOn: $showMenuButton) }
                if show("desktop mode rpg maker") { Toggle("Desktop mode (RPG Maker)", isOn: $desktopMode) }
                if show("sharp pixels smoothing") { Toggle("Sharp pixels (RPG Maker)", isOn: $pixelatedScaling) }
                if show("nw.js mode saves as files") { Toggle("NW.js mode: saves as files", isOn: $nwMode) }
            } header: {
                SettingsHeader(title: "Gameplay & Performance", symbol: "bolt.fill", color: .orange)
            } footer: {
                Text("Desktop mode lets MV and MZ run as on a PC (normal audio, full update rate, full height). NW.js mode keeps saves as files in the game's save folder, so they can be backed up, exported and rescued. Each game can override these in its Info & Settings. Changes apply the next time a game starts.")
            }
        }
    }

    @ViewBuilder private var backups: some View {
        if show("import backup automatic retention export saves") {
            Section {
                if show("automatic backup") { Toggle("Automatic save backups", isOn: $autoBackup) }
                if show("retention keep backups") {
                    Picker("Keep", selection: $retention) {
                        Text("Less (last 5)").tag(5)
                        Text("Standard (last 10)").tag(10)
                        Text("More (last 20)").tag(20)
                    }
                }
                if show("back up now") { Button("Back Up All Now") { backUpNow() } }
                if show("export all saves") { Button("Export All Saves (ZIP)…") { exportAll() } }
            } header: {
                SettingsHeader(title: "Import & Backup", symbol: "externaldrive.fill", color: .green)
            } footer: {
                Text("Backups of save files (NW.js mode) are made when you stop playing, when the app goes to the background and 30 seconds after launch, only when saves changed. To restore one, open the game's Info & Settings. Opening a saves ZIP from the Files app offers to restore it.")
            }
        }
    }

    @ViewBuilder private var translationSection: some View {
        if show("translation translate mtool language") {
            Section {
                Toggle("Translate MV/MZ games", isOn: $translation)
            } header: {
                SettingsHeader(title: "Translation", symbol: "character.bubble.fill", color: .indigo)
            } footer: {
                Text("Uses an MTool TranslateFile.json from the game folder or imported in the game menu (Translation…). Works offline; nothing is sent anywhere. Each game can override this. Turn it on before starting a game.")
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        if show("advanced app log diagnostics") {
            Section {
                NavigationLink("App Log") { AppLogView() }
            } header: { SettingsHeader(title: "Advanced", symbol: "wrench.and.screwdriver.fill", color: .gray) }
        }
    }

    @ViewBuilder private var about: some View {
        if show("about version credits licenses") {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Supports", value: "RPG Maker MV/MZ, HTML5 (XP/VX/Ace with the mkxp core build)")
                NavigationLink("Credits") { CreditsView() }
            } header: { SettingsHeader(title: "About", symbol: "info.circle.fill", color: .teal) }
        }
    }

    // MARK: - Actions

    private func resetDefaults() {
        let defaults = UserDefaults.standard
        for key in SettingsKey.all { defaults.removeObject(forKey: key) }
        AppLog.log("settings reset to defaults")
    }

    private func backUpNow() {
        let games = store.games
        Task {
            let count = await Task.detached { AutoBackup.runAll(games, force: true) }.value
            message = count == 0 ? "No save files to back up." : "Backed up \(count) game(s)."
        }
    }

    private func exportAll() {
        let games = store.games
        Task {
            do {
                shareURL = try await Task.detached { try AutoBackup.exportAll(games) }.value
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct SettingsHeader: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CreditsView: View {
    var body: some View {
        List {
            Section("Adapted code") {
                Text("Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app, and mvmz-apple-mobile, https://github.com/mateo-m/mvmz-apple-mobile (GPL-3.0-only with additional terms): RPG Maker runtime (speed, pause, focus), NW.js shim, game file server, save rescue and displaced-copy handling, controls model and touch handling ideas, controller bindings, backup retention and import pipeline invariants.")
            }
            Section("Libraries") {
                Text("ZIPFoundation, Copyright (c) 2017-2026 Thomas Zoechling, https://github.com/weichsel/ZIPFoundation (MIT).")
            }
            Section("RPG Maker XP/VX/Ace core (only in builds with the mkxp core)") {
                Text("mkxp-z, https://github.com/mkxp-z/mkxp-z (GPLv2 or later), built for iOS by mkxp-z-apple-mobile, https://github.com/mateo-m/mkxp-z-apple-mobile (GPL), with Ruby (Ruby license / BSD-2-Clause), SDL (zlib), ANGLE (BSD-3-Clause), FluidSynth (LGPL-2.1) and the other libraries its licenses.json lists. Core contract and build scripts from Empo (GPL-3.0-only with additional terms).")
            }
            Section("Ideas only (no code)") {
                Text("RPGPlayer, ArkRPG, JoiPlay, Runa, QuestPlay, RPGEmu: feature ideas such as collections, plugin manager, cheats, storage manager, MTool translation files and encoding repair.")
            }
        }
        .font(.footnote)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
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
