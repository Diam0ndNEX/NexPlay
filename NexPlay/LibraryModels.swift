import SwiftUI
import LocalAuthentication
import ZIPFoundation

// Sort options, retention presets (Less 5 / Standard 10 / More 20 last backups) and backup triggers (session end,
// background, 30 s after launch, only when saves changed) follow Empo's GameSorting.swift and docs/backups.mdx.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

extension SettingsKey {
    static let librarySortOrder = "librarySortOrder"
    static let libraryLayout = "libraryLayout"          // "grid" or "list"
    static let titleUnderCard = "titleUnderCard"        // grid: title under (true) or inside (false) the cover
    static let showContinueCard = "showContinueCard"
    static let theme = "theme"                          // "dark", "light", "system"
    static let autoBackup = "autoBackup"
    static let backupRetention = "backupRetention"      // 5, 10 or 20
    static let hiddenGames = "hiddenGames"
    static let defaultFastForward = "defaultFastForward"

    /// Every key Reset to Defaults clears.
    static let all: [String] = [
        librarySort, silentModeAudio, showMenuButton, keepScreenAwake, desktopMode, pixelatedScaling, nwMode,
        hapticsEnabled, hapticStrength, controllerMode, librarySortOrder, libraryLayout, titleUnderCard,
        showContinueCard, theme, autoBackup, backupRetention, defaultFastForward, screenScaling, screenshotsToPhotos,
    ]
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case titleAZ, titleZA, addedNewest, addedOldest, playedRecent, playedLeastRecent, mostPlayed, leastPlayed, largest, smallest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleAZ: return "Title A–Z"
        case .titleZA: return "Title Z–A"
        case .addedNewest: return "Recently Added"
        case .addedOldest: return "Least Recently Added"
        case .playedRecent: return "Recently Played"
        case .playedLeastRecent: return "Least Recently Played"
        case .mostPlayed: return "Most Played"
        case .leastPlayed: return "Least Played"
        case .largest: return "Largest"
        case .smallest: return "Smallest"
        }
    }

    var needsSizes: Bool { self == .largest || self == .smallest }

    func sort(_ games: [Game], sizes: [UUID: Int64]) -> [Game] {
        let byTitle: (Game, Game) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        switch self {
        case .titleAZ: return games.sorted(by: byTitle)
        case .titleZA: return games.sorted { byTitle($1, $0) }
        case .addedNewest: return games.sorted { $0.addedAt > $1.addedAt }
        case .addedOldest: return games.sorted { $0.addedAt < $1.addedAt }
        case .playedRecent: return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .playedLeastRecent: return games.sorted { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        case .mostPlayed: return games.sorted { $0.playSeconds > $1.playSeconds }
        case .leastPlayed: return games.sorted { $0.playSeconds < $1.playSeconds }
        case .largest: return games.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .smallest: return games.sorted { (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0) }
        }
    }
}

// MARK: - Collections

struct GameCollection: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorIndex: Int
    var gameIDs: [UUID]
    var isHidden: Bool

    static let palette: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .gray]

    var color: Color { GameCollection.palette[abs(colorIndex) % GameCollection.palette.count] }
}

/// Collections.json in Application Support/NexPlay.
@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var collections: [GameCollection] = []
    private let fileURL = Paths.support.appendingPathComponent("Collections.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([GameCollection].self, from: data) {
            collections = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func create(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collections.append(GameCollection(name: trimmed, colorIndex: collections.count, gameIDs: [], isHidden: false))
        save()
    }

    func change(_ id: UUID, _ edit: (inout GameCollection) -> Void) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        edit(&collections[index])
        save()
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func toggle(_ gameID: UUID, in collectionID: UUID) {
        change(collectionID) { collection in
            if let index = collection.gameIDs.firstIndex(of: gameID) {
                collection.gameIDs.remove(at: index)
            } else {
                collection.gameIDs.append(gameID)
            }
        }
    }

    func add(_ gameIDs: [UUID], to collectionID: UUID) {
        change(collectionID) { collection in
            for id in gameIDs where !collection.gameIDs.contains(id) { collection.gameIDs.append(id) }
        }
    }

    /// Removes a deleted game from every collection.
    func forget(_ gameID: UUID) {
        for index in collections.indices { collections[index].gameIDs.removeAll { $0 == gameID } }
        save()
    }

    func moveGames(in collectionID: UUID, from source: IndexSet, to destination: Int) {
        change(collectionID) { $0.gameIDs.move(fromOffsets: source, toOffset: destination) }
    }
}

