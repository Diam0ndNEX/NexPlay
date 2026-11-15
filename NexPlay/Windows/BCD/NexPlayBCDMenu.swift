// NexPlay's code (not BCD's), compiled only with the Windows engine (NexPlay 8.3.1).
// BCD's in-game menu drawn in NexPlay's in-game menu: BCD's session layer no longer draws BCDInGameMenu
// (NexBCDMenu.replacesBCDMenu); NexPlay's Windows panel shows the rows of BCD's live source (BCDLibraryMenuSource)
// with NexPlay's own sections. BCD by thebcd69: https://github.com/thebcd69/bcd-games (GPL-3.0-only with BCD's
// additional terms). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

import SwiftUI

enum NexBCDMenu {
    /// BCD's session layer skips its own menu (BCDSession.swift's hook): NexPlay's Windows panel draws it.
    static let replacesBCDMenu = true

    /// Added to BCD's "Quit game" question: Wine runs once per launch.
    static let restartLine = "NexPlay runs one Windows game per launch: to play another Windows game afterwards, close NexPlay and open it again."
}

/// The menu's source and model while NexPlay's Windows panel is open, as BCD's session opens them.
@MainActor final class NexBCDMenuBridge {
    let source = BCDLibraryMenuSource()
    let model: BCDSessionMenuModel

    init() {
        model = BCDSessionMenuModel(source: source)
        model.custom["touch"] = { AnyView(BCDTouchMenuSectionLive(closeMenu: { LibraryModel.shared.menu = false })) }
        model.custom[BCDInputMenu.lookCustom] = { AnyView(BCDTouchLookSampleLive()) }
        source.menu = model
    }

    func dispose() {
        source.dispose()
    }

    /// What WindowsPanelView needs (it is compiled without the engine, so it names no BCD type).
    var part: WindowsPanelView.BCDPart {
        let model = model
        let source = source
        return WindowsPanelView.BCDPart(
            subtitle: { source.subtitle },
            content: { tab, pages, question in
                AnyView(NexBCDMenuContent(model: model, tab: BCDSessionTab(rawValue: tab) ?? .game,
                                          pages: pages, question: question))
            },
            pageTitle: { id in source.page(id)?.title }
        )
    }
}

/// One tab or page of BCD's menu in NexPlay's look.
struct NexBCDMenuContent: View {
    @ObservedObject var model: BCDSessionMenuModel
    let tab: BCDSessionTab
    @Binding var pages: [String]
    @Binding var question: NexMenuQuestion?

    private var source: BCDSessionMenuSource { model.source }
    private var pageID: String? { pages.last.flatMap { source.page($0) == nil ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pageID, let page = source.page(pageID) {
                ForEach(page.sections) { section($0) }
                if page.kind == .log { logLines }
            } else {
                ForEach(source.sections(tab)) { section($0) }
            }
        }
        .onAppear { source.pageShown(pageID) }
        .onChange(of: pages) { _, _ in source.pageShown(pageID) }
        .onDisappear { source.pageShown(nil) }
    }

    // MARK: Sections

    @ViewBuilder private func section(_ section: BCDMenuSection) -> some View {
        let loose = section.rows.filter(isPrimary)
        let card = section.rows.filter { !isPrimary($0) }
        ForEach(loose) { row in
            Button {
                activate(row)
            } label: {
                Label(row.title, systemImage: row.symbol ?? "play.fill")
            }
            .buttonStyle(NexPrimaryButtonStyle())
            .disabled(!row.enabled)
        }
        if !card.isEmpty {
            NexMenuSection(section.title) {
                ForEach(card) { row in self.row(row) }
            }
        }
    }

    private func isPrimary(_ row: BCDMenuRow) -> Bool {
        if case .action(let primary, _) = row.kind { return primary }
        return false
    }

    // MARK: Rows

