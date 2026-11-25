import SwiftUI
import UniformTypeIdentifiers

/// 8.4.0: what the game page opens over itself (BCD's Options panel: from the right on a phone on its side and an iPad,
/// from the bottom on an upright phone).
enum GamePagePanel: String, Identifiable {
    case options, pcSetup, saves, media, mods

    var id: String { rawValue }

    var title: String {
        switch self {
        case .options: return "Options"
        case .pcSetup: return "PC Setup"
        case .saves: return "Saves"
        case .media: return "Media"
        case .mods: return "Mods"
        }
    }

    var symbol: String {
        switch self {
        case .options: return "slider.horizontal.3"
        case .pcSetup: return "cpu"
        case .saves: return "square.and.arrow.down.on.square.fill"
        case .media: return "photo.on.rectangle.angled"
        case .mods: return "puzzlepiece.extension.fill"
        }
    }
}

/// A line under the game's actions (BCD's notes): a warning or a hint, with buttons that fix it.
private struct GamePageNote: Identifiable {
    let id: String
    let text: String
    var warning = false
    var fixes: [GamePageFix] = []
}

private struct GamePageFix: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let run: () -> Void
}

/// A label and its value in the facts card.
private struct GamePageFact: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// The game page. 8.4.0: BCD's structure and layout (BCDGamePage: the art across the screen, the name and actions low on
/// the left, the facts card on the right; on an upright phone the art on top and one column below; Options in a panel),
/// NexPlay's content: engine-aware sections chosen by `RuntimeCapabilities`, save profiles, Media, Mods, How It Runs and
/// the crash card. NexPlay's own code on the 8.1 design system; layout ideas from BCD (GPL-3.0).
@MainActor
struct GameDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    let gameID: UUID
    /// Called with the game when the user taps Play.
    let onPlay: (Game) -> Void

    @State private var hero: UIImage?
    @State private var profiles: [ProfileSummary] = []
    @State private var appeared = false
    @State private var busy = false
    @State private var message: String?
    @State private var newProfileName = ""
    @State private var askingNewProfile = false
    @State private var profileInfo: ProfileSummary?
    @State private var renameText = ""
    @State private var renaming: ProfileSummary?
    @State private var folderSize: Int64?
    @State private var runtimeLabel: String?
    @State private var notice: String?
    @State private var showSetupCenter = false
    @State private var panel: GamePagePanel?
    /// 8.7.8: how far the panel is being dragged down (closes past 120 pt).
    @State private var panelDrag: CGFloat = 0
    /// 7.10.0: NexPlay closed while starting this game on this runtime last time.
    @State private var crashedOn: RuntimeKind?
    /// 8.4.0: PC games: the program the game starts, and the installers that came with it.
    @State private var program: String?
    @State private var installers: [String] = []
    @State private var askInstaller = false
    @State private var askClose = false
    /// 8.20.0: a Windows game with Japanese file names, whose Japanese locale is off (the hint offers to turn it on).
    @State private var japaneseHint = false
    /// 8.7.1: a controller on the game page (NexMenuNavigation.swift): the ring over Play, the chips and the cards' rows;
    /// A presses, B closes the panel then the page, L1/R1 switch the panel's pages, Menu closes the page.
    @StateObject private var navigator = NexMenuNavigator()

    private var game: Game? { store.game(id: gameID) }

    var body: some View {
        GeometryReader { proxy in
            let m = GamePageMetrics(size: proxy.size, insets: proxy.safeAreaInsets,
                                    pad: horizontal == .regular && vertical == .regular)
            ZStack {
                NexColor.dark(.ground).ignoresSafeArea()
                if let game {
                    backdrop(game, m)
                    Group {
                        if m.upright { upright(game, m) } else { landscape(game, m) }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    topBar(game, m)
                } else {
                    gone
                }
                // 8.10.4: Options, Saves, Media and Mods fill the whole screen (no half-open panel, no dim layer).
                if let panel, let game {
                    panelView(game, panel, m)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .font(NexType.body)
        .fontDesign(.rounded)
        .foregroundStyle(NexColor.dark(.text))
        .environment(\.colorScheme, .dark)
        .task { await refresh() }
        .environment(\.nexMenuNavigator, navigator)
        .onPreferenceChange(NexMenuOrderKey.self) { ids in navigator.order = ids }
        .onAppear {
            withAnimation(NexMotion.pick(NexMotion.hero)) { appeared = true }
            navigator.autoFocusFirst = true
            navigator.onBack = {
                if panel != nil { closePanel() } else { dismiss() }
            }
            navigator.onClose = { dismiss() }
            navigator.onTab = { delta in
                guard let current = panel, let game else { return }
                let pages = panelPages(game)
                guard let index = pages.firstIndex(of: current) else { return }
                NexHaptics.selection()
                panel = pages[(index + delta + pages.count) % pages.count]
            }
            navigator.capture()
        }
        .onDisappear { navigator.release() }
        .onChange(of: panel) { _ in navigator.reset() }
        .alert("New Profile", isPresented: $askingNewProfile) {
            TextField("Name", text: $newProfileName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createProfile() }
        } message: {
            Text("A new profile starts with no saves. The current saves stay in their profile, and you can switch back any time.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameProfile() }
        }
        .confirmationDialog(profileInfo?.profile.name ?? "", isPresented: Binding(
            get: { profileInfo != nil }, set: { if !$0 { profileInfo = nil } }
        ), titleVisibility: .visible) {
            if let info = profileInfo {
                Button("Rename") {
                    renameText = info.profile.name
                    // 8.19.0: after the dialog has closed; an alert asked for while it closes is dropped.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { renaming = info }
                }
                if !info.isActive {
                    Button("Delete Profile", role: .destructive) { deleteProfile(info) }
                }
            }
        } message: {
            if let info = profileInfo {
                Text("\(info.count) save file(s)" + (info.newest.map { " · last saved " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
            }
        }
        .confirmationDialog("Run an Installer", isPresented: $askInstaller, titleVisibility: .visible) {
            ForEach(installers, id: \.self) { path in
                Button((path as NSString).lastPathComponent) { runInstaller(path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The installer starts in place of the game, once. Windows starts one program per launch: when it is done, restart NexPlay and tap Play.")
        }
        .confirmationDialog("Close NexPlay?", isPresented: $askClose, titleVisibility: .visible) {
            Button("Close NexPlay", role: .destructive) { closeNexPlay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Windows runs once per launch. NexPlay closes now; open it again and tap Play.")
        }
        .sheet(isPresented: $showSetupCenter) {
            NavigationStack {
                SetupCenterView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { showSetupCenter = false } }
                    }
            }
        }
        .alert("Profiles", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    // MARK: - Art

    private var ground: Color { NexColor.dark(.ground) }

    /// The hero art filling its frame, or the engine's placeholder.
    private func art(_ game: Game) -> some View {
        Color.clear
            .overlay {
                if let hero {
                    Image(uiImage: hero)
                        .resizable()
                        .interpolation(hero.size.width < 400 ? .none : .high)
                        .scaledToFill()
                } else {
                    NexPlaceholderCover(title: "", engine: game.engine, compact: true)
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private func backdrop(_ game: Game, _ m: GamePageMetrics) -> some View {
        if m.upright {
            VStack(spacing: 0) {
                art(game)
                    .frame(height: m.artHeight)
                    .overlay {
                        // 8.7.9: darker at the top, so the default cover's engine symbol doesn't sit behind Back.
                        LinearGradient(stops: [.init(color: ground.opacity(0.7), location: 0),
                                               .init(color: ground.opacity(0.45), location: 0.5),
                                               .init(color: ground, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                ground
            }
            .ignoresSafeArea()
        } else {
            art(game)
                .overlay {
                    LinearGradient(stops: [.init(color: ground.opacity(0.94), location: 0),
                                           .init(color: ground.opacity(0.78), location: 0.4),
                                           .init(color: ground.opacity(0.3), location: 0.78),
                                           .init(color: ground.opacity(0.22), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .overlay {
                    LinearGradient(colors: [.clear, ground.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                .ignoresSafeArea()
        }
    }

    // MARK: - Layouts

    /// A phone on its side and an iPad: the name and actions on the left, the facts on the right.
    private func landscape(_ game: Game, _ m: GamePageMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: m.columnGap) {
                mainColumn(game, m)
                    .frame(maxWidth: m.mainColumn, alignment: .leading)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 16) {
                    factsCard(game)
                    howItRunsCard(game)
                }
                .frame(width: m.factsWidth)
            }
            .padding(.horizontal, m.gutter)
            .padding(.top, m.pad ? 84 : 58)
            .padding(.bottom, 20)
            .frame(minHeight: m.size.height, alignment: .bottom)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// An upright phone or iPad: the art on top, everything below it in one column (an iPad keeps the facts beside it).
    private func upright(_ game: Game, _ m: GamePageMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Color.clear.frame(height: m.uprightLead)
                if m.pad {
                    HStack(alignment: .top, spacing: m.columnGap) {
                        mainColumn(game, m).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 16) {
                            factsCard(game)
                            howItRunsCard(game)
                        }
                        .frame(width: m.factsWidth)
                    }
                } else {
                    mainColumn(game, m)
                    factsCard(game)
                    howItRunsCard(game)
                }
            }
            .padding(.horizontal, m.gutter)
            .padding(.bottom, 24)
        }
    }

    private var gone: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.square.dashed").font(.system(size: 40, weight: .semibold))
                .foregroundStyle(NexColor.dark(.textSoft))
            Text("This game isn't in your library any more").font(NexType.heading).multilineTextAlignment(.center)
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(NexGlassButtonStyle(fullWidth: false))
        }
        .padding(24)
    }

    private func topBar(_ game: Game, _ m: GamePageMetrics) -> some View {
        VStack {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(NexType.label)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .nexGlassCapsule(interactive: true)
                        .frame(minWidth: 64, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
                Button {
                    store.toggleFavorite(game)
                    NexHaptics.tap()
                } label: {
                    Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(game.isFavorite ? Color.pink : NexColor.dark(.text))
                }
                .buttonStyle(NexGlassIconButtonStyle(size: 40))
                .accessibilityLabel(game.isFavorite ? "Unfavorite" : "Favorite")
            }
            .padding(.horizontal, m.gutter)
            .padding(.top, m.pad ? 18 : 8)
            Spacer()
        }
    }

    // MARK: - The game, its actions and the lines under them

    private func mainColumn(_ game: Game, _ m: GamePageMetrics) -> some View {
        let caps = GameRuntimes.capabilities(for: game)
        return VStack(alignment: .leading, spacing: m.pad ? 16 : 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(NexType.display(m.titleSize))
                    .foregroundStyle(NexColor.dark(.text))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.45), radius: 6)
                badges(game)
            }
            actionRows(game, caps, m)
            if let setup = GameReadiness.setupReason(for: game) {
                Text(setup).font(NexType.caption).foregroundStyle(NexColor.dark(.textSoft))
            }
            notesView(notes(game, caps), m)
            if caps.fileSaves && game.usesNWMode { profileRow(game) }
        }
    }

    /// Engine, status and the owner's verdict, one line of small capsules.
    private func badges(_ game: Game) -> some View {
        NexChipFlow(spacing: 6) {
            Label(game.engine.title, systemImage: GameRuntimes.kind(for: game).symbol)
                .font(NexType.captionStrong)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(game.engine.accent.opacity(0.35), in: Capsule())
                .overlay(Capsule().strokeBorder(game.engine.accent.opacity(0.7), lineWidth: 1))
            if game.status != nil {
                Label(game.playStatus.title, systemImage: game.playStatus.symbol)
                    .font(NexType.captionStrong)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(game.playStatus.color.opacity(0.3), in: Capsule())
            }
            if let developer = game.developer, !developer.isEmpty {
                Text(developer)
                    .font(NexType.captionStrong)
                    .foregroundStyle(NexColor.dark(.textSoft))
                    .padding(.vertical, 5)
            }
        }
    }

    private struct Other: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let run: () -> Void
    }

    /// The buttons beside Play: Options, then the sections this game has.
    private func otherButtons(_ game: Game, _ caps: RuntimeCapabilities) -> [Other] {
        var list: [Other] = [Other(id: "options", title: "Options", symbol: GamePagePanel.options.symbol) { openPanel(.options) }]
        if caps.pcSetup && WindowsEngine.isBuiltIn {
            list.append(Other(id: "pc", title: "PC Setup", symbol: GamePagePanel.pcSetup.symbol) { openPanel(.pcSetup) })
        }
        if caps.fileSaves { list.append(Other(id: "saves", title: "Saves", symbol: GamePagePanel.saves.symbol) { openPanel(.saves) }) }
        list.append(Other(id: "media", title: "Media", symbol: GamePagePanel.media.symbol) { openPanel(.media) })
        if caps.mods { list.append(Other(id: "mods", title: "Mods", symbol: GamePagePanel.mods.symbol) { openPanel(.mods) }) }
        if caps.pcSetup && !installers.isEmpty && !WindowsEngine.ranThisLaunch {
            list.append(Other(id: "installer", title: "Run Installer", symbol: "shippingbox.fill") { askInstaller = true })
        }
        if GameReadiness.setupReason(for: game) != nil {
            list.append(Other(id: "anyway", title: "Play Anyway", symbol: "play") { play(game) })
        }
        return list
    }

    @ViewBuilder private func actionRows(_ game: Game, _ caps: RuntimeCapabilities, _ m: GamePageMetrics) -> some View {
        let others = otherButtons(game, caps)
        if m.upright && !m.pad {
            VStack(alignment: .leading, spacing: 10) {
                mainButton(game)
                chips(others)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    mainButton(game).frame(width: m.mainWidth)
                    ForEach(others) { item in chip(item) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    mainButton(game).frame(width: m.mainWidth)
                    chips(others)
                }
            }
        }
    }

    private func chips(_ list: [Other]) -> some View {
        NexChipFlow(spacing: 10) {
            ForEach(list) { item in chip(item) }
        }
    }

    private func chip(_ item: Other) -> some View {
        Button {
            NexHaptics.tap()
            item.run()
        } label: {
            Label(item.title, systemImage: item.symbol).lineLimit(1)
        }
        .buttonStyle(NexGlassButtonStyle(fullWidth: false))
        .nexMenuFocusable("page.chip.\(item.title)") { item.run() }
    }

    /// Play, or Set Up when the game needs setup first, or Restart and Play after an installer.
    @ViewBuilder private func mainButton(_ game: Game) -> some View {
        if GameReadiness.setupReason(for: game) != nil {
            Button {
                NexHaptics.press()
                showSetupCenter = true
            } label: {
                Label("Set Up", systemImage: "wrench.and.screwdriver.fill")
            }
            .buttonStyle(NexPrimaryButtonStyle())
            .nexMenuFocusable("page.main.setup") { showSetupCenter = true }
        } else if installerRan(game) {
            Button {
                NexHaptics.press()
                askClose = true
            } label: {
                Label("Restart and Play", systemImage: "arrow.clockwise")
            }
            .buttonStyle(NexPrimaryButtonStyle())
            .nexMenuFocusable("page.main.restart") { askClose = true }
        } else {
            let title = WindowsEngine.playTitle(for: game)
            Button {
                play(game)
            } label: {
                Label(title, systemImage: title == "Play" ? "play.fill" : "arrow.clockwise")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(NexPrimaryButtonStyle())
            .nexMenuFocusable("page.main.play") { play(game) }
        }
    }

    private func installerRan(_ game: Game) -> Bool {
        WindowsInstallers.ranFor == game.id && WindowsEngine.ranThisLaunch
    }

    /// The lines under the actions: runtime notices, the crash card, the installer and restart hints.
    private func notes(_ game: Game, _ caps: RuntimeCapabilities) -> [GamePageNote] {
        var list: [GamePageNote] = []
        if let notice { list.append(GamePageNote(id: "notice", text: notice, warning: true)) }
        if let crashedOn {
            var fixes: [GamePageFix] = GameRuntimes.choices(for: game).filter { $0 != crashedOn }.map { other in
                GamePageFix(id: "use." + other.rawValue, title: "Use \(other.title)", symbol: other.symbol) {
                    store.mutate(game.id) { $0.runtime = other }
                    LaunchGuard.clearCrash(for: game.id)
                    self.crashedOn = nil
                }
            }
            fixes.append(GamePageFix(id: "dismiss", title: "Dismiss", symbol: "xmark") {
                LaunchGuard.clearCrash(for: game.id)
                self.crashedOn = nil
            })
            list.append(GamePageNote(id: "crash", text: "NexPlay closed while starting this game on \(crashedOn.title) last time. Try another runtime, or play again if it was a one-off.",
                                     warning: true, fixes: fixes))
        }
        if caps.pcSetup && japaneseHint {
            list.append(GamePageNote(id: "japanese", text: "This looks like a Japanese game. If its text shows as boxes or garbled characters, or it doesn't start, run it with a Japanese system locale (Shift-JIS and a Japanese font).",
                                     fixes: [
                                        GamePageFix(id: "japanese.on", title: "Use Japanese Locale", symbol: "character.ja") { setJapanese(game) },
                                        GamePageFix(id: "japanese.no", title: "Not Needed", symbol: "xmark") {
                                            UserDefaults.standard.set(true, forKey: "japaneseHintDismissed.\(game.id.uuidString)")
                                            japaneseHint = false
                                        },
                                     ]))
        }
        if caps.pcSetup {
            if installerRan(game) {
                list.append(GamePageNote(id: "restart", text: "The installer ran. Windows starts once per launch, so installing and playing are two launches: close NexPlay, open it again and tap Play.",
                                         warning: true, fixes: [
                                            GamePageFix(id: "close", title: "Close NexPlay", symbol: "power") { askClose = true }
                                         ]))
            } else if WindowsEngine.ranThisLaunch {
                list.append(GamePageNote(id: "restart", text: "A Windows game already ran this launch. Windows starts once per launch: restart NexPlay to play this one."))
            } else if !installers.isEmpty {
                let first = (installers[0] as NSString).lastPathComponent
                let more = installers.count > 1 ? " and \(installers.count - 1) more" : ""
                list.append(GamePageNote(id: "installers", text: "This game comes with installers (\(first)\(more)). Most games run without them. If one is needed, installing and playing are two launches: run it, then restart NexPlay and play.",
                                         fixes: [
                                            GamePageFix(id: "install", title: "Run Installer", symbol: "shippingbox.fill") { askInstaller = true }
                                         ]))
            }
        }
        return list
    }

    private func notesView(_ notes: [GamePageNote], _ m: GamePageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: note.warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(note.warning ? NexColor.dark(.warning) : NexColor.dark(.accentSoft))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.text)
                            .font(NexType.body)
                            .foregroundStyle(NexColor.dark(.text).opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                        if !note.fixes.isEmpty {
                            NexChipFlow(spacing: 8) {
                                ForEach(note.fixes) { fix in
                                    Button {
                                        NexHaptics.tap()
                                        fix.run()
                                    } label: {
                                        Label(fix.title, systemImage: fix.symbol).font(NexType.captionStrong)
                                    }
                                    .buttonStyle(NexGlassButtonStyle(fullWidth: false))
                                    .nexMenuFocusable("page.fix.\(fix.id)") { fix.run() }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: m.upright ? .infinity : 460, alignment: .leading)
    }

    // MARK: - Cards

    private func facts(_ game: Game) -> [GamePageFact] {
        let caps = GameRuntimes.capabilities(for: game)
        var list = [GamePageFact(label: "Engine", value: game.engine.title)]
        let kind = GameRuntimes.kind(for: game)
        list.append(GamePageFact(label: "Runs On", value: runtimeLabel.map { "\(kind.title) · \($0)" } ?? kind.title))
        list.append(GamePageFact(label: "Played", value: game.playSeconds > 0 ? formatHours(game.playSeconds) : "Not yet"))
        if game.playCount > 0 {
            list.append(GamePageFact(label: "Sessions", value: "\(game.playCount)"))
        }
        if let last = game.lastPlayed {
            list.append(GamePageFact(label: "Last Played", value: last.formatted(.relative(presentation: .named))))
        }
        list.append(GamePageFact(label: "Added", value: game.addedAt.formatted(date: .abbreviated, time: .omitted)))
        if let folderSize {
            list.append(GamePageFact(label: "Size", value: ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file)))
        }
        if let version = game.version, !version.isEmpty { list.append(GamePageFact(label: "Version", value: version)) }
        if caps.pcSetup {
            if let program { list.append(GamePageFact(label: "Program", value: (program as NSString).lastPathComponent)) }
            if let info = game.windowsInfo { list.append(GamePageFact(label: "Outlook", value: info.summary)) }
        }
        return list
    }

    private func factsCard(_ game: Game) -> some View {
        NexMenuSection("Details") {
            ForEach(facts(game)) { fact in
                NexMenuCustomRow {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(fact.label).font(NexType.caption).foregroundStyle(NexColor.dark(.textSoft))
                        Spacer(minLength: 8)
                        Text(fact.value).font(NexType.captionStrong).multilineTextAlignment(.trailing).lineLimit(2)
                    }
                }
            }
            if let notes = game.notes, !notes.isEmpty {
                NexMenuNote(text: notes, symbol: "note.text", tint: NexColor.dark(.text))
            }
            NexMenuRow(title: "Edit Details", symbol: "pencil", accessory: .chevron) { openPanel(.options) }
        }
    }

    private func howItRunsCard(_ game: Game) -> some View {
        let kind = GameRuntimes.kind(for: game)
        let current = game.compatibility ?? .untested
        return NexMenuSection("How It Runs") {
            NexMenuNote(text: kind.howItRuns, symbol: kind.symbol, tint: NexColor.dark(.text))
            NexMenuNote(text: game.runtime == nil ? "Runtime: Automatic (\(kind.title))" : "Runtime: \(kind.title), chosen in Options")
            NexMenuCustomRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach([CompatStatus.works, .playable, .broken]) { status in
                            Button {
                                store.mutate(game.id) { $0.compatibility = current == status ? nil : status }
                                NexHaptics.selection()
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(status.color).frame(width: 8, height: 8)
                                    Text(status.title).font(NexType.captionStrong).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(current == status ? status.color.opacity(0.45) : Color.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(current == status ? status.color : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Your verdict. It shows on the game's card.")
                        .font(NexType.caption).foregroundStyle(NexColor.dark(.textSoft))
                }
            }
        }
    }

    private func profileRow(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            NexMenuEyebrow(text: "Save Profiles").padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(profiles) { info in
                        ProfileCard(info: info) {
                            switchTo(info)
                        } onInfo: {
                            profileInfo = info
                        }
                    }
                    Button {
                        newProfileName = "Profile \(profiles.count + 1)"
                        askingNewProfile = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 30, weight: .black)).foregroundStyle(NexColor.dark(.accent))
                            Text("New Profile").font(NexType.label)
                        }
                        .frame(width: 150, height: 120)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .disabled(busy)
            .overlay { if busy { ProgressView().tint(.white) } }
        }
    }

    // MARK: - Panel

    /// 8.10.4: a full-screen page: the game's art blurred across the top, the page's title and a close button, the
    /// other pages as a tab row, then the page. (Before: a half-open panel with a drag handle and a dim layer.)
    @ViewBuilder private func panelView(_ game: Game, _ page: GamePagePanel, _ m: GamePageMetrics) -> some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            art(game)
                .opacity(0.5)
                .frame(height: 300)
                .overlay {
                    LinearGradient(stops: [.init(color: ground.opacity(0.55), location: 0),
                                           .init(color: ground.opacity(0.92), location: 0.7),
                                           .init(color: ground, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .blur(radius: 22)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                panelHeader(game, page)
                panelContent(game, page)
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panel's title, the other pages of this game as chips, and close.
    /// The panel's pages for this game (also L1/R1's order).
    private func panelPages(_ game: Game) -> [GamePagePanel] {
        let caps = GameRuntimes.capabilities(for: game)
        var pages: [GamePagePanel] = [.options]
        if caps.pcSetup && WindowsEngine.isBuiltIn { pages.append(.pcSetup) }
        if caps.fileSaves { pages.append(.saves) }
        pages.append(.media)
        if caps.mods { pages.append(.mods) }
        return pages
    }

    private func panelHeader(_ game: Game, _ page: GamePagePanel) -> some View {
        let pages = panelPages(game)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(NexType.display(26))
                        .foregroundStyle(NexColor.dark(.text))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(page.title)
                        .font(NexType.caption)
                        .foregroundStyle(NexColor.dark(.textSoft))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { closePanel() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NexGlassIconButtonStyle(size: 44))
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pages) { item in
                        Button {
                            guard panel != item else { return }
                            NexHaptics.selection()
                            panel = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(NexType.captionStrong)
                                .foregroundStyle(item == page ? NexColor.dark(.onAccent) : NexColor.dark(.text))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background {
                                    if item == page {
                                        Capsule().fill(NexColor.accentGradient)
                                    } else {
                                        Capsule().fill(Color.white.opacity(0.08))
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func panelContent(_ game: Game, _ page: GamePagePanel) -> some View {
        switch page {
        case .options:
            GameSettingsView(gameID: game.id, onDeleted: {
                panel = nil
                dismiss()
            }, embedded: true)
        case .pcSetup:
            // 8.4.1: BCD's PC sections (graphics, prefix tools, components, AutoTune, recommended settings, save backups).
            #if NEXPLAY_WINDOWS
            NexBCDPCSetupView(game: game)
            #else
            Text("This build has no Windows engine.")
                .font(NexType.body)
                .foregroundStyle(NexColor.dark(.textSoft))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        case .saves:
            GameSavesView(gameID: game.id, embedded: true)
        case .media:
            MediaBrowserView(game: game, embedded: true)
        case .mods:
            ModsView(game: game, embedded: true)
        }
    }

    private func openPanel(_ page: GamePagePanel) {
        withAnimation(NexMotion.pick(NexMotion.smooth)) { panel = page }
    }

    private func closePanel() {
        withAnimation(NexMotion.pick(NexMotion.snappy)) { panel = nil }
        Task { await refresh() }
    }

    // MARK: - Play, installers

    private func play(_ game: Game) {
        NexHaptics.press()
        onPlay(game)
    }

    private func runInstaller(_ path: String) {
        guard let game else { return }
        WindowsInstallers.runNext(path, for: game.id)
        AppLog.log("windows: \(game.name): installer chosen \(path)")
        play(game)
    }

    private func setJapanese(_ game: Game) {
        #if NEXPLAY_WINDOWS
        if NexBCDJapanese.set(true, for: game) {
            japaneseHint = false
            message = "The Japanese locale is on for \(game.name) from its next start. Turn it off under PC Setup › Compatibility."
        } else {
            message = "Start any Windows game once (it sets up drive C:), then try again."
        }
        #endif
    }

    /// Shows the Japanese locale hint for a Windows game with Japanese file names whose locale is off.
    private func checkJapanese(_ game: Game) async {
        #if NEXPLAY_WINDOWS
        guard GameRuntimes.kind(for: game) == .windows, NexBCDJapanese.available,
              !UserDefaults.standard.bool(forKey: "japaneseHintDismissed.\(game.id.uuidString)"),
              !NexBCDJapanese.isOn(for: game) else {
            japaneseHint = false
            return
        }
        let folder = Paths.folder(for: game)
        japaneseHint = await Task.detached(priority: .utility) { JapaneseText.looksJapanese(folder: folder) }.value
        #endif
    }

    private func closeNexPlay() {
        AppLog.log("windows: closing NexPlay from the game page (restart and play)")
        WindowsPendingPlay.note(gameID)
        _ = AppLog.shared.text
        exit(0)
    }

    // MARK: - Loading

    private func refresh() async {
        guard let game else { return }
        let target = game
        crashedOn = LaunchGuard.crashedRuntime(for: target.id)
        await checkJapanese(target)
        hero = await Task.detached(priority: .userInitiated) { GameArt.hero(for: target) }.value
        switch target.engine {
        case .rpgXP, .rpgVX, .rpgVXAce:
            notice = RubyCore.runner.isAvailable ? nil : RubyCore.runner.unavailableReason
        case .renpy:
            notice = RenPyRuntime.bundled.isEmpty ? RenPyRuntime.RenPyError.noRuntime.errorDescription : nil
        case .flash:
            notice = FlashRuntime.folder == nil ? FlashRuntime.FlashError.missing.errorDescription : nil
        case .rpg2k:
            let fine = EasyRPGCore.isPresent || target.runtime == .windows
            notice = fine ? nil : "This build has no EasyRPG core. Pick Windows in Options > Runs On, or install a newer build."
        case .windows:
            notice = WindowsEngine.unavailableReason ?? target.windowsInfo.flatMap {
                $0.outlook == .likely ? nil : "Windows runtime outlook: \($0.summary)."
            }
        default:
            notice = nil
        }
        if target.engine.hasRuntimeChoice {
            let engine = EngineRuntimes.engineName(target.engine)
            let auto = await Task.detached(priority: .utility) { EngineRuntimes.automatic(for: target) }.value
            if let chosen = target.runtimeVersion {
                runtimeLabel = "\(engine) \(chosen)"
            } else if let runtime = auto.runtime {
                runtimeLabel = "\(engine) \(runtime)"
            } else {
                runtimeLabel = nil
            }
        }
        if GameRuntimes.capabilities(for: target).pcSetup {
            let found = await Task.detached(priority: .utility) { () -> (String?, [String]) in
                let root = Paths.folder(for: target)
                return (WindowsGameFiles.program(for: target), WindowsInstallers.list(in: root))
            }.value
            program = found.0
            installers = found.1
        } else {
            program = nil
            installers = []
        }
        folderSize = await Task.detached(priority: .utility) { GameScanner.size(of: Paths.folder(for: target)) }.value
        if target.usesNWMode {
            profiles = await Task.detached { SaveProfiles.summaries(target) }.value
        }
    }

    private func switchTo(_ info: ProfileSummary) {
        guard let game, !info.isActive, !busy else { return }
        let current = SaveProfiles.active(game).id
        let list = SaveProfiles.list(game)
        busy = true
        Task {
            do {
                try await Task.detached { try SaveProfiles.switchFiles(game, from: current, to: info.profile.id) }.value
                store.mutate(game.id) { g in
                    g.profiles = list
                    g.activeProfile = info.profile.id
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                message = "Couldn't switch profiles: \(error.localizedDescription). Your saves were backed up first."
            }
            busy = false
            await refresh()
        }
    }

    private func createProfile() {
        guard let game else { return }
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        let profile = SaveProfile(name: name.isEmpty ? "Profile \(profiles.count + 1)" : String(name.prefix(24)))
        let current = SaveProfiles.active(game).id
        var list = SaveProfiles.list(game)
        list.append(profile)
        busy = true
        Task {
            do {
                try await Task.detached { try SaveProfiles.switchFiles(game, from: current, to: profile.id) }.value
                store.mutate(game.id) { g in
                    g.profiles = list
                    g.activeProfile = profile.id
                }
            } catch {
                message = "Couldn't create the profile: \(error.localizedDescription)"
            }
            busy = false
            await refresh()
        }
    }

    private func renameProfile() {
        guard let game, let info = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = SaveProfiles.list(game)
        if let index = list.firstIndex(where: { $0.id == info.profile.id }) { list[index].name = String(name.prefix(24)) }
        let activeID = SaveProfiles.active(game).id
        store.mutate(game.id) { g in
            g.profiles = list
            g.activeProfile = activeID
        }
        renaming = nil
        Task { await refresh() }
    }

    private func deleteProfile(_ info: ProfileSummary) {
        guard let game, !info.isActive else { return }
        let list = SaveProfiles.list(game).filter { $0.id != info.profile.id }
        let activeID = SaveProfiles.active(game).id
        Task {
            await Task.detached { SaveProfiles.discardParked(game, info.profile.id, name: info.profile.name) }.value
            store.mutate(game.id) { g in
                g.profiles = list
                g.activeProfile = activeID
            }
            message = "\(info.profile.name) was removed. Its save files were moved to Rescued Saves."
            await refresh()
        }
    }
}

/// Sizes for each layout (BCD's BCDGamePageMetrics): a phone on its side, an upright phone, an iPad either way.
private struct GamePageMetrics {
    let size: CGSize
    let insets: EdgeInsets
    let pad: Bool

    var upright: Bool { size.height > size.width }
    var gutter: CGFloat { pad ? 36 : 20 }
    var columnGap: CGFloat { pad ? 36 : 22 }
    var factsWidth: CGFloat { pad ? 330 : (size.width < 760 ? 240 : 270) }
    var mainColumn: CGFloat { max(260, size.width - 2 * gutter - factsWidth - columnGap) }
    var titleSize: CGFloat { pad ? 44 : 30 }
    var mainWidth: CGFloat { pad ? 240 : 190 }
    var panelWidth: CGFloat { pad ? 460 : min(440, max(340, size.width * 0.55)) }
    /// An upright screen: how tall the art is, and how far down the name starts on it.
    var artHeight: CGFloat { max(250, (size.height + insets.top + insets.bottom) * (pad ? 0.5 : 0.44)) }
    var uprightLead: CGFloat { max(40, artHeight - insets.top - (pad ? 210 : 150)) }
}

/// A save profile card: check mark when active, name, save count, date and an info button.
struct ProfileCard: View {
    let info: ProfileSummary
    let onTap: () -> Void
    let onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: info.isActive ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(info.isActive ? NexStyle.accent : .white.opacity(0.6))
                Text(info.profile.name).font(NexType.heading).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onInfo) {
                    Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.55)).padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile options")
            }
            Text(info.count == 1 ? "1 save" : "\(info.count) saves").font(NexType.caption).foregroundStyle(.white.opacity(0.6))
            Text(info.newest.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "No saves yet")
                .font(NexType.caption).foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .frame(width: 210, height: 120, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(info.isActive ? NexStyle.accent : Color.white.opacity(0.12), lineWidth: info.isActive ? 3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
    }
}

/// A wide glass tile with an icon and a short title (bottom of the game page).
struct BottomTile: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(NexStyle.accent)
                Text(title).font(NexType.label).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 8)
            .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A round glass button (close, settings).
struct GlassCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14)))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet for SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
