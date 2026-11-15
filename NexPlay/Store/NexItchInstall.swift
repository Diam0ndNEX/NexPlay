import Foundation
import UIKit

// 8.5.0: installing an itch.io upload. The file downloads into the import staging folder with progress on the import
// card (Cancel cancels it), then goes through NexPlay's own import pipeline (stage, detect, install), so every engine is
// found the usual way: HTML5, Ren'Py, Twine, RPG Maker, Godot and Flash games use NexPlay's runtimes and real Windows
// programs become PC games. A failed or cancelled download leaves nothing behind (the staging folder is removed, and
// ImportPipeline.sweepStaging clears it at the next launch if NexPlay was closed mid-download).

/// Where an import came from (a store download): kept on the game so an update replaces it in place.
struct NexImportOrigin {
    var source: GameSource
    var storeID: String
    var title: String
    var author: String?
    /// The store's cover art, already downloaded (becomes the game's cover).
    var coverData: Data?

    /// A new game: the store's title and author.
    func apply(to game: inout Game) {
        game.source = source
        game.storeID = storeID
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { game.name = name }
        if game.developer == nil, let author, !author.isEmpty { game.developer = author }
    }

    /// Saves the store's cover as the game's cover (an update keeps a cover the owner picked).
    func applyCover(to game: Game, replace: Bool) {
        guard let coverData, let image = UIImage(data: coverData) else { return }
        if !replace && CoverStore.hasCustomCover(game) { return }
        CoverStore.setCover(image, for: game)
    }
}

enum NexItchInstall {
    /// A bare .exe or .msi that libarchive can't open (not a self-extractor) is put in a folder of its own, so the
    /// pipeline imports it as a Windows program or installer (or a one-file Godot game).
    static func prepare(_ file: URL, title: String) throws -> URL {
        let ext = file.pathExtension.lowercased()
        guard ext == "exe" || ext == "msi" else { return file }
        if ext == "exe" && isReadableArchive(file) { return file }
        let safe = Paths.safeName(title).isEmpty ? "Game" : Paths.safeName(title)
        let folder = file.deletingLastPathComponent().appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: target)
        return folder
    }

    /// True when libarchive reads a first entry (a self-extracting archive).
    static func isReadableArchive(_ url: URL) -> Bool {
        guard let reader = archive_read_new() else { return false }
        defer { _ = archive_read_free(reader) }
        _ = archive_read_support_filter_all(reader)
        _ = archive_read_support_format_all(reader)
        let opened = url.path.withCString { archive_read_open_filename(reader, $0, 1 << 16) }
        guard opened == 0 else { return false }
        var entry: OpaquePointer?
        return archive_read_next_header(reader, &entry) == 0
    }

    static func freeSpace() -> Int64? {
        let values = try? Paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func coverData(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("NexPlay", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        let data = result.0
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), data.count < 8 << 20, UIImage(data: data) != nil else { return nil }
        return data
    }
}

extension LibraryStore {
    /// The installed game that came from this itch.io game, if any.
    func itchGame(_ id: Int) -> Game? {
        games.first { $0.source == .itch && $0.storeID == String(id) }
    }

    /// Downloads `upload` of `game` and imports it (8.5.0).
    func importFromItch(_ game: NexItchGame, upload: NexItchUpload) async {
        guard !isImporting else {
            importMessage = "Another import is running. Wait for it to finish, then try again."
            return
        }
        // The archive and the unpacked game sit side by side for a moment.
        if upload.size > 0, let free = NexItchInstall.freeSpace(), free < upload.size * 3 + 200_000_000 {
            let needed = ByteCountFormatter.string(fromByteCount: upload.size * 3 + 200_000_000, countStyle: .file)
            importMessage = "Not enough free space for \(game.title): it needs about \(needed). Free some space, then try again."
            return
        }
        let request: URLRequest
        do {
            request = try await NexItchAPI.shared.downloadRequest(upload: upload.id, downloadKey: game.downloadKeyID)
        } catch {
            importMessage = error.localizedDescription
            return
        }
        isImporting = true
        importProgress = ImportProgress(stage: .downloading, detail: "itch.io", fraction: nil, item: 1, itemCount: 1,
                                        itemName: game.title)
        let folder = ImportPipeline.staging.appendingPathComponent("itch-\(UUID().uuidString)", isDirectory: true)
        let progress: (Int64, Int64, String) -> Void = { [weak self] done, total, name in
            Task { @MainActor in
                guard let self, self.isImporting, self.importProgress.stage == .downloading else { return }
                let size = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
                let whole = total > 0 ? total : upload.size
                if whole > 0 {
                    let all = ByteCountFormatter.string(fromByteCount: whole, countStyle: .file)
                    self.importProgress.detail = "\(name) · \(size) of \(all)"
                    self.importProgress.fraction = min(1, Double(done) / Double(whole))
                } else {
                    self.importProgress.detail = "\(name) · \(size)"
                }
            }
        }
        AppLog.log("itch.io: downloading game \(game.id) upload \(upload.id) (\(upload.kindLabel))")
        async let cover = NexItchInstall.coverData(game.cover)
        do {
            let downloaded = try await LinkDownloader.download(request: request, name: upload.filename, into: folder,
                                                               progress: progress) { [weak self] task in
                Task { @MainActor in self?.downloadTask = task }
            }
            downloadTask = nil
            let file = try NexItchInstall.prepare(downloaded, title: game.title)
            let art = await cover
            isImporting = false
            AppLog.log("itch.io: downloaded \(downloaded.lastPathComponent)")
            let origin = NexImportOrigin(source: .itch, storeID: game.storeID, title: game.title, author: game.author,
                                         coverData: art)
            await importItems([file], origin: origin)
        } catch {
            downloadTask = nil
            _ = await cover
            isImporting = false
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                importMessage = "The download of \(game.title) was cancelled. Nothing was installed."
                AppLog.log("itch.io: download cancelled")
            } else {
                importMessage = "Couldn't download \(game.title): \(error.localizedDescription)"
                AppLog.log("itch.io: download failed: \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
