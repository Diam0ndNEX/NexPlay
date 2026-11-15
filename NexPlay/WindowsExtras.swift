import SwiftUI
import UIKit

// 7.12.0: what SPEC-7.0 8.4/8.5 and SPEC-7.0-review C5 add around Windows games:
// - per-game Run Options (arguments, environment, locale) for every runtime that can use them,
// - the JIT sheet shown before a Windows game when JIT is off,
// - the Windows panel (Performance, Input, Windows) behind the ⋯ button over a running Windows game.

/// Per-game Run Options. Stored in `Game.runOptions`.
struct RunOptions: Codable, Hashable {
    /// Extra command-line arguments, separated by spaces ("quoted parts" stay together).
    var arguments: String?
    /// KEY=VALUE, one per line.
    var environment: String?
    /// A language tag such as ja-JP; nil = the iPhone's.
    var locale: String?

    var isEmpty: Bool {
        (arguments ?? "").isEmpty && (environment ?? "").isEmpty && (locale ?? "").isEmpty
    }

    /// Arguments split on spaces, keeping "quoted parts" together.
    var argumentList: [String] {
        var list: [String] = []
        var current = ""
        var quoted = false
        for character in arguments ?? "" {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { list.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { list.append(current) }
        return list
    }

    var environmentPairs: [(String, String)] {
        (environment ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// A page script that makes navigator.language(s) report the chosen locale (web, Godot, Ren'Py, Twine games).
    static func localeScript(_ locale: String) -> String {
        let tag = PageScripts.jsString(locale)
        return """
        (function () {
            try {
                Object.defineProperty(navigator, 'language', { get: function () { return \(tag); } });
                Object.defineProperty(navigator, 'languages', { get: function () { return [\(tag)]; } });
            } catch (e) {}
        })();
        """
    }

    static let locales: [(String, String)] = [
        ("", "iPhone Language"), ("en-US", "English"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"), ("ko-KR", "Korean"), ("de-DE", "German"), ("fr-FR", "French"),
        ("es-ES", "Spanish"), ("pt-BR", "Portuguese (Brazil)"), ("ru-RU", "Russian"),
    ]
}

/// Game Settings > Run Options.
struct RunOptionsSection: View {
    @EnvironmentObject private var store: LibraryStore
    let game: Game

    private func binding(_ keyPath: WritableKeyPath<RunOptions, String?>) -> Binding<String> {
        Binding(
            get: { game.runOptions?[keyPath: keyPath] ?? "" },
            set: { value in
                store.mutate(game.id) { g in
                    var options = g.runOptions ?? RunOptions()
                    options[keyPath: keyPath] = value.isEmpty ? nil : value
                    g.runOptions = options.isEmpty ? nil : options
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker(selection: binding(\.locale)) {
                ForEach(RunOptions.locales, id: \.0) { item in Text(item.1).tag(item.0) }
            } label: { Label("Language", systemImage: "globe") }
            TextField("Arguments", text: binding(\.arguments))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (KEY=VALUE per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding(\.environment))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 70)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            SettingsHeader(title: "Run Options", symbol: "terminal.fill", color: .gray)
        } footer: {
            Text("Language: web games see it as the browser language; Windows games get it as LANG. Arguments: Godot desktop games and Windows programs. Environment: Windows games. Restart the game after changing these.")
        }
    }
}

/// The JIT sheet before a Windows game (SPEC-7.0 8.5): pairing file, LocalDevVPN, Enable JIT, with live ticks.
struct JITSheetView: View {
    @ObservedObject private var jit = JITManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false
    let gameName: String
    /// true = JIT is on (or the player chose to start anyway), false = cancelled.
    let onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step("Pairing File", ok: jit.pairingPresent,
                         detail: jit.pairingKind ?? "Lets NexPlay talk to this iPhone's debug service.") {
                        Button(jit.pairingPresent ? "Replace" : "Import") { ImportPicker.pickOneFile { jit.importPairing($0) } }
                    }
                    step("LocalDevVPN", ok: jit.vpnReachable,
                         detail: jit.vpnDetail ?? "Connects NexPlay to itself through 10.7.0.1.") {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                    }
                    step("JIT", ok: jit.isActive ? true : (jit.error == nil ? nil : false),
                         detail: jit.error ?? jit.status ?? "Windows games translate x86 code, which needs JIT.") {
                        if jit.busy {
                            ProgressView()
                        } else {
                            Button("Enable") {
                                jit.enable { ok in if ok { finish(true) } }
                            }
                            .disabled(!jit.pairingPresent)
                        }
                    }
                } footer: {
                    Text("\(gameName) runs through Windows. Turn JIT on once per app launch.")
                }
                Section {
                    Button("Use StikDebug Instead") { jit.enableWithStikDebug() }
                    Button("Start Anyway") { finish(true) }
                } footer: {
                    Text("The game asks for JIT again when it starts, with the same pairing file.")
                }
            }
            .navigationTitle("Turn On JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetHelpButton(title: "Why JIT?", text: "Windows games are x86 programs. NexPlay translates them to ARM while they run (FEX), and iOS only allows that with JIT. You need a pairing file (made once on a computer or with an app like SideStore/StikDebug's tools) and LocalDevVPN connected.")
                }
            }
            .onAppear { jit.refresh() }
            .onChange(of: jit.isActive) { active in if active { finish(true) } }
        }
        .interactiveDismissDisabled()
    }

    private func step<Trailing: View>(_ title: String, ok: Bool?, detail: String,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(ok == true ? Color.green : (ok == false ? Color.red : Color.secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        dismiss()
        onDone(ok)
    }
}

/// The panel over a running Windows game (⋯ button, BCD's menu button and its controller chord; 8.3.1: NexPlay's
/// in-game menu). With the engine it shows BCD's in-game menu (`bcd`: BCD's rows in NexPlay's look,
/// NexPlayBCDMenu.swift) next to NexPlay's own sections: Performance HUD, Controls Style and presets, the log.
struct WindowsPanelView: View {
    let gameName: String
    let hudOn: Bool
    let onToggleHUD: () -> Void
    /// nil: no Restart Game (8.0.0: the engine runs one Windows game per app run).
    let onRestart: (() -> Void)?
    let onExit: () -> Void
    /// 8.3.1: closes the panel (and BCD's menu).
    var onClose: () -> Void = {}
    /// 8.2.0: Controls Style and the touch-control editor (engine builds).
    var controls: Controls? = nil
    /// 8.3.1: BCD's in-game menu (engine builds, while a game runs).
    var bcd: BCDPart? = nil

    @State private var copied = false
    @State private var styleChoice: ControlsStyle??
    @State private var hud: Bool?
    @State private var tab = "game"
    @State private var pages: [String] = []
    @State private var question: NexMenuQuestion?

    struct Controls {
        let game: Game
        let onStyle: (ControlsStyle?) -> Void
        let onEdit: () -> Void
        /// 8.2.1: a layout preset for the game's Controls Style.
        let onPreset: (LayoutPreset) -> Void
    }

    /// What NexPlayBCDMenu.swift gives the panel; this file names no BCD type.
    struct BCDPart {
        let subtitle: () -> String
        let content: (String, Binding<[String]>, Binding<NexMenuQuestion?>) -> AnyView
        let pageTitle: (String) -> String?
    }

    private let tabs = [
        NexMenuTab(id: "game", title: "Game"),
        NexMenuTab(id: "display", title: "Display"),
        NexMenuTab(id: "controls", title: "Controls"),
        NexMenuTab(id: "tools", title: "Tools"),
    ]

    private static let presetsPage = "nex.presets"

    private var windowsLog: [String] {
        AppLog.shared.text.split(separator: "\n").filter { $0.contains("windows") || $0.contains("jit:") }.suffix(80).map(String.init)
    }

    private var hudShown: Bool { hud ?? hudOn }

    private var pageTitle: String? {
        guard let last = pages.last else { return nil }
        if last == Self.presetsPage { return "Layout Preset" }
        return bcd?.pageTitle(last) ?? "Windows"
    }

    var body: some View {
        NexInGameMenu(eyebrow: bcd.map { "PC · " + $0.subtitle() } ?? "PC", title: gameName,
                      symbol: GameEngine.windows.symbol, tint: GameEngine.windows.accent, tabs: tabs, tab: $tab,
                      pageTitle: pageTitle, back: pages.isEmpty ? nil : { pages.removeLast() },
                      question: $question, close: onClose) {
            if pages.last == Self.presetsPage {
                presetsPage
            } else if !pages.isEmpty, let bcd {
                bcd.content(tab, $pages, $question)
            } else {
                switch tab {
                case "display": displayTab
                case "controls": controlsTab
                case "tools": toolsTab
                default: gameTab
                }
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder private var gameTab: some View {
        if let bcd {
            bcd.content("game", $pages, $question)
        } else {
            Button {
                onClose()
            } label: {
                Label("Back to Game", systemImage: "play.fill")
            }
            .buttonStyle(NexPrimaryButtonStyle())
            NexMenuSection("Game") {
                NexMenuRow(title: "Quit Game", detail: "Progress you haven't saved is lost.", symbol: "stop.circle",
                           destructive: true) {
                    question = NexMenuQuestion(title: "Quit the game?",
                                               message: "What you haven't saved is lost. NexPlay runs one Windows game per launch: to play another Windows game afterwards, close NexPlay and open it again.",
                                               answer: "Quit Game", destructive: true) { onExit() }
                }
            }
        }
        if let onRestart {
            NexMenuSection {
                NexMenuRow(title: "Restart Game", symbol: "arrow.clockwise") { onRestart() }
            }
        }
    }

    @ViewBuilder private var displayTab: some View {
        NexMenuSection("Performance HUD") {
            NexMenuToggleRow(title: "Show Stats", detail: bcd == nil ? "CPU, memory, temperature and battery over the game"
                                 : "BCD's HUD in the \(HUDLayout.current.title) layout: the engine's frame rate, load, memory, heat. The rows below fine-tune it.",
                             symbol: "speedometer", isOn: hudShown) { value in
                onToggleHUD()
                hud = value
            }
        }
        if let bcd { bcd.content("display", $pages, $question) }
    }

    @ViewBuilder private var controlsTab: some View {
        if let controls {
            NexMenuSection("Controls Style") {
                NexMenuCustomRow {
                    ControlsStylePicker(game: controls.game, choice: styleChoice ?? controls.game.controlsStyle) { style in
                        styleChoice = .some(style)
                        controls.onStyle(style)
                    }
                }
                NexMenuRow(title: "Edit Touch Controls", symbol: "slider.horizontal.below.square.and.square.filled",
                           accessory: .chevron) {
                    onClose()
                    controls.onEdit()
                }
                NexMenuRow(title: "Layout Preset", detail: "Replaces the touch layout of the game's Controls Style",
                           symbol: "square.on.square", accessory: .chevron) { pages.append(Self.presetsPage) }
            }
        }
        if let bcd {
            bcd.content("controls", $pages, $question)
        } else {
            NexMenuNote(text: "Controllers reach the game as XInput pads.")
        }
    }

    @ViewBuilder private var presetsPage: some View {
        if let controls {
            NexMenuSection {
                ForEach(LayoutPreset.allCases) { preset in
                    NexMenuRow(title: preset.title, symbol: preset.symbol) {
                        controls.onPreset(preset)
                        pages.removeLast()
                    }
                }
            }
        }
    }

    @ViewBuilder private var toolsTab: some View {
        if let bcd { bcd.content("tools", $pages, $question) }
        NexMenuSection("NexPlay") {
            NexMenuRow(title: copied ? "Copied" : "Copy Log for Claude", symbol: "doc.on.doc") {
                UIPasteboard.general.string = DeviceInfo.report() + "\n\n" + windowsLog.joined(separator: "\n")
                copied = true
            }
            NexMenuCustomRow {
                Text(windowsLog.suffix(30).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NexColor.textSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
