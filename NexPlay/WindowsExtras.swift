import SwiftUI
import UIKit

// 7.12.0: what SPEC-7.0 8.4/8.5 and SPEC-7.0-review C5 add around Windows games:
// - per-game Run Options (arguments, environment, locale) for every runtime that can use them,
// - the JIT sheet shown before a Windows game when JIT is off,
// - the Windows panel (Performance, Input, Windows) behind a button on BCD's screen.

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
    /// true = JIT is on (or the player chose to let Windows Games handle it), false = cancelled.
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
                    Button("Let Windows Games Handle It") { finish(true) }
                } footer: {
                    Text("Windows Games can also turn JIT on itself when the game starts.")
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

/// The panel behind the ⋯ button on BCD's screen (SPEC-7.0 8.4 Windows cards).
struct WindowsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    let gameName: String
    let hudOn: Bool
    let onToggleHUD: () -> Void
    let onRestart: () -> Void
    let onExit: () -> Void
    @State private var copied = false

    private var windowsLog: [String] {
        AppLog.shared.text.split(separator: "\n").filter { $0.contains("windows") || $0.contains("jit:") }.suffix(80).map(String.init)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PanelCard("Performance", symbol: "speedometer") {
                        Toggle("Performance HUD", isOn: Binding(get: { hudOn }, set: { _ in onToggleHUD(); dismiss() }))
                        Text("CPU, memory, temperature and battery. FPS limit and render scale are in Windows Games' own settings for this game.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    PanelCard("Input", symbol: "gamecontroller.fill") {
                        Text("Windows Games maps controllers to XInput and has its own touch controls and mouse modes (its game settings).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    PanelCard("Windows", symbol: "pc") {
                        Button {
                            dismiss()
                            onRestart()
                        } label: {
                            Label("Restart Game", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PlayButtonStyle())
                        Button {
                            UIPasteboard.general.string = DeviceInfo.report() + "\n\n" + windowsLog.joined(separator: "\n")
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Log for Claude", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            dismiss()
                            onExit()
                        } label: {
                            Label("Back to Library", systemImage: "xmark.circle")
                        }
                    }
                    PanelCard("Log", symbol: "list.bullet.rectangle") {
                        Text(windowsLog.suffix(30).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(gameName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { SheetCloseButton { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
