import SwiftUI
import UniformTypeIdentifiers

/// Pages the game page opens.
enum GameRoute: String, Identifiable {
    case settings, saves, media, mods
    var id: String { rawValue }
}

/// 7.9.0: the game page's tabs.
enum GamePageTab: String, CaseIterable, Identifiable {
    case overview, saves, settings, media, mods

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .saves: return "Saves"
        case .settings: return "Settings"
        case .media: return "Media"
        case .mods: return "Mods"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "info.circle.fill"
        case .saves: return "square.and.arrow.down.on.square.fill"
        case .settings: return "gearshape.fill"
        case .media: return "photo.on.rectangle.angled"
        case .mods: return "puzzlepiece.extension.fill"
        }
    }
}

/// The game page: cover in a glass frame, title, engine, save profiles, Play, and Manage Saves / Gallery / Mods.
/// Layout follows RPGPlayer's pre-launch screen; NexPlay's own code.
/// 7.5.0: "How it runs" card with the compatibility vote, and a Play button that says when setup is needed.
@MainActor
struct GameDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var collections: CollectionStore
    @EnvironmentObject private var privacy: PrivacyLock
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID
    /// Called with the game when the user taps Play.
    let onPlay: (Game) -> Void

    @State private var hero: UIImage?
    @State private var profiles: [ProfileSummary] = []
    @State private var route: GameRoute?
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
    @State private var pageTab: GamePageTab = .overview
    /// 7.10.0: NexPlay closed while starting this game on this runtime last time.
    @State private var crashedOn: RuntimeKind?

    private var game: Game? { store.game(id: gameID) }

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            if let game {
                VStack(spacing: 0) {
                    tabStrip
                        .padding(.top, 62)
                    switch pageTab {
                    case .overview:
                        ScrollView {
                            VStack(spacing: 18) {
                                coverFrame(game)
                                titleBlock(game)
                                infoChips(game)
                                if let notice { noticeCard(notice) }
                                if let crashedOn { crashCard(game, crashedOn) }
                                howItRunsCard(game)
                                if game.usesNWMode { profileRow(game) }
                                detailsCard(game)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        bottomBar(game)
                    case .saves:
                        GameSavesView(gameID: game.id, embedded: true)
                    case .settings:
                        GameSettingsView(gameID: game.id, onDeleted: { dismiss() }, embedded: true)
                    case .media:
                        MediaBrowserView(game: game, embedded: true)
                    case .mods:
                        ModsView(game: game, embedded: true)
                    }
                }
                topBar
            }
        }
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .task { await refresh() }
        .fullScreenCover(item: $route, onDismiss: { Task { await refresh() } }) { page in
            if let game {
                routeView(page, game)
                    .font(.pixel(16))
                    .environmentObject(store)
                    .environmentObject(collections)
                    .environmentObject(privacy)
            }
        }
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
                    renaming = info
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

    @ViewBuilder
    private func routeView(_ page: GameRoute, _ game: Game) -> some View {
        switch page {
        case .settings:
            GameSettingsView(gameID: game.id) {
                route = nil
                dismiss()
            }
        case .saves:
            GameSavesView(gameID: game.id)
        case .media:
            MediaBrowserView(game: game)
        case .mods:
            ModsView(game: game)
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        VStack {
            HStack {
                GlassCircleButton(symbol: "xmark", label: "Close") { dismiss() }
                Spacer()
                if let game {
                    GlassCircleButton(symbol: game.isFavorite ? "heart.fill" : "heart",
                                      label: game.isFavorite ? "Unfavorite" : "Favorite") {
                        store.toggleFavorite(game)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                if pageTab != .overview, let game {
                    GlassCircleButton(symbol: "play.fill", label: "Play") { onPlay(game) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func coverFrame(_ game: Game) -> some View {
        Group {
            if let hero {
                Image(uiImage: hero)
                    .resizable()
                    .interpolation(hero.size.width < 400 ? .none : .high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                CoverView(game: game).frame(maxWidth: 240)
            }
        }
        .frame(maxHeight: 300)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(game.tagColor ?? Color.white.opacity(0.14), lineWidth: 1.5))
        .shadow(color: (game.tagColor ?? .black).opacity(0.35), radius: 20, y: 10)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private func titleBlock(_ game: Game) -> some View {
        VStack(spacing: 12) {
            Text(game.name)
                .font(.pixel(30, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 6)
            HStack(spacing: 8) {
                Text(game.engine.badge)
                    .font(.pixel(15))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.14)))
                if game.isFavorite {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                }
                if game.status != nil {
                    Label(game.playStatus.title, systemImage: game.playStatus.symbol)
                        .font(.pixel(13))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(game.playStatus.color.opacity(0.3), in: Capsule())
                }
            }
            if game.playSeconds > 0 || game.lastPlayed != nil {
                Text(statsLine(game)).font(.pixel(12)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func infoChips(_ game: Game) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatChip(symbol: "clock.fill", text: game.playSeconds > 0 ? formatHours(game.playSeconds) : "Not played")
                if game.playCount > 0 {
                    StatChip(symbol: "play.fill", text: "\(game.playCount) session\(game.playCount == 1 ? "" : "s")")
                }
                StatChip(symbol: "calendar", text: "Added " + game.addedAt.formatted(date: .abbreviated, time: .omitted))
                if let folderSize {
                    StatChip(symbol: "internaldrive.fill", text: ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file))
                }
                if let runtimeLabel {
                    StatChip(symbol: "cpu", text: runtimeLabel)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func noticeCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.pixel(13)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.orange.opacity(0.35)))
    }

    private func statsLine(_ game: Game) -> String {
        var parts = [formatDuration(game.playSeconds)]
        if let last = game.lastPlayed { parts.append("last played " + last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func profileRow(_ game: Game) -> some View {
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
                        Image(systemName: "plus").font(.system(size: 34, weight: .black)).foregroundStyle(NexStyle.accent)
                        Text("New Profile").font(.pixel(14)).foregroundStyle(.white)
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

    private func crashCard(_ game: Game, _ kind: RuntimeKind) -> some View {
        let others = GameRuntimes.choices(for: game).filter { $0 != kind }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(.red)
                Text("NexPlay closed while starting this game on \(kind.title) last time. Try another runtime, or play again if it was a one-off.")
                    .font(.pixel(13))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(others) { other in
                    Button {
                        store.mutate(game.id) { $0.runtime = other }
                        LaunchGuard.clearCrash(for: game.id)
                        crashedOn = nil
                    } label: {
                        Label("Use \(other.title)", systemImage: other.symbol).font(.pixel(13))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NexStyle.accentDeep)
                }
                Button("Dismiss") {
                    LaunchGuard.clearCrash(for: game.id)
                    crashedOn = nil
                }
                .font(.pixel(13))
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.red.opacity(0.35)))
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GamePageTab.allCases) { item in
                    Button {
                        if pageTab != item {
                            UISelectionFeedbackGenerator().selectionChanged()
                            pageTab = item
                        }
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.pixel(13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                if pageTab == item {
                                    Capsule().fill(NexStyle.accentGradient)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.08))
                                }
                            }
                            .overlay(Capsule().stroke(Color.white.opacity(pageTab == item ? 0 : 0.12)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    /// Overview: status, developer, version and notes (edited in the Settings tab).
    private func detailsCard(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Details", systemImage: "list.bullet.rectangle.fill")
                .font(.pixel(14))
                .foregroundStyle(NexStyle.accent)
            detailRow("Status", game.playStatus.title)
            if let developer = game.developer, !developer.isEmpty { detailRow("Developer", developer) }
            if let version = game.version, !version.isEmpty { detailRow("Version", version) }
            detailRow("Engine", game.engine.title)
            if let notes = game.notes, !notes.isEmpty {
                Text(notes)
                    .font(.pixel(13))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Button {
                pageTab = .settings
            } label: {
                Label("Edit in Settings", systemImage: "pencil")
                    .font(.pixel(13))
            }
            .tint(NexStyle.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexStyle.cardStroke))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.pixel(13)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.pixel(13)).foregroundStyle(.white).multilineTextAlignment(.trailing)
        }
    }

    private func howItRunsCard(_ game: Game) -> some View {
        let kind = GameRuntimes.kind(for: game)
        let current = game.compatibility ?? .untested
        return VStack(alignment: .leading, spacing: 12) {
            Label("How It Runs", systemImage: kind.symbol)
                .font(.pixel(14))
                .foregroundStyle(NexStyle.accent)
            Text(kind.howItRuns)
                .font(.pixel(13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text(game.runtime == nil ? "Runtime: Automatic (\(kind.title))" : "Runtime: \(kind.title), chosen in Game Settings")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([CompatStatus.works, .playable, .broken]) { status in
                    Button {
                        store.mutate(game.id) { $0.compatibility = current == status ? nil : status }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(status.color).frame(width: 8, height: 8)
                            Text(status.title).font(.pixel(13))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(current == status ? status.color.opacity(0.45) : Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(current == status ? status.color : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Text("Your verdict. It shows on the game's card.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexStyle.cardStroke))
    }

    private func bottomBar(_ game: Game) -> some View {
        let setup = GameReadiness.setupReason(for: game)
        return VStack(spacing: 14) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            if let setup {
                Button {
                    showSetupCenter = true
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 10) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text("Set Up").font(.pixel(22))
                        }
                        Text(setup).font(.pixel(11)).opacity(0.8)
                    }
                }
                .buttonStyle(PlayButtonStyle())
                .padding(.horizontal, 20)
                Button("Play Anyway") { onPlay(game) }
                    .font(.pixel(13))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Button {
                    onPlay(game)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                        Text("Play").font(.pixel(24))
                    }
                }
                .buttonStyle(PlayButtonStyle())
                .padding(.horizontal, 20)
            }
            Color.clear.frame(height: 4)
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    // MARK: - Profiles

    private func refresh() async {
        guard let game else { return }
        let target = game
        crashedOn = LaunchGuard.crashedRuntime(for: target.id)
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
            notice = fine ? nil : "This build has no EasyRPG core. Pick Windows in Game Settings > Runtime, or install a newer build."
        case .windows:
            notice = BCDRuntimeInfo.unavailableReason ?? target.windowsInfo.flatMap {
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
                Text(info.profile.name).font(.pixel(17)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onInfo) {
                    Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.55)).padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile options")
            }
            Text(info.count == 1 ? "1 save" : "\(info.count) saves").font(.pixel(13)).foregroundStyle(.white.opacity(0.6))
            Text(info.newest.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "No saves yet")
                .font(.pixel(13)).foregroundStyle(.white.opacity(0.45))
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
                Text(title).font(.pixel(15)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
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