    @ViewBuilder private func row(_ row: BCDMenuRow) -> some View {
        switch row.kind {
        case .action(_, let destructive):
            NexMenuRow(title: row.title, detail: row.detail, symbol: row.symbol,
                       accessory: row.confirm != nil && !destructive ? .chevron : .none,
                       destructive: destructive, enabled: row.enabled) { activate(row) }
        case .toggle(let on):
            NexMenuToggleRow(title: row.title, detail: row.detail, symbol: row.symbol, isOn: on, enabled: row.enabled) { value in
                run { source.toggle(row.id, value) }
            }
        case .choice(let choices, let selected):
            NexMenuChipsRow(title: row.title, detail: row.detail, symbol: row.symbol,
                            choices: choices.map { NexMenuChoice(value: $0.id, title: $0.title) },
                            selected: selected, enabled: row.enabled) { value in run { source.choose(row.id, value) } }
        case .multi(let choices, let selected):
            NexMenuChipsRow(title: row.title, detail: row.detail, symbol: row.symbol,
                            choices: choices.map { NexMenuChoice(value: $0.id, title: $0.title) },
                            isOn: { selected.contains($0) }, enabled: row.enabled) { value in run { source.choose(row.id, value) } }
        case .slider(let value, let range, let step, let text):
            NexMenuSliderRow(title: row.title, symbol: row.symbol, value: value, range: range, step: step, text: text,
                             change: { new in run { source.slide(row.id, new) } })
                .disabled(!row.enabled)
                .opacity(row.enabled ? 1 : 0.45)
        case .page(let page, let value):
            NexMenuRow(title: row.title, detail: row.detail, symbol: row.symbol,
                       accessory: value.map { NexMenuRow.Accessory.value($0) } ?? NexMenuRow.Accessory.chevron, enabled: row.enabled) {
                pages.append(page)
            }
        case .pick(let selected):
            NexMenuRow(title: row.title, detail: row.detail, symbol: row.symbol, accessory: .check(selected),
                       enabled: row.enabled) { activate(row) }
        case .note(let tone):
            NexMenuNote(text: row.title, symbol: row.symbol, tint: color(tone))
        case .custom(let part):
            if let draw = model.custom[part] {
                NexMenuCustomRow { draw() }
            }
        case .share(let files):
            ShareLink(items: files) {
                HStack(spacing: 12) {
                    if let symbol = row.symbol {
                        Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NexColor.accentSoft).frame(width: 22)
                    }
                    Text(row.title).font(NexType.label).foregroundStyle(NexColor.text)
                    Spacer(minLength: 8)
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(NexColor.textSoft)
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(files.isEmpty || !row.enabled)
            .opacity(files.isEmpty || !row.enabled ? 0.45 : 1)
        }
    }

    private var logLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(source.logLines()) { line in
                Text(verbatim: line.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(line.error ? NexColor.danger : NexColor.text.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .id("log.\(model.revision)")
    }

    private func color(_ tone: BCDSessionTone) -> Color {
        switch tone {
        case .normal: return NexColor.text
        case .soft: return NexColor.textSoft
        case .good: return NexColor.success
        case .warm: return NexColor.warning
        case .hot: return NexColor.danger
        }
    }

    // MARK: Doing (as BCDInGameMenu)

    private func run(_ work: () -> Void) {
        work()
        model.changed()
    }

    private func activate(_ row: BCDMenuRow) {
        guard row.enabled else { return }
        if let confirm = row.confirm {
            ask(row, confirm)
            return
        }
        if case .pick = row.kind, let page = pages.last {
            run { source.choose(page, row.id) }
            pages.removeLast()
            return
        }
        run { source.act(row.id) }
    }

    private func ask(_ row: BCDMenuRow, _ confirm: BCDConfirm) {
        var message = confirm.message
        if row.id == "quit" {
            message += (message.isEmpty ? "" : "\n\n") + NexBCDMenu.restartLine
        }
        let isPick: Bool
        if case .pick = row.kind { isPick = true } else { isPick = false }
        question = NexMenuQuestion(title: confirm.title, message: message, answers: confirm.answers.map { answer in
            NexMenuAnswer(title: answer.title, destructive: answer.destructive) {
                run { source.answer(row.id, answer.id) }
                if isPick, !pages.isEmpty { pages.removeLast() }
            }
        })
    }
}

/// 8.3.2: one Performance HUD for every engine. A Windows game shows BCD's own HUD (it reads the engine's frame times,
/// GPU and JIT pool), switched on and off by NexPlay's Show Stats in NexPlay's chosen layout (Pulse/Strip/Tune/Report =
/// BCD's layouts 1-4). Done as BCD's in-game menu does it (BCDHUDMenu.choose, BCDHUDState.change).
@MainActor enum NexBCDHUD {
    static var isShown: Bool { BCDHUDState.shared.setup.layout.shown }

    static func show(_ on: Bool) {
        let state = BCDHUDState.shared
        let value = on ? HUDLayout.current.bcdValue : BCDHUDLayout.off.rawValue
        let next = BCDHUDMenu.choose(BCDHUDMenu.layoutRow, value, state.setup, screen: .landscape).setup
        state.change(next, why: "NexPlay's Show Stats")
    }
}
