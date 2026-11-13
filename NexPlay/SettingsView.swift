import SwiftUI

// Settings pages, grouped like RPGPlayer (ideas only): a searchable list of pages with coloured icon tiles.

/// One page of Settings.
enum NexSettingsPage: String, CaseIterable, Identifiable, Hashable {
    case setupCenter, appearance, controls, gameplay, jit, translation, privacy, backup, advanced, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setupCenter: return "Setup Center"
        case .appearance: return "Appearance"
        case .controls: return "Controls"
        case .gameplay: return "Gameplay & Performance"
        case .jit: return "JIT & Performance"
        case .translation: return "Translation"
        case .privacy: return "Privacy"
        case .backup: return "Import & Backup"
        case .advanced: return "Advanced"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .setupCenter: return "A checklist of what Windows games need, with a fix for each"
        case .appearance: return "Theme, background, library layout"
        case .controls: return "Virtual gamepad, control bar, haptics and physical controllers"
        case .gameplay: return "Power profiles, idle pause, orientation, sound and RPG Maker modes"
        case .jit: return "Built-in JIT: pairing file, LocalDevVPN, status and test"
        case .translation: return "In-game text translation"
        case .privacy: return "Hide games and collections behind Face ID, Touch ID or a passcode"
        case .backup: return "Automatic save backups and exports"
        case .advanced: return "Engines and runtimes, storage, play stats, what's new, app log"
        case .diagnostics: return "Device, signing, entitlements, JIT state and a report for bug reports"
        }
    }

    var symbol: String {
        switch self {
        case .setupCenter: return "checklist"
        case .appearance: return "paintpalette.fill"
        case .controls: return "gamecontroller.fill"
        case .gameplay: return "bolt.fill"
        case .jit: return "cpu"
        case .translation: return "character.bubble.fill"
        case .privacy: return "lock.fill"
        case .backup: return "externaldrive.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .setupCenter: return .pink
        case .appearance: return .indigo
        case .controls: return .blue
        case .gameplay: return .orange
        case .jit: return .yellow
        case .translation: return .teal
        case .privacy: return .green
        case .backup: return .purple
        case .advanced: return .gray
        case .diagnostics: return .mint
        }
    }

    /// Setting names on the page, for search.
    var rows: [String] {
        switch self {
        case .setupCenter:
            return ["Checklist", "Pairing File", "LocalDevVPN", "JIT Test", "Entitlements", "Windows Runtime", "Free Storage"]
        case .appearance:
            return ["Dark Mode", "Theme", "Animated Background", "Background Theme", "Library View", "Title Under the Cover",
                    "Continue Playing Card"]
        case .controls:
            return ["Virtual Gamepad Size", "Virtual Gamepad Opacity", "Control Type", "Joystick", "D-Pad",
                    "Reset Default Touch Layout", "Control Bar Opacity", "Control Bar Size", "Drawer Direction",
                    "Glass Effect", "Auto-Hide Controls", "Show Fast Forward Button", "Show Screenshot Button",
                    "Show Keyboard Button", "Reset Control Bar Position", "Haptic Feedback", "Haptic Strength",
                    "Enable Physical Controller", "Auto-hide Virtual Gamepad", "Show Control Bar With Controller",
                    "Controller Mode", "Controller Mapping", "Button Mapping"]
        case .gameplay:
            return ["Auto-rotate In Games", "Game Orientation", "Auto-rotate Outside Games", "Portrait Game Position",
                    "Play Sound in Silent Mode", "Keep Screen Awake", "Desktop Mode", "Sharp Pixels", "NW.js Mode",
                    "Power Profile", "Battery Saver", "Idle Pause", "Thermal Guard"]
        case .jit:
            return ["JIT", "Enable JIT Now", "Pairing File", "Import Pairing File", "LocalDevVPN", "Check Connection",
                    "Developer Disk Image", "StikDebug", "TXM", "Enable JIT at App Launch", "Enable JIT When a Game Needs It"]
        case .translation:
            return ["Translate MV/MZ Games", "MTool", "TranslateFile.json"]
        case .privacy:
            return ["Privacy Lock", "Hidden Games", "Face ID", "Unhide All Games"]
        case .backup:
            return ["Automatic Save Backups", "Keep Backups", "Back Up All Now", "Export All Saves"]
        case .advanced:
            return ["Engines & Runtimes", "Ren'Py", "Godot", "Flash", "Clear Runtime Cache", "Storage", "Rescued Saves", "Free Space", "Play Stats", "What's New", "App Log", "Credits"]
        case .diagnostics:
            return ["Device", "iOS Version", "TXM", "Memory", "Entitlements", "get-task-allow", "Increased Memory Limit",
                    "Extended Virtual Addressing", "JIT", "Build Flags", "Copy Report", "Copy Log"]
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var confirmReset = false
    @State private var message: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var platform: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private var hits: [(page: NexSettingsPage, row: String)] {
        var list: [(page: NexSettingsPage, row: String)] = []
        for page in NexSettingsPage.allCases {
            for row in [page.title] + page.rows where row.localizedCaseInsensitiveContains(search) {
                list.append((page: page, row: row))
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    mainSections
                } else {
                    searchResults
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Settings")
            .searchable(text: $search, prompt: "Search settings")
            .navigationDestination(for: NexSettingsPage.self) { page in
                SettingsPageView(page: page)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive) { resetDefaults() }
            } message: {
                Text("Games, saves, layouts and collections stay.")
            }
            .alert("NexPlay", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    @ViewBuilder private var mainSections: some View {
        Section {
            ForEach(NexSettingsPage.allCases) { page in
                NavigationLink(value: page) { SettingsTile(page: page) }
            }
        } header: {
            SettingsHeader(title: "Settings", symbol: "gearshape.fill", color: .purple)
        }
        Section {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("NexPlay").font(.headline)
                    Text(version).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Platform", value: platform)
            NavigationLink("Credits") { CreditsView() }
        } header: {
            SettingsHeader(title: "About", symbol: "info.circle.fill", color: .teal)
        }
        Section {
            Button(role: .destructive) { confirmReset = true } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("Resets settings only. Games, saves, layouts and collections stay.")
        }
    }

    @ViewBuilder private var searchResults: some View {
        if hits.isEmpty {
            Text("No settings match \u{201C}\(search)\u{201D}.").foregroundStyle(.secondary)
        } else {
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                NavigationLink(value: hit.page) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.row)
                        Text(hit.page.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func resetDefaults() {
        let defaults = UserDefaults.standard
        let keys = SettingsKey.all + SettingsKey.playerKeys + SettingsKey.backgroundKeys + SettingsKey.jitKeys + SettingsKey.powerKeys
            + [SettingsKey.translationEnabled]
        for key in keys { defaults.removeObject(forKey: key) }
        OrientationManager.unlock()
        AppLog.log("settings reset to defaults")
        message = "Settings are back to their defaults."
    }
}

/// A row on the main settings list: coloured tile, title and a short description.
struct SettingsTile: View {
    let page: NexSettingsPage

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: page.symbol)
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(page.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.body.weight(.medium))
                Text(page.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
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

/// A setting name with a one-line explanation under it.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A slider with its title and current value on one line.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(Color.accentColor).monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// Shows one settings page with the app background.
struct SettingsPageView: View {
    let page: NexSettingsPage

    var body: some View {
        Group {
            switch page {
            case .setupCenter: SetupCenterView()
            case .appearance: AppearanceSettings()
            case .controls: ControlsSettings()
            case .gameplay: GameplaySettings()
            case .jit: JITSettingsView()
            case .translation: TranslationGlobalSettings()
            case .privacy: PrivacySettings()
            case .backup: BackupSettings()
            case .advanced: AdvancedSettings()
            case .diagnostics: DiagnosticsView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(SettingsKey.theme) private var theme = "dark"
    @AppStorage(SettingsKey.animatedBackground) private var animated = true
    @AppStorage(SettingsKey.backgroundTheme) private var backgroundTheme = "nebula"
    @AppStorage(SettingsKey.libraryLayout) private var layout = "grid"
    @AppStorage(SettingsKey.titleUnderCard) private var titleUnder = true
    @AppStorage(SettingsKey.showContinueCard) private var showContinue = true
    @AppStorage(SettingsKey.pixelFont) private var pixelFont = true
    @AppStorage(SettingsKey.tapOpensGamePage) private var tapOpensPage = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $pixelFont) {
                    SettingLabel("Pixel Font", "Retro pixel lettering (Departure Mono) across the app and the touch controls. Fully applies after reopening the app.")
                }
                Toggle(isOn: $tapOpensPage) {
                    SettingLabel("Tap Opens Game Page", "Tapping a game shows its page with saves, gallery and mods. Turn off to start games right away.")
                }
                Picker("Appearance", selection: $theme) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                Toggle(isOn: $animated) {
                    SettingLabel("Animated Background", "Turn off to use a still background and save battery.")
                }
            } header: {
                SettingsHeader(title: "Appearance", symbol: "paintpalette.fill", color: .indigo)
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(BackgroundTheme.allCases) { item in
                            themeButton(item)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("Background Theme")
            } footer: {
                Text("Shown behind the library and settings in dark mode.")
            }

            Section {
                Picker("Library View", selection: $layout) {
                    Label("Grid View", systemImage: "square.grid.2x2").tag("grid")
                    Label("List View", systemImage: "list.bullet").tag("list")
                }
                Toggle("Title Under the Cover", isOn: $titleUnder)
                Toggle("Continue Playing Card", isOn: $showContinue)
            } header: {
                Text("Library")
            }
        }
    }

    private func themeButton(_ item: BackgroundTheme) -> some View {
        let selected = backgroundTheme == item.rawValue
        return Button {
            backgroundTheme = item.rawValue
        } label: {
            VStack(spacing: 6) {
                BackgroundCanvas(theme: item, time: 0)
                    .frame(width: 84, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }
                Label(item.title, systemImage: item.symbol)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Controls

struct ControlsSettings: View {
    @AppStorage(SettingsKey.touchPadScale) private var padScale = 1.0
    @AppStorage(SettingsKey.touchPadOpacity) private var padOpacity = 1.0
    @AppStorage(SettingsKey.touchDirectionalType) private var directional = "layout"
    @AppStorage(SettingsKey.barOpacity) private var barOpacity = 0.85
    @AppStorage(SettingsKey.barScale) private var barScale = 1.0
    @AppStorage(SettingsKey.barDrawer) private var drawer = "horizontal"
    @AppStorage(SettingsKey.barGlass) private var glass = true
    @AppStorage(SettingsKey.barAutoHide) private var autoHide = true
    @AppStorage(SettingsKey.barShowFastForward) private var showFastForward = true
    @AppStorage(SettingsKey.barShowScreenshot) private var showScreenshot = true
    @AppStorage(SettingsKey.barShowKeyboard) private var showKeyboard = true
    @AppStorage(SettingsKey.barShowCheats) private var showCheats = true
    @AppStorage(SettingsKey.screenshotsToPhotos) private var screenshotsToPhotos = true
    @AppStorage(SettingsKey.hapticsEnabled) private var haptics = true
    @AppStorage(SettingsKey.hapticStrength) private var hapticStrength = 1
    @AppStorage(SettingsKey.physicalControllerEnabled) private var physical = true
    @AppStorage(SettingsKey.hidePadWithController) private var hidePad = true
    @AppStorage(SettingsKey.barWithController) private var barWithController = false
    @AppStorage(SettingsKey.controllerMode) private var controllerMode = "keys"

    @State private var showControllerMap = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ValueSlider(title: "Size", value: $padScale, range: 0.6...1.6) { String(format: "%.1f×", $0) }
                ValueSlider(title: "Opacity", value: $padOpacity, range: 0.2...1, format: percent)
                Picker("Control Type", selection: $directional) {
                    Text("As in Layout").tag("layout")
                    Label("Joystick", systemImage: "circle.circle").tag("joystick")
                    Label("D-Pad", systemImage: "dpad").tag("dpad")
                }
                Button("Reset Default Touch Layout") {
                    LayoutStore.resetDefault()
                    message = "The default touch layout is back to the built-in one. Games with their own layout keep it."
                }
            } header: {
                SettingsHeader(title: "Virtual Gamepad", symbol: "gamecontroller", color: .blue)
            } footer: {
                Text("Applies the next time a game starts. To move or add buttons, open a game, tap the control bar and then the pencil.")
            }

            Section {
                ValueSlider(title: "Opacity", value: $barOpacity, range: 0.3...1, format: percent)
                ValueSlider(title: "Size", value: $barScale, range: 0.7...1.4, format: percent)
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel("Drawer Direction", "Opens to the right when the bar sits on the left half of the screen, and to the left on the right half. A vertical drawer that doesn't fit opens sideways.")
                    Picker("Drawer Direction", selection: $drawer) {
                        Text("Horizontal").tag("horizontal")
                        Text("Vertical").tag("vertical")
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(isOn: $glass) { SettingLabel("Glass Effect", "Frosted-glass look for the control bar.") }
                Toggle(isOn: $autoHide) {
                    SettingLabel("Auto-Hide Controls", "Hide the control bar after 5 seconds without use; tap the screen to bring it back. Off while a controller is connected.")
                }
                Toggle(isOn: $showFastForward) { SettingLabel("Show Fast Forward Button", "RPG Maker games only.") }
                Toggle("Show Screenshot Button", isOn: $showScreenshot)
                Toggle(isOn: $screenshotsToPhotos) {
                    SettingLabel("Also Save Screenshots to Photos", "Screenshots always go to the game's Gallery.")
                }
                Toggle(isOn: $showCheats) { SettingLabel("Show Cheat Engine Button", "RPG Maker MV/MZ games only.") }
                Toggle(isOn: $showKeyboard) { SettingLabel("Show Keyboard Button", "Type letters and numbers into the game, for name entry and the like.") }
                Button("Reset Control Bar Position") {
                    UserDefaults.standard.removeObject(forKey: SettingsKey.barPosition)
                    message = "The control bar goes back to the top right corner the next time a game starts."
                }
            } header: {
                SettingsHeader(title: "Control Bar", symbol: "square.grid.2x2.fill", color: .purple)
            } footer: {
                Text("In a game, drag the NexPlay bubble anywhere and tap it to open the bar: exit, keyboard, on-screen controls, game menu, screenshot, edit controls, fast forward and the cheat engine.")
            }

            Section {
                Toggle(isOn: $haptics) { SettingLabel("Haptic Feedback", "Vibrate when pressing the D-pad or buttons.") }
                Picker("Strength", selection: $hapticStrength) {
                    Text("Light").tag(0)
                    Text("Medium").tag(1)
                    Text("Heavy").tag(2)
                }
                .disabled(!haptics)
            } header: {
                SettingsHeader(title: "Haptics", symbol: "hand.tap.fill", color: .pink)
            }

            Section {
                Toggle(isOn: $physical) { SettingLabel("Enable Physical Controller", "MFi, PlayStation and Xbox controllers.") }
                Toggle(isOn: $hidePad) { SettingLabel("Auto-hide Virtual Gamepad", "Hide on-screen controls while a controller is connected.") }
                    .disabled(!physical)
                Toggle(isOn: $barWithController) {
                    SettingLabel("Show Control Bar With Controller", "Keep the control bar visible while a controller is connected.")
                }
                .disabled(!physical)
                Picker("Controller Mode", selection: $controllerMode) {
                    Text("Send keys (remappable)").tag("keys")
                    Text("Game reads them (Gamepad API)").tag("gamepadAPI")
                }
                .disabled(!physical)
                Button {
                    showControllerMap = true
                } label: {
                    Label("Controller Mapping", systemImage: "pencil")
                }
                .disabled(!physical)
            } header: {
                SettingsHeader(title: "Physical Controller", symbol: "gamecontroller.fill", color: .green)
            }
        }
        .sheet(isPresented: $showControllerMap) { ControllerMapView(gameID: nil, gameName: nil) }
        .alert("Controls", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

// MARK: - Gameplay & Performance

struct GameplaySettings: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage(SettingsKey.autoRotateInGames) private var autoRotateGames = false
    @AppStorage(SettingsKey.newGameOrientation) private var orientation = "landscape"
    @AppStorage(SettingsKey.autoRotateOutside) private var autoRotateOutside = false
    @AppStorage(SettingsKey.portraitGameOffset) private var offset = 0.0
    @AppStorage(SettingsKey.silentModeAudio) private var silentModeAudio = true
    @AppStorage(SettingsKey.keepScreenAwake) private var keepScreenAwake = true
    @AppStorage(SettingsKey.desktopMode) private var desktopMode = true
    @AppStorage(SettingsKey.pixelatedScaling) private var pixelatedScaling = false
    @AppStorage(SettingsKey.nwMode) private var nwMode = true
    @AppStorage(SettingsKey.screenScaling) private var screenScaling = "fit"

    @State private var message: String?

    var body: some View {
        Form {
            PowerSettingsSection()
            Section {
                Toggle(isOn: $autoRotateGames) {
                    SettingLabel("Auto-rotate In Games", "Let games rotate freely with your device. Turn this off to lock games to one orientation.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel("Game Orientation", "New RPG Maker games open locked in this orientation. Landscape allows both sides.")
                    Picker("Game Orientation", selection: $orientation) {
                        Text("Landscape").tag("landscape")
                        Text("Portrait").tag("portrait")
                        Text("Auto").tag("auto")
                    }
                    .pickerStyle(.segmented)
                }
                Button("Apply to All RPG Maker Games") { applyOrientationToAll() }
                Toggle(isOn: $autoRotateOutside) {
                    SettingLabel("Auto-rotate Outside Games", "Let the library and settings follow how you hold your phone.")
                }
                .onChange(of: autoRotateOutside) { _ in OrientationManager.unlock() }
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel("Screen Scaling", "How RPG Maker games fill a screen of another shape. Fit keeps black bars, Fill crops the edges, Stretch changes the aspect.")
                    Picker("Screen Scaling", selection: $screenScaling) {
                        ForEach(ScreenScaling.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                ValueSlider(title: "Portrait Game Position", value: $offset, range: 0...0.3) { value in
                    value < 0.005 ? "Centered" : "−\(Int((value * 100).rounded()))%"
                }
            } header: {
                SettingsHeader(title: "Gameplay", symbol: "bolt.fill", color: .orange)
            } footer: {
                Text("Portrait Game Position moves the game up by this much of the screen in portrait, so the on-screen controls cover less of it. Changes apply the next time a game starts.")
            }

            Section {
                Toggle("Play Sound in Silent Mode", isOn: $silentModeAudio)
                Toggle("Keep Screen Awake While Playing", isOn: $keepScreenAwake)
                Toggle("Desktop Mode (RPG Maker)", isOn: $desktopMode)
                Toggle("Sharp Pixels (RPG Maker)", isOn: $pixelatedScaling)
                Toggle("NW.js Mode: Saves as Files", isOn: $nwMode)
            } header: {
                SettingsHeader(title: "Performance", symbol: "speedometer", color: .red)
            } footer: {
                Text("Desktop mode lets MV and MZ run as on a PC (normal audio, full update rate, full height). NW.js mode keeps saves as files in the game's save folder, so they can be backed up, exported and rescued. Each game can override these in its Info & Settings.")
            }
        }
        .alert("Orientation", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func applyOrientationToAll() {
        let mode = OrientationMode(rawValue: orientation) ?? .landscape
        var count = 0
        for game in store.games where game.engine.isRPGMaker || game.engine.isRuby {
            store.mutate(game.id) { $0.orientation = mode }
            count += 1
        }
        message = count == 0 ? "No RPG Maker games yet." : "\(count) game(s) now open in \(mode.title.lowercased())."
    }
}

// MARK: - Translation

struct TranslationGlobalSettings: View {
    @AppStorage(SettingsKey.translationEnabled) private var translation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $translation) {
                    SettingLabel("Translate MV/MZ Games", "Configure in-game text translation per game from the game menu (Translation…).")
                }
            } header: {
                SettingsHeader(title: "Translation", symbol: "character.bubble.fill", color: .teal)
            } footer: {
                Text("Uses an MTool TranslateFile.json from the game folder or imported in the game menu. Works offline; nothing is sent anywhere. Each game can override this. Turn it on before starting a game.")
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @EnvironmentObject private var privacy: PrivacyLock

    var body: some View {
        Form {
            Section {
                LabeledContent("Hidden Games", value: "\(privacy.hiddenGames.count)")
                Button {
                    if privacy.isUnlocked {
                        privacy.lock()
                    } else {
                        Task { await privacy.unlock() }
                    }
                } label: {
                    Label(privacy.isUnlocked ? "Lock Hidden Games Now" : "Show Hidden Games…",
                          systemImage: privacy.isUnlocked ? "lock.fill" : "faceid")
                }
                Button("Unhide All Games", role: .destructive) {
                    let ids = privacy.hiddenGames
                    for id in ids { privacy.setHidden(id, false) }
                }
                .disabled(privacy.hiddenGames.isEmpty || !privacy.isUnlocked)
            } header: {
                SettingsHeader(title: "Privacy Lock", symbol: "lock.fill", color: .green)
            } footer: {
                Text("Hide a game from its long-press menu in the library, and a collection from Collections. Hidden games and collections stay completely hidden in your library until you unlock with Face ID, Touch ID or your passcode. They lock again when NexPlay goes to the background.")
            }
        }
    }
}

// MARK: - Import & Backup

struct BackupSettings: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage(SettingsKey.autoBackup) private var autoBackup = true
    @AppStorage(SettingsKey.backupRetention) private var retention = 10

    @State private var shareURL: URL?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoBackup) {
                    SettingLabel("Auto Backup Saves", "Back up save files when you stop playing and when NexPlay goes to the background.")
                }
                Picker("Keep", selection: $retention) {
                    Text("Less (last 5)").tag(5)
                    Text("Standard (last 10)").tag(10)
                    Text("More (last 20)").tag(20)
                }
                Button("Back Up All Now") { backUpNow() }
                Button("Export All Saves (ZIP)…") { exportAll() }
            } header: {
                SettingsHeader(title: "Import & Backup", symbol: "externaldrive.fill", color: .purple)
            } footer: {
                Text("Backups cover save files (NW.js mode) and are only made when saves changed. Restore one from the game's Info & Settings. NexPlay imports ZIP, 7z and RAR archives, game folders and HTML files; opening a saves ZIP from the Files app offers to restore it.")
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in ActivityView(items: [item.url]) }
        .alert("Backups", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
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

// MARK: - Advanced

struct AdvancedSettings: View {
    var body: some View {
        Form {
            Section {
                NavigationLink { EnginesSettingsView() } label: { Label("Engines & Runtimes", systemImage: "cpu") }
                NavigationLink { StorageView() } label: { Label("Storage", systemImage: "internaldrive") }
                NavigationLink { StatsView() } label: { Label("Play Stats", systemImage: "chart.bar.fill") }
                NavigationLink { WhatsNewView(standalone: false) } label: { Label("What's New", systemImage: "sparkles") }
                NavigationLink("App Log") { AppLogView() }
                NavigationLink("Credits") { CreditsView() }
            } header: {
                SettingsHeader(title: "Advanced", symbol: "wrench.and.screwdriver.fill", color: .gray)
            } footer: {
                Text("The app log lists imports, backups and crash notes. Each game also has its own Game Log in the game menu.")
            }
        }
    }
}

struct CreditsView: View {
    var body: some View {
        List {
            Section("Adapted code") {
                Text("Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app, and mvmz-apple-mobile, https://github.com/mateo-m/mvmz-apple-mobile (GPL-3.0-only with additional terms): RPG Maker runtime (speed, pause, focus), NW.js shim, game file server, archive extraction with the system libarchive, save rescue and displaced-copy handling, controls model and touch handling ideas, controller bindings, backup retention and import pipeline invariants.")
                Text("Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)")
                Text("BCD (GPL-3.0 with the BCD additional terms and the Madeira Converter Exception) is a fork of Madeira by Will Faust, https://github.com/willfaust/Madeira (GPL-3.0-or-later): entitlement, signing and device checks (Diagnostics), entitlements set; built-in JIT: the helper extension and how it is started, the pairing-file store, the JIT script (madeira-jit.js), the BRK #0xf00d calls and the JIT test page (portions copyright 2026 SirDank, from Madeira).")
                Text("Windows games: BCD itself (Wine, FEX-Emu, DXMT, its interface and game manager), built unchanged from https://github.com/thebcd69/bcd-games as BCDCore.framework by NexPlay's tools/windows and opened from Setup Center. BCD's licence files and those of Wine (LGPL-2.1+), FEX-Emu (MIT), DXMT (zlib), MoltenVK (Apache-2.0) and its other parts ship inside the app with the runtime.")
            }
            Section("Libraries") {
                Text("StikJIT, https://github.com/StikDebug/StikJIT (MPL-2.0), based on StikDebug: built-in JIT (debugger attach over LocalDevVPN, Developer Disk Image). It bundles idevice, Copyright (c) Jackson Coxson, https://github.com/jkcoxson/idevice (MIT).")
                Text("EasyRPG Player, https://easyrpg.org (GPL-3.0), with liblcf (MIT): runs RPG Maker 2000/2003 games natively. Its libretro core comes from the libretro buildbot (https://buildbot.libretro.com); NexPlay's frontend follows the libretro API (libretro.h, MIT, The RetroArch team).")
                Text("ZIPFoundation, Copyright (c) 2017-2026 Thomas Zoechling, https://github.com/weichsel/ZIPFoundation (MIT).")
                Text("libarchive (part of iOS), https://www.libarchive.org (BSD-2-Clause): 7z, RAR and TAR import.")
                Text("Godot Engine web runtimes (official export templates), Copyright (c) 2014-present Godot Engine contributors, https://godotengine.org/license (MIT): run desktop Godot games.")
                Text("Ren'Py and RenPyWeb, Copyright 2004-present Tom Rothamel and contributors, https://www.renpy.org (MIT; RenPyWeb by Sylvain Beucler and Teyut): the web runtimes and engine files that run Ren'Py games. The .rpa reader follows renpy/loader.py.")
                Text("Ruffle, Copyright (c) the Ruffle LLC contributors, https://ruffle.rs (MIT or Apache-2.0): runs Flash games.")
                Text("Departure Mono, Copyright 2022–2024 Helena Zhang, https://departuremono.com (SIL Open Font License 1.1): the pixel font.")
            }
            Section("RPG Maker XP/VX/Ace core (only in builds with the mkxp core)") {
                Text("mkxp-z, https://github.com/mkxp-z/mkxp-z (GPLv2 or later), built for iOS by mkxp-z-apple-mobile, https://github.com/mateo-m/mkxp-z-apple-mobile (GPL), with Ruby (Ruby license / BSD-2-Clause), SDL (zlib), ANGLE (BSD-3-Clause), FluidSynth (LGPL-2.1) and the other libraries its licenses.json lists. Core contract and build scripts from Empo (GPL-3.0-only with additional terms).")
            }
            Section("Ideas only (no code)") {
                Text("RPGPlayer, ArkRPG, JoiPlay, Runa, QuestPlay, RPGEmu: feature ideas such as the control bar, settings layout, background themes, collections, plugin manager, cheats, storage manager, MTool translation files and encoding repair; the game page, save profiles, media browser, mods page and the touch-control edit mode follow RPGPlayer's screenshots.")
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
