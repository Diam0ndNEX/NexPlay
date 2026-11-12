import SwiftUI
import AVKit
import UniformTypeIdentifiers
import Photos

// Manage Saves, the Media Browser (Gallery) and Mods, opened from the game page. Layout follows RPGPlayer's
// screenshots (action tiles, profile card, save cards with "Newest"; media tabs with counts and search; mods
// with a global switch); NexPlay's own code.

/// Header used by the full-screen pages: a capsule button on each side and a pixel title.
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title).font(.pixel(20)).foregroundStyle(.white)
            HStack {
                leading()
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// A capsule glass button with a pixel title.
struct CapsuleButton: View {
    let title: String
    var tint: Color = NexStyle.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.pixel(16))
                .foregroundStyle(tint)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Manage Saves

struct SaveFileItem: Identifiable, Hashable {
    let url: URL
    let relative: String
    let date: Date
    let bytes: Int64
    var id: String { relative }
    var name: String { (relative as NSString).deletingPathExtension }

    var symbol: String {
        let lower = relative.lowercased()
        if lower.hasPrefix("global") { return "globe" }
        if lower.hasPrefix("config") { return "gearshape.fill" }
        return "doc.text.fill"
    }
}

struct GameSavesView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    enum Tab: String, CaseIterable { case local = "Local Saves", backups = "Backups" }

    @State private var tab: Tab = .local
    @State private var files: [SaveFileItem] = []
    @State private var backups: [BackupEntry] = []
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var shareURLs: [URL] = []
    @State private var sharing = false
    @State private var pickingSaves = false
    @State private var pendingBackup: BackupEntry?
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var busy = false

    private var game: Game? { store.game(id: gameID) }

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    PageHeader(title: "Manage Saves") {
                        CapsuleButton(title: "Close") { dismiss() }
                    } trailing: {
                        CapsuleButton(title: selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selected = []
                        }
                    }
                    actionTiles
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .background(Color(white: 0.07).opacity(0.92).ignoresSafeArea(edges: .top))

                if let game {
                    if game.usesNWMode {
                        ScrollView {
                            VStack(spacing: 14) {
                                profileCard(game)
                                Picker("Saves", selection: $tab) {
                                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                if tab == .local { localList } else { backupList }
                            }
                            .padding(16)
                        }
                    } else {
                        browserModeNote
                    }
                }
            }
            if busy { ProgressView().tint(.white).scaleEffect(1.4) }
        }
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .task { await refresh() }
        .sheet(isPresented: $sharing) { ActivityView(items: shareURLs) }
        // ZIPs, loose .rpgsave/.rmmzsave files (from a PC's www/save folder) or a whole save folder. No confirmation
        // dialog: one shown while the picker is still closing never appears. The import backs up first anyway.
        .fileImporter(isPresented: $pickingSaves, allowedContentTypes: [.zip, .folder, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty { importSaves(urls) }
            case .failure(let error):
                message = "Couldn't open the files: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } }),
                            titleVisibility: .visible) {
            Button("Restore") {
                if let entry = pendingBackup { restore(entry.url) }
                pendingBackup = nil
            }
            Button("Delete Backup", role: .destructive) {
                if let entry = pendingBackup { try? FileManager.default.removeItem(at: entry.url) }
                pendingBackup = nil
                Task { await refresh() }
            }
        } message: { Text("Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.") }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: { Text("A backup ZIP is made first, so this can be undone from Backups.") }
        .alert("Saves", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var deleteTitle: String {
        selected.isEmpty ? "Delete all save files?" : "Delete \(selected.count) save file(s)?"
    }

    private var actionTiles: some View {
        HStack(spacing: 10) {
            SaveActionTile(title: "Backup", symbol: "square.and.arrow.down", enabled: !files.isEmpty) { backUpNow() }
            SaveActionTile(title: "Import", symbol: "square.and.arrow.up", enabled: game?.usesNWMode == true) { pickingSaves = true }
            SaveActionTile(title: "Share", symbol: "square.and.arrow.up.on.square", enabled: !files.isEmpty) { share() }
            SaveActionTile(title: "Delete", symbol: "trash", enabled: selecting && !selected.isEmpty, destructive: true) {
                confirmDelete = true
            }
        }
    }

    private func profileCard(_ game: Game) -> some View {
        let active = SaveProfiles.active(game)
        return HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(NexStyle.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save Profile").font(.pixel(12)).foregroundStyle(.white.opacity(0.55))
                Text(active.name).font(.pixel(20)).foregroundStyle(.white)
            }
            Spacer()
            Text("Switch on the game page").font(.pixel(11)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var newestID: String? {
        files.filter { !$0.relative.lowercased().hasPrefix("config") }.max { $0.date < $1.date }?.id
    }

    private var localList: some View {
        VStack(spacing: 12) {
            if files.isEmpty {
                emptyNote("No save files yet", "Save in the game and they show up here. To bring saves from a PC, tap Import and pick the .rpgsave/.rmmzsave files (or a ZIP of the save folder).")
            }
            ForEach(files) { file in
                let isSelected = selected.contains(file.id)
                HStack(spacing: 16) {
                    Image(systemName: file.symbol)
                        .font(.title2)
                        .foregroundStyle(NexStyle.accent)
                        .frame(width: 58, height: 58)
                        .background(NexStyle.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(file.name).font(.pixel(19)).foregroundStyle(.white).lineLimit(1)
                            if file.id == newestID {
                                Text("Newest").font(.pixel(12)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(NexStyle.accentDeep, in: Capsule())
                            }
                        }
                        HStack(spacing: 14) {
                            Label(file.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            Label(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file), systemImage: "internaldrive")
                        }
                        .font(.pixel(12))
                        .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? NexStyle.accent : .white.opacity(0.4))
                    }
                }
                .padding(16)
                .background(Color(white: 0.11).opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(isSelected ? NexStyle.accent : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    if selecting {
                        if isSelected { selected.remove(file.id) } else { selected.insert(file.id) }
                    }
                }
                .contextMenu {
                    Button { shareURLs = [file.url]; sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        selected = [file.id]
                        confirmDelete = true
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    private var backupList: some View {
        VStack(spacing: 12) {
            if backups.isEmpty {
                emptyNote("No backups yet", "Tap Backup, or let automatic backups run after you play.")
            }
            ForEach(backups) { entry in
                let safety = entry.name.hasPrefix("before-")
                Button { pendingBackup = entry } label: {
                    HStack(spacing: 16) {
                        Image(systemName: safety ? "shield.lefthalf.filled" : "archivebox.fill")
                            .font(.title2)
                            .foregroundStyle(NexStyle.accent)
                            .frame(width: 58, height: 58)
                            .background(NexStyle.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.pixel(17)).foregroundStyle(.white)
                            Text(safety ? "Safety copy" : ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                .font(.pixel(12)).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "arrow.counterclockwise").foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(16)
                    .background(Color(white: 0.11).opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private var browserModeNote: some View {
        ScrollView {
            emptyNote("Saves are in web storage", browserModeText)
                .padding(20)
        }
    }

    private var browserModeText: String {
        switch game?.engine ?? .web {
        case .renpy:
            return "Ren'Py keeps its saves inside the web runtime. To move them, start the game and open the game menu (bubble, then gear) > Ren'Py Saves: Export makes a ZIP, Back Up Now stores one in this game's backups, and Import takes .save files, a saves folder or a ZIP (from a PC: game/saves or %APPDATA%/RenPy/<game>)."
        case .twine:
            return "Twine games keep their saves inside the browser. Use the game's own Saves menu: Export opens the share sheet with the save file, Import reads one back. NexPlay's game menu (bubble, then gear, then Saves) can back up all of the game's web storage too."
        case .godot:
            return "Godot games keep their saves (user://) inside the browser. Back them up from the game: tap the bubble, then the gear, then Saves."
        default:
            return "This game keeps its saves inside the browser. Back them up from the game: tap its bubble, then the gear, then Saves. RPG Maker games can switch to NW.js mode in Game Settings to keep saves as files."
        }
    }

    private func emptyNote(_ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.pixel(18)).foregroundStyle(.white)
            Text(text).font(.pixel(13)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(white: 0.11).opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: Actions

    private func refresh() async {
        guard let game else { return }
        let target = game
        files = await Task.detached { () -> [SaveFileItem] in
            SaveArchive.files(in: Paths.saveFolder(for: target))
                .filter { !$0.relative.hasSuffix(SaveArchive.displacedSuffix) }
                .map { file in
                    let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    return SaveFileItem(url: file.url, relative: file.relative,
                                        date: values?.contentModificationDate ?? .distantPast,
                                        bytes: Int64(values?.fileSize ?? 0))
                }
                .sorted { $0.date > $1.date }
        }.value
        backups = await Task.detached { SaveArchive.backups(for: target) }.value
    }

    private func backUpNow() {
        guard let game else { return }
        busy = true
        Task {
            _ = await Task.detached { AutoBackup.run(game, force: true) }.value
            busy = false
            tab = .backups
            await refresh()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func share() {
        guard let game else { return }
        if selecting && !selected.isEmpty {
            shareURLs = files.filter { selected.contains($0.id) }.map { $0.url }
            sharing = true
            return
        }
        Task {
            do {
                let url = try await Task.detached { try SaveArchive.exportZip(for: game) }.value
                shareURLs = [url]
                sharing = true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Imports picked ZIPs, save files or folders (SaveArchive.importSaves opens each one's security scope).
    private func importSaves(_ urls: [URL]) {
        guard let game else { return }
        busy = true
        Task {
            do {
                let count = try await Task.detached { try SaveArchive.importSaves(from: urls, into: game) }.value
                message = "Imported \(count) save file(s). Your old saves were backed up first (see Backups)."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
            busy = false
            tab = .local
            await refresh()
        }
    }

    private func restore(_ url: URL) {
        guard let game else { return }
        busy = true
        Task {
            do {
                let count = try await Task.detached { try SaveArchive.restore(zip: url, into: game) }.value
                message = "Restored \(count) save file(s)."
            } catch {
                message = "Restore failed: \(error.localizedDescription)"
            }
            busy = false
            tab = .local
            await refresh()
        }
    }

    private func deleteSelected() {
        guard let game else { return }
        let targets = selected.isEmpty ? files : files.filter { selected.contains($0.id) }
        busy = true
        Task {
            do {
                try await Task.detached {
                    try SaveArchive.backUp(game, label: "before-delete-\(Paths.timestamp())")
                    for file in targets { try FileManager.default.removeItem(at: file.url) }
                }.value
            } catch {
                message = error.localizedDescription
            }
            selected = []
            selecting = false
            busy = false
            await refresh()
        }
    }
}

struct SaveActionTile: View {
    let title: String
    let symbol: String
    var enabled = true
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                Text(title).font(.pixel(14))
            }
            .foregroundStyle(destructive && enabled ? Color.red : .white)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(Color(white: 0.16).opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08)))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
    }
}

// MARK: - Media Browser

struct MediaBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game

    @State private var index: [MediaKind: [MediaItem]] = [:]
    @State private var tab: MediaKind = .pictures
    @State private var search = ""
    @State private var loading = true
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var viewing: MediaItem?
    @State private var shareURLs: [URL] = []
    @State private var sharing = false
    @State private var key: [UInt8]?

    private var tabs: [MediaKind] {
        MediaKind.allCases.filter { !(index[$0] ?? []).isEmpty || $0 == .screenshots }
    }

    private var items: [MediaItem] {
        let list = index[tab] ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                PageHeader(title: "Media Browser") {
                    GlassCircleButton(symbol: "xmark", label: "Close") { dismiss() }
                } trailing: {
                    CapsuleButton(title: selecting ? "Done" : "Select", tint: .white) {
                        selecting.toggle()
                        selected = []
                    }
                }
                searchField
                tabBar
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                content
                if selecting && !selected.isEmpty { selectionBar }
            }
        }
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .task { await load() }
        .sheet(isPresented: $sharing) { ActivityView(items: shareURLs) }
        .fullScreenCover(item: $viewing) { item in
            MediaViewer(game: game, item: item, key: key) { viewing = nil }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7))
            TextField("Search media", text: $search)
                .font(.pixel(16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color(white: 0.13), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { kind in
                    let chosen = kind == tab
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { tab = kind }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbol)
                            Text(kind.title).font(.pixel(16))
                            Text("\((index[kind] ?? []).count)").font(.pixel(12)).foregroundStyle(.white.opacity(0.6))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(chosen ? NexStyle.accentDeep.opacity(0.45) : Color(white: 0.13), in: Capsule())
                        .overlay(Capsule().stroke(chosen ? NexStyle.accent : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer()
            ProgressView("Scanning the game…").tint(.white).font(.pixel(14))
            Spacer()
        } else if items.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: tab.symbol).font(.system(size: 40)).foregroundStyle(.white.opacity(0.35))
                Text(tab == .screenshots ? "No screenshots yet" : "Nothing here").font(.pixel(17))
                if tab == .screenshots {
                    Text("In a game, open its bubble and tap the camera.").font(.pixel(13)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(items) { item in
                        let isSelected = selected.contains(item.id)
                        MediaThumb(item: item, key: key)
                            .overlay(alignment: .topTrailing) {
                                if selecting {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? NexStyle.accent : .white)
                                        .padding(6)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? NexStyle.accent : .clear, lineWidth: 3))
                            .onTapGesture {
                                if selecting {
                                    if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
                                } else {
                                    viewing = item
                                }
                            }
                    }
                }
                .padding(6)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selected.count) selected").font(.pixel(14))
            Spacer()
            Button {
                let chosen = items.filter { selected.contains($0.id) }
                let currentKey = key
                Task {
                    shareURLs = await Task.detached { chosen.compactMap { MediaIndex.exportable($0, key: currentKey) } }.value
                    sharing = !shareURLs.isEmpty
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up").font(.pixel(15))
            }
            .buttonStyle(.borderedProminent)
            .tint(NexStyle.accentDeep)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private func load() async {
        let target = game
        key = await Task.detached { RPGMakerCrypto.key(for: target) }.value
        index = await Task.detached(priority: .userInitiated) { MediaIndex.scan(target) }.value
        if (index[tab] ?? []).isEmpty, let first = tabs.first { tab = first }
        loading = false
    }
}

/// A square thumbnail for a media item (decrypted images, video frames, a film icon for WebM).
struct MediaThumb: View {
    let item: MediaItem
    let key: [UInt8]?
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else if item.kind.isVideo {
                    VStack(spacing: 6) {
                        Image(systemName: "film").font(.title)
                        Text(item.name).font(.pixel(11)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind.isVideo, image != nil {
                    Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: item.id) {
                let target = item
                let currentKey = key
                image = await Task.detached(priority: .utility) { () -> UIImage? in
                    if target.kind.isVideo {
                        guard ["mp4", "m4v", "mov"].contains(target.url.pathExtension.lowercased()) else { return nil }
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target.url))
                        generator.appliesPreferredTrackTransform = true
                        generator.maximumSize = CGSize(width: 300, height: 300)
                        guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) else { return nil }
                        return UIImage(cgImage: frame)
                    }
                    guard let full = RPGMakerCrypto.image(at: target.url, key: currentKey) else { return nil }
                    return full.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? full
                }.value
            }
    }
}

/// Full-screen view of one item: zoom, share, set as cover, save to Photos; video playback for MP4/MOV.
struct MediaViewer: View {
    let game: Game
    let item: MediaItem
    let key: [UInt8]?
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var note: String?
    @State private var shareURLs: [URL] = []
    @State private var sharing = false
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnificationGesture().onChanged { zoom = max(1, min($0, 6)) }.onEnded { _ in
                        if zoom < 1.05 { withAnimation { zoom = 1 } }
                    })
                    .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
            } else if item.kind.isVideo {
                VStack(spacing: 10) {
                    Image(systemName: "film").font(.system(size: 44))
                    Text("\(item.url.pathExtension.uppercased()) videos can't be previewed on iPhone; the game plays them itself.")
                        .font(.pixel(14)).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    GlassCircleButton(symbol: "xmark", label: "Close") {
                        player?.pause()
                        onClose()
                    }
                    Spacer()
                    Text(item.name).font(.pixel(15)).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(16)
                Spacer()
                if let note {
                    Text(note).font(.pixel(14)).padding(10).background(.ultraThinMaterial, in: Capsule())
                }
                if image != nil {
                    HStack(spacing: 12) {
                        viewerButton("square.and.arrow.up", "Share") { share() }
                        viewerButton("photo.fill", "Set Cover") { setCover() }
                        viewerButton("square.and.arrow.down", "To Photos") { saveToPhotos() }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .foregroundStyle(.white)
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .task { await load() }
        .sheet(isPresented: $sharing) { ActivityView(items: shareURLs) }
    }

    private func viewerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.pixel(12))
            }
            .frame(width: 96, height: 62)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }

    private func load() async {
        if item.kind.isVideo {
            if ["mp4", "m4v", "mov"].contains(item.url.pathExtension.lowercased()) {
                let video = AVPlayer(url: item.url)
                player = video
                video.play()
            }
            return
        }
        let target = item
        let currentKey = key
        image = await Task.detached(priority: .userInitiated) { RPGMakerCrypto.image(at: target.url, key: currentKey) }.value
    }

    private func share() {
        let target = item
        let currentKey = key
        Task {
            if let url = await Task.detached(operation: { MediaIndex.exportable(target, key: currentKey) }).value {
                shareURLs = [url]
                sharing = true
            }
        }
    }

    private func setCover() {
        guard let image else { return }
        CoverStore.setCover(image, for: game)
        note = "Cover updated."
    }

    private func saveToPhotos() {
        guard let image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        note = "Saved to Photos."
    }
}

// MARK: - Mods

struct ModsView: View {
    @Environment(\.dismiss) private var dismiss
    /// nil shows the global mods.
    let game: Game?

    @State private var mods: [ModEntry] = []
    @State private var useGlobal = true
    @State private var pickingFiles = false
    @State private var pickingFolder = false
    @State private var showGlobal = false
    @State private var message: String?
    @State private var pendingDelete: ModEntry?

    private var title: String { game == nil ? "Global Mods" : "Mods" }

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                PageHeader(title: title) {
                    GlassCircleButton(symbol: game == nil ? "chevron.left" : "xmark", label: "Close") { dismiss() }
                } trailing: {
                    Menu {
                        Button { pickingFolder = true } label: { Label("Add Mod Folder…", systemImage: "folder") }
                        Button { pickingFiles = true } label: { Label("Add ZIP or Plugin (.js)…", systemImage: "doc.zipper") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.14)))
                    }
                }
                ScrollView {
                    VStack(spacing: 16) {
                        if let game { headerCard(game) }
                        if mods.isEmpty {
                            emptyState
                        } else {
                            ForEach(mods) { mod in modRow(mod) }
                        }
                        Text(helpText).font(.pixel(12)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 6)
                    }
                    .padding(16)
                }
            }
        }
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .onAppear { reload() }
        // One importer for both kinds: two fileImporter modifiers on one view don't work together.
        .fileImporter(isPresented: Binding(get: { pickingFiles || pickingFolder },
                                           set: { if !$0 { pickingFiles = false; pickingFolder = false } }),
                      allowedContentTypes: pickingFolder ? [.folder] : [.zip, .javaScript, UTType(filenameExtension: "js") ?? .sourceCode],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .fullScreenCover(isPresented: $showGlobal, onDismiss: reload) { ModsView(game: nil) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Mod", role: .destructive) {
                if let mod = pendingDelete { ModStore.delete(mod) }
                pendingDelete = nil
                reload()
            }
        } message: { Text("The game's own files are never changed; only the mod is removed.") }
        .alert("Mods", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var helpText: String {
        "A mod is a folder whose files lay over the game's files, starting where index.html is (js/plugins/Foo.js, img/pictures/Bar.png…), or a single plugin .js that is added to the plugin list. The game's files are never changed. Mods apply the next time the game starts."
    }

    private func headerCard(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.name).font(.pixel(18))
            Toggle(isOn: Binding(get: { useGlobal }, set: { value in
                useGlobal = value
                var config = ModStore.config(game)
                config.useGlobal = value
                ModStore.setConfig(config, for: game)
            })) {
                Text("Use Global Mods").font(.pixel(18))
            }
            .tint(NexStyle.accent)
            Text("Changes here affect only this game. Game-specific mods take priority over global mods.")
                .font(.pixel(12)).foregroundStyle(.white.opacity(0.55))
            Button { showGlobal = true } label: {
                Label("Manage Global Mods", systemImage: "puzzlepiece.extension.fill").font(.pixel(16))
            }
            .tint(.blue)
        }
        .padding(18)
        .background(Color(white: 0.12).opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 52)).foregroundStyle(.white.opacity(0.45))
            Text("No mods added").font(.pixel(20))
            Text(game == nil ? "Global mods apply to every game that uses them." : "Add a mod folder, a ZIP, or a plugin .js.")
                .font(.pixel(13)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            Menu {
                Button { pickingFolder = true } label: { Label("Mod Folder…", systemImage: "folder") }
                Button { pickingFiles = true } label: { Label("ZIP or Plugin (.js)…", systemImage: "doc.zipper") }
            } label: {
                Label("Add Mod", systemImage: "plus").font(.pixel(18)).foregroundStyle(.white)
                    .padding(.horizontal, 30).padding(.vertical, 15)
                    .background(NexStyle.accentGradient, in: Capsule())
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private func modRow(_ mod: ModEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: mod.isPlugin ? "curlybraces" : "folder.fill")
                .font(.title3)
                .foregroundStyle(NexStyle.accent)
                .frame(width: 50, height: 50)
                .background(NexStyle.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(mod.name).font(.pixel(17)).lineLimit(1)
                Text(mod.isPlugin ? "Plugin" : "\(mod.fileCount) file(s)").font(.pixel(12)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { mod.enabled }, set: { value in
                ModStore.setEnabled(mod, value, game: game)
                reload()
            }))
            .labelsHidden()
            .tint(NexStyle.accent)
        }
        .padding(14)
        .background(Color(white: 0.12).opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button(role: .destructive) { pendingDelete = mod } label: { Label("Delete Mod", systemImage: "trash") }
        }
    }

    private func reload() {
        mods = ModStore.mods(game)
        useGlobal = game.map { ModStore.config($0).useGlobal } ?? true
    }

    private func add(_ urls: [URL]) {
        let target = game
        Task {
            var added: [String] = []
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let name = try await Task.detached { try ModStore.add(url, game: target) }.value
                    added.append(name)
                } catch {
                    failed.append(url.lastPathComponent)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            reload()
            if !failed.isEmpty {
                message = "Couldn't add: \(failed.joined(separator: ", ")). Mods are folders, ZIPs or .js files."
            } else if !added.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
