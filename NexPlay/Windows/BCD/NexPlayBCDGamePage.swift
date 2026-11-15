// NexPlay's code (not BCD's), compiled only with the Windows engine (NexPlay 8.4.1).
// The PC sections of BCD's game page (graphics and GPU, Windows/prefix tools, components and installers, CPU translation,
// game fixes, controls, launch, save backups, help, AutoTune, recommended settings, the game's config) drawn with
// NexPlay's menu rows on NexPlay's game page. The data and every change go through BCD's own backend
// (BCDGameDetailBackend, BCDGamePageLive), so no BCD file changes. BCD by thebcd69:
// https://github.com/thebcd69/bcd-games (GPL-3.0-only with BCD's additional terms).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

import SwiftUI

/// A NexPlay game as BCD's game page sees it: the library entry NexPlay's launcher made for its program.
@MainActor enum NexBCDGamePage {
    /// BCD's sections NexPlay doesn't show: stores (hidden in NexPlay), the game's name/cover/removal (NexPlay's own
    /// Options do those) and BCD's external-drive location.
    static let hiddenGroups: Set<String> = ["steam", "dlc", "version", "download", "library", "location"]

    static var backend: BCDGameDetailBackend? { BCDGameDetailSource.backend }

    /// BCD's library entry for the game's program; made (with the drive link) when `create` and BCD's drive is set up.
    static func entry(for game: Game, create: Bool) -> LibraryEntry? {
        guard let program = WindowsGameFiles.program(for: game) else { return nil }
        let paths = WindowsLibraryLink.paths(for: game, program: program)
        let key = paths.relative.lowercased()
        func find() -> LibraryEntry? {
            LibraryModel.shared.entries.first { $0.desktop != true && $0.relativePath.lowercased() == key }
        }
        if let found = find() { return found }
        guard create, WindowsLibraryLink.driveReady else { return nil }
        do {
            try WindowsLibraryLink.make(for: game)
        } catch {
            AppLog.log("windows: \(game.name): game page couldn't link the game: \(error.localizedDescription)")
            return nil
        }
        let arguments = game.runOptions.map { $0.argumentList.joined(separator: " ") }
        guard NexWindowsHost.addGame(relativePath: paths.relative, title: game.name, arguments: arguments) else { return nil }
        return find()
    }

    static func bcdGame(_ entry: LibraryEntry, title: String) -> BCDGame {
        var game = BCDGame(id: BCDLiveID.local(entry.id), title: title, store: .local, state: .ready, size: entry.folderBytes)
        game.lastPlayed = entry.lastPlayed
        game.thirtyTwoBit = entry.bits == 32
        return game
    }
}

/// The PC Setup page of a Windows game's game page.
@MainActor
struct NexBCDPCSetupView: View {
    let game: Game

    private enum Page: Hashable {
        case group(String)
        case setting(String)
        case config
    }

    private struct Asking: Identifiable {
        let id = UUID()
        let question: BCDGameQuestion
        let run: () -> Void
    }

