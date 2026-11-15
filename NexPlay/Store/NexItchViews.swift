import SwiftUI
import UIKit

// 8.5.0: itch.io in NexPlay's design (DesignSystem tokens, NexMenuSection/NexMenuRow rows from the in-game menu).
// NexItchStoreView: the store sheet (+ menu, Home, Library toolbar): your games, collections, search or a pasted
// game link, then a game page with its uploads and Install / Update. NexItchAccountPage: Settings › Accounts › itch.io.
// Only itch.io is shown; BCD's other stores stay hidden (docs/PLAN-8.0.md).

/// The store sheet. `install` closes the sheet and starts the download (the import card shows its progress).
struct NexItchStoreView: View {
    let install: (NexItchGame, NexItchUpload) -> Void
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var account = NexItchAccount.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [NexItchGame]?
    @State private var searching = false
    @State private var searchFailure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !account.signedIn {
                        NexItchSignInCard()
                    } else {
                        accountHeader
                        if let results {
                            gameSection(searchTitle, games: results, empty: "No games found.")
                        } else if searching {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                        } else {
                            if let failure = account.failure { note(failure, symbol: "exclamationmark.triangle.fill", tint: NexColor.warning) }
                            gameSection("Your Games", games: account.owned,
                                        empty: account.loading ? "Loading your itch.io library…" : "No purchased or claimed games yet. Search itch.io or paste a game's link above.")
                            if !account.collected.isEmpty { gameSection("Collections", games: account.collected, empty: "") }
                        }
                        if let searchFailure { note(searchFailure, symbol: "exclamationmark.triangle.fill", tint: NexColor.warning) }
                    }
                }
                .padding(16)
                .padding(.bottom, 30)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("itch.io")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(NexItchSearch(enabled: account.signedIn, text: $search, submit: runSearch))
            .onChange(of: search) { text in
                if text.isEmpty { results = nil; searchFailure = nil }
            }
            .refreshable { await account.refresh() }
            .navigationDestination(for: NexItchGame.self) { game in
                NexItchGamePage(game: game) { upload in
                    dismiss()
                    install(game, upload)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { dismiss() } }
            }
        }
        .onAppear { account.start() }
    }

    private var searchTitle: String {
        NexItchFormat.dataURL(search) != nil ? "From the Link" : "Search Results"
    }

    private var accountHeader: some View {
        HStack(spacing: 14) {
            NexItchBadge(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.accountName ?? "itch.io account").font(NexType.heading).foregroundStyle(NexColor.text).lineLimit(1)
                Text("\(account.owned.count) owned · \(account.collected.count) in collections")
                    .font(NexType.caption).foregroundStyle(NexColor.textSoft)
            }
            Spacer(minLength: 8)
            if account.loading {
                ProgressView()
            } else {
                Button {
                    NexHaptics.tap()
                    Task { await account.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(NexGlassIconButtonStyle(size: 38))
                    .accessibilityLabel("Refresh")
            }
        }
        .nexCard(padding: 14)
    }

    private func gameSection(_ title: String, games: [NexItchGame], empty: String) -> some View {
        NexMenuSection(title) {
            if games.isEmpty {
                Text(empty).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(games) { game in
                    NavigationLink(value: game) {
                        NexItchGameRow(game: game, installed: store.itchGame(game.id) != nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).font(NexType.caption).foregroundStyle(NexColor.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .nexCard(padding: 12)
    }

    private func runSearch() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        searchFailure = nil
        Task {
            do {
                if NexItchFormat.dataURL(text) != nil {
                    results = [try await NexItchAPI.shared.game(link: text)]
                } else {
                    results = try await NexItchAPI.shared.search(text)
                }
            } catch {
                results = nil
                searchFailure = error.localizedDescription
            }
            searching = false
        }
    }
}

/// The search field only while signed in.
private struct NexItchSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let submit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search itch.io or paste a game link")
                .onSubmit(of: .search) { submit() }
        } else {
            content
        }
    }
}

/// itch.io's mark: a rounded tile in itch.io's red.
struct NexItchBadge: View {
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: "gamecontroller.fill")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.98, green: 0.36, blue: 0.36).gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A cover from itch.io (fixed size, placeholder while it loads).
private struct NexItchCover: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(NexColor.surfaceRaised)
            .frame(width: width, height: height)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(NexColor.textSoft.opacity(0.6))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct NexItchGameRow: View {
    let game: NexItchGame
    let installed: Bool

    var body: some View {
        HStack(spacing: 12) {
            NexItchCover(url: game.cover, width: 76, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(NexType.label).foregroundStyle(NexColor.text).lineLimit(2)
                Text([game.author, game.platformSummary].compactMap { $0 }.joined(separator: " · "))
                    .font(NexType.caption).foregroundStyle(NexColor.textSoft).lineLimit(1)
            }
            Spacer(minLength: 6)
            if installed {
                Text("In Library")
                    .font(NexType.captionStrong)
                    .foregroundStyle(NexColor.success)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(NexColor.success.opacity(0.15), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(NexColor.textSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A game's page: cover, uploads (the recommended one picked), Install or Update.
private struct NexItchGamePage: View {
    let game: NexItchGame
    let install: (NexItchUpload) -> Void
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openURL) private var openURL
    @State private var uploads: [NexItchUpload]?
    @State private var chosen: Int?
    @State private var failure: String?
    @State private var showExtras = false

    private var installed: Game? { store.itchGame(game.id) }
    private var games: [NexItchUpload] { (uploads ?? []).filter { $0.rank != nil } }
    private var extras: [NexItchUpload] { (uploads ?? []).filter { $0.rank == nil } }
    private var selected: NexItchUpload? { (uploads ?? []).first { $0.id == chosen } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(NexType.caption).foregroundStyle(NexColor.text)
                        .nexCard(padding: 12)
                }
                if uploads == nil && failure == nil {
                    ProgressView("Reading the downloads…").frame(maxWidth: .infinity).padding(.top, 10)
                } else if let uploads, uploads.isEmpty {
                    Text(game.owned || (game.minPrice ?? 0) == 0
                         ? "This game has no downloads (it may be played only in the browser on itch.io)."
                         : "itch.io lists no downloads for this account. Paid games show their files once you own them.")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        .nexCard(padding: 12)
                }
                if !games.isEmpty {
                    NexMenuSection("Downloads") {
                        ForEach(games) { upload in uploadRow(upload) }
                    }
                }
                if !extras.isEmpty {
                    NexMenuSection("Extras") {
                        if showExtras {
                            ForEach(extras) { upload in uploadRow(upload) }
                        } else {
                            NexMenuRow(title: "Show \(extras.count) More", detail: "Soundtracks, books, mods and other files",
                                       symbol: "ellipsis.circle", accessory: .chevron) { showExtras = true }
                        }
                    }
                }
                if let selected {
                    Text(selected.recommendedNote)
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        .padding(.horizontal, 4)
                    Button {
                        NexHaptics.press()
                        install(selected)
                    } label: {
                        Label(installed == nil ? "Install" : "Download Again (Update It / Add as New)",
                              systemImage: installed == nil ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(NexPrimaryButtonStyle())
                    .disabled(store.isImporting)
                    if store.isImporting {
                        Text("Another import is running.").font(NexType.caption).foregroundStyle(NexColor.textSoft)
                    }
                }
                if let url = game.url {
                    Button { openURL(url) } label: { Label("Open on itch.io", systemImage: "safari") }
                        .buttonStyle(NexGlassButtonStyle())
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            NexItchCover(url: game.cover, width: 315 * 0.9, height: 250 * 0.9)
                .frame(maxWidth: .infinity)
            Text(game.title).font(NexType.title(22)).foregroundStyle(NexColor.text)
            HStack(spacing: 8) {
                if let author = game.author {
                    Text(author).font(NexType.label).foregroundStyle(NexColor.accentSoft)
                }
                Text(game.owned ? "Owned" : ((game.minPrice ?? 0) == 0 ? "Free" : "Not owned"))
                    .font(NexType.captionStrong).foregroundStyle(NexColor.textSoft)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .nexGlassCapsule()
                if installed != nil {
                    Text("In Library").font(NexType.captionStrong).foregroundStyle(NexColor.success)
                }
            }
            if let text = game.shortText, !text.isEmpty {
                Text(text).font(NexType.body).foregroundStyle(NexColor.textSoft)
            }
        }
    }

    private func uploadRow(_ upload: NexItchUpload) -> some View {
        let size = upload.size > 0 ? ByteCountFormatter.string(fromByteCount: upload.size, countStyle: .file) : nil
        let best = NexItchFormat.choose(uploads ?? [])?.id == upload.id
        let detail = [upload.kindLabel + (upload.demo ? " demo" : ""), size, best ? "Recommended" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return NexMenuRow(title: upload.name, detail: detail, symbol: upload.symbol, accessory: .check(chosen == upload.id)) {
            chosen = upload.id
        }
    }

    private func load() async {
        guard uploads == nil else { return }
        do {
            let list = NexItchFormat.sorted(try await NexItchAPI.shared.uploads(game: game.id, downloadKey: game.downloadKeyID))
            uploads = list
            chosen = NexItchFormat.choose(list)?.id
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Signing in with an API key made on itch.io. The key is checked with itch.io, kept in the Keychain only once
/// itch.io accepts it, the field is cleared at once, and the key is never logged.
struct NexItchSignInCard: View {
    @ObservedObject private var account = NexItchAccount.shared
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NexItchBadge(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to itch.io").font(NexType.heading).foregroundStyle(NexColor.text)
                    Text("See the games you bought or claimed and install them into NexPlay.")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                }
            }
            Text("1. Open itch.io's API keys page and make a new key.\n2. Copy it, come back and paste it here.")
                .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button { openURL(NexItchAPI.keysPage) } label: { Label("Get an API Key", systemImage: "key.fill") }
                .buttonStyle(NexGlassButtonStyle())
            HStack(spacing: 8) {
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(NexType.body)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(NexColor.surfaceRaised, in: RoundedRectangle(cornerRadius: NexMetrics.cornerS, style: .continuous))
                Button {
                    key = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(NexGlassIconButtonStyle(size: 46))
                    .accessibilityLabel("Paste")
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(NexType.caption).foregroundStyle(NexColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: signIn) {
                if busy { ProgressView().tint(NexColor.onAccent) } else { Text("Sign In") }
            }
            .buttonStyle(NexPrimaryButtonStyle())
            .disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("The key stays in this iPhone's Keychain. You can delete it on itch.io at any time.")
                .font(NexType.caption).foregroundStyle(NexColor.textSoft)
        }
        .nexCard(padding: 16)
    }

    private func signIn() {
        let candidate = key
        key = ""
        busy = true
        failure = nil
        Task {
            do {
                try await account.signIn(key: candidate)
                NexHaptics.success()
            } catch {
                failure = error.localizedDescription
                NexHaptics.error()
            }
            busy = false
        }
    }
}

/// Settings › Accounts › itch.io.
struct NexItchAccountPage: View {
    @ObservedObject private var account = NexItchAccount.shared
    @State private var confirmSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if account.signedIn {
                    NexMenuSection("Account") {
                        HStack(spacing: 12) {
                            NexItchBadge(size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.accountName ?? "itch.io account").font(NexType.label).foregroundStyle(NexColor.text)
                                Text("Signed in · \(account.owned.count) owned games").font(NexType.caption).foregroundStyle(NexColor.textSoft)
                            }
                            Spacer()
                            NexStatusMark(ok: account.failure == nil)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        NexMenuRow(title: account.loading ? "Refreshing…" : "Refresh Library", symbol: "arrow.clockwise",
                                   enabled: !account.loading) {
                            Task { await account.refresh() }
                        }
                        NexMenuRow(title: "Sign Out", detail: "Removes the key from this iPhone. Installed games stay.",
                                   symbol: "rectangle.portrait.and.arrow.right", destructive: true) {
                            confirmSignOut = true
                        }
                    }
                    if let failure = account.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(NexType.caption).foregroundStyle(NexColor.text)
                            .nexCard(padding: 12)
                    }
                    Text("Open the store from the + button or the itch.io button in the Library.")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft).padding(.horizontal, 4)
                } else {
                    NexItchSignInCard()
                }
            }
            .padding(16)
        }
        .onAppear { account.start() }
        .confirmationDialog("Sign out of itch.io?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { account.signOut() }
        } message: {
            Text("NexPlay removes your API key from this iPhone's Keychain and forgets the list of your itch.io games. Installed games stay and still play.")
        }
    }
}
