import Foundation
import ZIPFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var isImporting = false
    @Published var importMessage: String?

    private let fileURL = Paths.support.appendingPathComponent("library.json")

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            games = try decoder.decode([Game].self, from: data)
        } catch {
            // Never overwrite a library we could not read: keep a copy for recovery.
            let copy = Paths.support.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: copy)
            AppLog.log("library.json could not be read (\(error.localizedDescription)); copy kept as \(copy.lastPathComponent)")
            games = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(games) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Changes

    /// Changes one game in place. Always go through this, so a stale copy of a game never overwrites newer changes.
    func mutate(_ id: UUID, _ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[index])
        save()
    }

    func game(id: UUID) -> Game? {
        games.first { $0.id == id }
    }

    func toggleFavorite(_ game: Game) {
        mutate(game.id) { $0.isFavorite.toggle() }
    }

    /// Removes the game's files and its web data.
    func delete(_ game: Game) async {
        await DataStores.wipe(for: game)
        try? FileManager.default.removeItem(at: Paths.folder(for: game))
        games.removeAll { $0.id == game.id }
        save()
        AppLog.log("deleted \(game.name)")
    }

    // MARK: - Import

    func importItems(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        var problems: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let game = try await Task.detached(priority: .userInitiated) {
                    try LibraryStore.buildGame(from: url)
                }.value
                games.append(game)
                save()
                AppLog.log("imported \(game.name) (\(game.engine.badge)) from \(url.lastPathComponent)")
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.log("import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        isImporting = false
        if !problems.isEmpty {
            importMessage = problems.joined(separator: "\n\n")
        }
    }

    nonisolated static func buildGame(from url: URL) throws -> Game {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw ImportError.missing }

        var game = Game(name: "", engine: .web, entry: "")
        let destination = Paths.folder(for: game)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            let ext = url.pathExtension.lowercased()
            var fallbackName = url.deletingPathExtension().lastPathComponent

            if isDirectory.boolValue {
                fallbackName = url.lastPathComponent
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try fm.copyItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
                }
            } else if ext == "zip" {
                try fm.unzipItem(at: url, to: destination)
            } else if ["html", "htm"].contains(ext) {
                try fm.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
            } else {
                throw ImportError.unsupported(ext)
            }

            GameScanner.tidy(destination)
            guard let found = GameScanner.detect(in: destination) else { throw ImportError.noGame }

            game.engine = found.engine
            game.entry = found.entry
            game.name = GameScanner.title(for: found, in: destination) ?? fallbackName
            if found.engine.isRPGMaker {
                game.orientation = .landscape
                game.gamepad = true
            } else {
                game.orientation = .auto
                game.gamepad = false
            }
            return game
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}