    @State private var target: BCDGame?
    @State private var details = BCDGameDetails()
    @State private var path: [Page] = []
    @State private var missing: String?
    @State private var status: String?
    @State private var asking: Asking?
    @State private var draft = ""
    @State private var configDraft = ""
    @State private var opened = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { root }
                    .padding(16)
            }
            .background(NexColor.dark(.ground))
            .navigationTitle("PC Setup")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { pageView(page) }
                        .padding(16)
                }
                .background(NexColor.dark(.ground))
                .navigationTitle(title(of: page))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .font(NexType.body)
        .environment(\.colorScheme, .dark)
        .onAppear { load() }
        .onDisappear { NexBCDGamePage.backend?.onChange = nil }
        .confirmationDialog(asking?.question.title ?? "", isPresented: Binding(
            get: { asking != nil }, set: { if !$0 { asking = nil } }
        ), titleVisibility: .visible) {
            if let asking {
                Button(asking.question.confirm, role: asking.question.destructive ? .destructive : nil) {
                    asking.run()
                    self.asking = nil
                }
                Button("Cancel", role: .cancel) { self.asking = nil }
            }
        } message: {
            Text(asking?.question.message ?? "")
        }
    }

    // MARK: Loading

    private func load() {
        guard let backend = NexBCDGamePage.backend else {
            missing = "The Windows engine's game settings aren't in this build."
            return
        }
        guard let entry = NexBCDGamePage.entry(for: game, create: true) else {
            missing = WindowsLibraryLink.driveReady
                ? "NexPlay couldn't find this game's Windows program. Pick it in Options > Windows > Program."
                : "The Windows drive is set up the first time a Windows game starts. Play once, then the PC settings show here."
            return
        }
        let made = NexBCDGamePage.bcdGame(entry, title: game.name)
        target = made
        missing = nil
        backend.onChange = { reload() }
        if !opened {
            opened = true
            backend.opened(made)
        }
        reload()
    }

    private func reload() {
        guard let target, let backend = NexBCDGamePage.backend else { return }
        details = backend.details(for: target, settings: true)
    }

    private func set(_ setting: BCDGameSetting, _ value: String) {
        guard let target, let backend = NexBCDGamePage.backend, setting.locked == nil else { return }
        guard setting.kind == .action || setting.value != value else { return }
        let run = {
            backend.set(setting.id, to: value, for: target)
            NexHaptics.selection()
            reload()
        }
        let question = setting.kind == .action ? setting.question : setting.choices.first { $0.value == value }?.question
        if let question {
            asking = Asking(question: question, run: run)
        } else {
            run()
        }
    }

    private var groups: [BCDGameSettingGroup] {
        details.groups.filter { $0.parent == nil && !NexBCDGamePage.hiddenGroups.contains($0.id) }
    }

    // MARK: The first page

    @ViewBuilder private var root: some View {
        if let missing {
            NexMenuSection {
                NexMenuNote(text: missing, symbol: "info.circle.fill", tint: NexColor.dark(.text))
            }
        } else {
            if let status {
                NexMenuNote(text: status, symbol: "checkmark.circle.fill", tint: NexColor.dark(.success))
            }
            summarySection
            recommendedSection
            tuningSection
            NexMenuSection("Settings") {
                ForEach(groups) { group in
                    NexMenuRow(title: group.title, detail: group.summary, symbol: group.symbol, accessory: .chevron) {
                        path.append(.group(group.id))
                    }
                }
                if let count = details.configSettings {
                    NexMenuRow(title: "Game Config", detail: BCDGameText.settings(count), symbol: "doc.text", accessory: .chevron) {
                        configDraft = target.flatMap { NexBCDGamePage.backend?.configText(for: $0) } ?? ""
                        path.append(.config)
                    }
                }
            }
            NexMenuNote(text: "These are the Windows engine's settings for this game. Most apply at the next start.")
        }
    }

    @ViewBuilder private var summarySection: some View {
        let lines = [details.program.map { "Program: \($0)" }, details.settings.map { "Settings: \($0)" }].compactMap { $0 }
        if !lines.isEmpty || details.readiness != nil || !details.blockers.isEmpty || details.needsWineMono {
            NexMenuSection {
                ForEach(lines, id: \.self) { line in NexMenuNote(text: line, tint: NexColor.dark(.text)) }
                ForEach(details.blockers, id: \.self) { line in
                    NexMenuNote(text: line, symbol: "exclamationmark.triangle.fill", tint: NexColor.dark(.warning))
                }
                if let readiness = details.readiness {
                    NexMenuNote(text: readiness, symbol: "shippingbox", tint: NexColor.dark(.warning))
                }
                if details.needsWineMono {
                    NexMenuNote(text: "The last start needed Wine Mono (.NET), which isn't on this device yet.",
                                symbol: "exclamationmark.triangle.fill", tint: NexColor.dark(.warning))
                }
            }
        }
    }

    @ViewBuilder private var recommendedSection: some View {
        if let rec = details.recommendation, let target, let backend = NexBCDGamePage.backend {
            NexMenuSection("Recommended Settings") {
                NexMenuNote(text: (rec.title.map { "Tested settings for \($0). " } ?? "The engine's standard settings for any game. ") + rec.source,
                            symbol: "wand.and.stars", tint: NexColor.dark(.text))
                NexMenuRow(title: rec.inUse ? "Recommended Settings in Use" : "Use Recommended Settings", symbol: "checkmark.seal",
                           accessory: .check(rec.inUse), enabled: !rec.inUse) {
                    asking = Asking(question: BCDGameQuestion(title: "Use the recommended settings?",
                                                              message: "This game's own settings are replaced by the recommended ones.",
                                                              confirm: "Use Recommended", destructive: false)) {
                        backend.resetToRecommended(target)
                        status = "The recommended settings are back."
                        reload()
                    }
                }
                NexMenuRow(title: "Get the Latest List", symbol: "arrow.down.circle") {
                    Task {
                        let result = await backend.refreshRecommendedSettings(for: target)
                        if case .available(let changes) = result {
                            asking = Asking(question: BCDGameQuestion(title: "Newer recommended settings",
                                                                      message: "\(changes) of this game's settings differ from the newest list. Use the list?",
                                                                      confirm: "Use the Newest List", destructive: false)) {
                                backend.applyRecommendedSettings(target)
                                status = "Updated: \(changes) change\(changes == 1 ? "" : "s")"
                                reload()
                            }
                        } else {
                            status = result.line
                        }
                        reload()
                    }
                }
            }
        }
    }

    @ViewBuilder private var tuningSection: some View {
        if let target, let backend = NexBCDGamePage.backend {
            if let tuning = details.tuning {
                NexMenuSection("AutoTune") {
                    NexMenuToggleRow(title: "AutoTune", detail: tuning.status ?? "Tries settings at each start until the game runs well.",
                                     symbol: "dial.medium", isOn: tuning.on) { on in
                        backend.setTuning(on, for: target)
                        reload()
                    }
                    if tuning.canUndo {
                        NexMenuRow(title: "Undo AutoTune's Last Change", symbol: "arrow.uturn.backward") {
                            backend.undoTuning(target)
                            reload()
                        }
                    }
                    if !tuning.found.isEmpty {
                        NexMenuRow(title: "Keep Its Findings", detail: tuning.found.joined(separator: "; "), symbol: "square.and.arrow.down") {
                            backend.writeTuningLines(target)
                            status = "Written into this game's config."
                            reload()
                        }
                    }
                    ForEach(Array(tuning.history.prefix(4).enumerated()), id: \.offset) { _, step in
                        NexMenuNote(text: step.title + " · " + step.detail)
                    }
                }
            } else if !AutoTune.preferred {
                NexMenuSection("AutoTune") {
                    NexMenuRow(title: "Turn On AutoTune", detail: "For every Windows game, from the next launch of NexPlay.", symbol: "dial.medium") {
                        AutoTune.preferred = true
                        status = "AutoTune is on from the next launch."
                    }
                }
            }
        }
    }

    // MARK: Pages

    private func title(of page: Page) -> String {
        switch page {
        case .group(let id): return details.groups.first { $0.id == id }?.title ?? "Settings"
        case .setting(let id): return details.setting(id)?.setting.title ?? "Setting"
        case .config: return "Game Config"
        }
    }

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case .group(let id):
            if let group = details.groups.first(where: { $0.id == id }) {
                groupPage(group)
            } else {
                NexMenuNote(text: "This section isn't available now.")
            }
        case .setting(let id):
            if let setting = details.setting(id)?.setting {
                settingPage(setting)
            } else {
                NexMenuNote(text: "This setting isn't available now.")
            }
        case .config:
            configPage
        }
    }

    /// A section: its settings in runs under their headings.
    @ViewBuilder private func groupPage(_ group: BCDGameSettingGroup) -> some View {
        if let note = group.note {
            NexMenuNote(text: note, symbol: "exclamationmark.triangle.fill", tint: NexColor.dark(.warning))
        }
        ForEach(runs(group.settings), id: \.first) { run in
            NexMenuSection(run.heading) {
                ForEach(run.settings) { setting in row(setting) }
            }
        }
    }

    private struct Run {
        let heading: String?
        let settings: [BCDGameSetting]
        var first: String { settings.first?.id ?? "" }
    }

    private func runs(_ settings: [BCDGameSetting]) -> [Run] {
        var list: [Run] = []
        var current: [BCDGameSetting] = []
        var heading: String?
        for setting in settings {
            if setting.heading != nil, !current.isEmpty {
                list.append(Run(heading: heading, settings: current))
                current = []
            }
            if current.isEmpty { heading = setting.heading }
            current.append(setting)
        }
        if !current.isEmpty { list.append(Run(heading: heading, settings: current)) }
        return list
    }

    @ViewBuilder private func row(_ setting: BCDGameSetting) -> some View {
        let detail = setting.locked ?? setting.note
        switch setting.kind {
        case .choice:
            NexMenuRow(title: setting.title, detail: detail, accessory: .value(setting.summary)) {
                path.append(.setting(setting.id))
            }
        case .toggle:
            NexMenuToggleRow(title: setting.title, detail: detail, isOn: setting.isOn, enabled: setting.locked == nil) { on in
                set(setting, on ? "1" : "0")
            }
        case .text:
            NexMenuRow(title: setting.title, detail: detail, accessory: .value(setting.summary)) {
                draft = setting.value
                path.append(.setting(setting.id))
            }
        case .info:
            NexMenuCustomRow {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(setting.title).font(NexType.label)
                        Spacer(minLength: 8)
                        Text(setting.value).font(NexType.caption).foregroundStyle(NexColor.dark(.textSoft))
                            .multilineTextAlignment(.trailing)
                    }
                    if let note = setting.note {
                        Text(note).font(NexType.caption).foregroundStyle(NexColor.dark(.textSoft))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .action:
            NexMenuRow(title: setting.title, detail: detail, destructive: setting.destructive, enabled: setting.locked == nil) {
                set(setting, "run")
            }
        case .opens(let screen):
            if case .section(let id) = screen {
                NexMenuRow(title: setting.title, detail: detail,
                           accessory: setting.summary.isEmpty ? .chevron : .value(setting.summary)) {
                    path.append(.group(id))
                }
            }
        }
    }

    /// A setting's own page: its choices, or its text with quick picks.
    @ViewBuilder private func settingPage(_ setting: BCDGameSetting) -> some View {
        if let note = setting.locked ?? setting.note {
            NexMenuNote(text: note, tint: setting.locked != nil ? NexColor.dark(.warning) : NexColor.dark(.textSoft))
        }
        switch setting.kind {
        case .choice(let list):
            ForEach(choiceRuns(list), id: \.first) { run in
                NexMenuSection(run.heading) {
                    ForEach(run.choices) { choice in
                        NexMenuRow(title: choice.label, accessory: .check(setting.value == choice.value),
                                   enabled: setting.locked == nil) {
                            set(setting, choice.value)
                        }
                    }
                }
            }
        case .text(let prompt):
            NexMenuSection {
                NexMenuCustomRow {
                    TextField(prompt, text: $draft, axis: .vertical)
                        .font(NexType.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                NexMenuRow(title: "Save", symbol: "checkmark", enabled: draft != setting.value) {
                    set(setting, draft)
                }
            }
            if !setting.chips.isEmpty {
                NexMenuSection("Quick Picks") {
                    ForEach(setting.chips) { chip in
                        let words = draft.split(separator: " ").map(String.init)
                        NexMenuRow(title: chip.value, detail: chip.note, accessory: .check(words.contains(chip.value))) {
                            if words.contains(chip.value) {
                                draft = words.filter { $0 != chip.value }.joined(separator: " ")
                            } else {
                                draft = (words + [chip.value]).joined(separator: " ")
                            }
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private struct ChoiceRun {
        let heading: String?
        let choices: [BCDGameChoice]
        var first: String { choices.first?.value ?? "" }
    }

    private func choiceRuns(_ list: [BCDGameChoice]) -> [ChoiceRun] {
        var runs: [ChoiceRun] = []
        var current: [BCDGameChoice] = []
        var heading: String?
        for choice in list {
            if choice.group != nil, !current.isEmpty {
                runs.append(ChoiceRun(heading: heading, choices: current))
                current = []
            }
            if current.isEmpty { heading = choice.group }
            current.append(choice)
        }
        if !current.isEmpty { runs.append(ChoiceRun(heading: heading, choices: current)) }
        return runs
    }

    /// The game's own config file (key = value lines), as BCD's Edit config page.
    @ViewBuilder private var configPage: some View {
        NexMenuNote(text: "One setting per line: key = value. Lines starting with # are notes. Applies at the next start.")
        NexMenuSection {
            NexMenuCustomRow {
                TextEditor(text: $configDraft)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            NexMenuRow(title: "Save Config", symbol: "checkmark") {
                guard let target else { return }
                NexBCDGamePage.backend?.saveConfig(configDraft, for: target)
                status = "Config saved."
                reload()
                if !path.isEmpty { path.removeLast() }
            }
        }
    }
}