// MARK: - Privacy

/// Hidden games and collections stay out of the library until the user unlocks with Face ID, Touch ID or the
/// passcode. Unlocked until the app goes to the background.
@MainActor
final class PrivacyLock: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var hiddenGames: Set<UUID> = []

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: SettingsKey.hiddenGames) ?? []
        hiddenGames = Set(stored.compactMap { UUID(uuidString: $0) })
    }

    func isHidden(_ gameID: UUID) -> Bool { hiddenGames.contains(gameID) }

    func setHidden(_ gameID: UUID, _ hidden: Bool) {
        if hidden { hiddenGames.insert(gameID) } else { hiddenGames.remove(gameID) }
        UserDefaults.standard.set(hiddenGames.map { $0.uuidString }, forKey: SettingsKey.hiddenGames)
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: nothing to check against.
            isUnlocked = true
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show hidden games")
            isUnlocked = ok
        } catch {
            isUnlocked = false
        }
    }

    func lock() {
        isUnlocked = false
    }
}

// MARK: - Automatic backups

enum AutoBackup {
    static var retention: Int {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.backupRetention)
        return [5, 10, 20].contains(value) ? value : 10
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.autoBackup) }

    /// Backs up a game's save/ folder when it changed since the newest backup. Returns true when a backup was made.
    @discardableResult
    static func run(_ game: Game, force: Bool = false) -> Bool {
        guard game.usesNWMode else { return false }
        let info = SaveArchive.info(for: game)
        guard info.count > 0, let newestSave = info.newest else { return false }
        let newestBackup = SaveArchive.backups(for: game).first?.date ?? .distantPast
        guard force || newestSave > newestBackup else { return false }
        do {
            try SaveArchive.backUp(game, label: Paths.timestamp())
            prune(game)
            AppLog.log("backed up saves of \(game.name)")
            return true
        } catch {
            AppLog.log("backup of \(game.name) failed: \(error.localizedDescription)")
            return false
        }
    }

    static func runAll(_ games: [Game], force: Bool = false) -> Int {
        var count = 0
        for game in games where run(game, force: force) { count += 1 }
        return count
    }

    /// Keeps the newest automatic backups (the retention preset). before-restore and before-delete copies are kept.
    static func prune(_ game: Game) {
        let automatic = SaveArchive.backups(for: game).filter { !$0.name.hasPrefix("before-") }
        for old in automatic.dropFirst(retention) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    /// One ZIP with the save/ folder of every game: <Name>/save/...
    static func exportAll(_ games: [Game]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NexPlay-all-saves-\(Paths.timestamp())", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var copied = 0
        for game in games {
            let saves = Paths.saveFolder(for: game)
            guard !SaveArchive.files(in: saves).isEmpty else { continue }
            let folder = root.appendingPathComponent("\(Paths.safeName(game.name))-\(game.id.uuidString.prefix(8))", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: saves, to: folder.appendingPathComponent("save"))
            copied += 1
        }
        guard copied > 0 else { throw SaveArchiveError.noSaves }
        let zip = fm.temporaryDirectory.appendingPathComponent(root.lastPathComponent + ".zip")
        try? fm.removeItem(at: zip)
        try fm.zipItem(at: root, to: zip, shouldKeepParent: false)
        try? fm.removeItem(at: root)
        return zip
    }

    /// True for a ZIP that holds RPG Maker save files but no game (a NexPlay save backup or export).
    static func looksLikeSaveBackup(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zip",
              let archive = try? Archive(url: url, accessMode: .read) else { return false }
        var hasSave = false
        for entry in archive {
            let path = entry.path.lowercased()
            if path.hasSuffix("index.html") || path.hasSuffix("game.ini") { return false }
            if path.hasSuffix(".rpgsave") || path.hasSuffix(".rmmzsave") { hasSave = true }
        }
        return hasSave
    }
}

/// App-wide UI state shared by the library and the app (a save backup opened from Files).
@MainActor
final class AppState: ObservableObject {
    @Published var pendingBackup: URL?
}
