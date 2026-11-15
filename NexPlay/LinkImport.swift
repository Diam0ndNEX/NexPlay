import Foundation

/// Imports a game from a direct download link: downloads it with progress on the import card, then imports the
/// file like one picked in Files. Pages (HTML that is not a game file) are refused with a hint.
enum LinkError: LocalizedError {
    case badLink
    case webPage
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badLink:
            return "That isn't a web link. Paste a link that starts with https://."
        case .webPage:
            return "The link opens a web page, not a file. Copy the direct download link (the one that starts the download in Safari)."
        case .status(let code):
            return "The server answered \(code). The link may have expired or need a login."
        }
    }
}

extension LibraryStore {
    /// Downloads `text` (a URL) and imports the file.
    func importFromLink(_ text: String) async {
        guard !isImporting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            importMessage = LinkError.badLink.errorDescription
            return
        }
        isImporting = true
        importProgress = ImportProgress(stage: .downloading, detail: url.host ?? "", fraction: nil, item: 1, itemCount: 1,
                                        itemName: url.lastPathComponent)
        let progress: (Int64, Int64, String) -> Void = { [weak self] done, total, name in
            Task { @MainActor in
                guard let self, self.isImporting else { return }
                let size = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
                if total > 0 {
                    let whole = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    self.importProgress.detail = "\(name) · \(size) of \(whole)"
                    self.importProgress.fraction = Double(done) / Double(total)
                } else {
                    self.importProgress.detail = "\(name) · \(size)"
                }
            }
        }
        do {
            let file = try await LinkDownloader.download(url, progress: progress) { [weak self] task in
                Task { @MainActor in self?.downloadTask = task }
            }
            downloadTask = nil
            isImporting = false
            AppLog.log("downloaded \(file.lastPathComponent) from \(url.host ?? "a link")")
            await importItems([file])
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        } catch {
            downloadTask = nil
            isImporting = false
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                importMessage = "The download was cancelled."
            } else {
                importMessage = "Couldn't download the game: \(error.localizedDescription)"
                AppLog.log("download failed for \(url.host ?? "a link"): \(error.localizedDescription)")
            }
        }
    }
}

/// One download with progress, into its own temporary folder, keeping the server's file name.
final class LinkDownloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Int64, Int64, String) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var name: String
    private var result: Result<URL, Error>?
    /// 8.5.0: where the file goes (nil = a new folder in the temporary directory).
    private let folder: URL?

    private init(name: String, folder: URL?, progress: @escaping (Int64, Int64, String) -> Void) {
        self.name = name
        self.folder = folder
        self.progress = progress
    }

    static func download(_ url: URL, progress: @escaping (Int64, Int64, String) -> Void,
                         started: @escaping (URLSessionTask) -> Void) async throws -> URL {
        try await download(request: URLRequest(url: url), name: url.lastPathComponent, into: nil,
                           progress: progress, started: started)
    }

    /// 8.5.0 (itch.io): a prepared request (its headers are sent), a fallback file name and the target folder.
    static func download(request: URLRequest, name: String, into folder: URL?,
                         progress: @escaping (Int64, Int64, String) -> Void,
                         started: @escaping (URLSessionTask) -> Void) async throws -> URL {
        let delegate = LinkDownloader(name: name.isEmpty ? "download" : name, folder: folder, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            delegate.continuation = continuation
            let task = session.downloadTask(with: request)
            started(task)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty { name = suggested }
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0), name)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed when this method returns, so it is moved now.
        do {
            let response = downloadTask.response as? HTTPURLResponse
            if let code = response?.statusCode, !(200...299).contains(code) { throw LinkError.status(code) }
            var fileName = Paths.safeName(downloadTask.response?.suggestedFilename ?? name)
            let mime = (response?.mimeType ?? "").lowercased()
            let ext = (fileName as NSString).pathExtension.lowercased()
            if mime.hasPrefix("text/html") && !["html", "htm"].contains(ext) { throw LinkError.webPage }
            if ext.isEmpty, mime.contains("zip") { fileName += ".zip" }
            let target = (self.folder ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("LinkImport-\(UUID().uuidString)", isDirectory: true))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let file = target.appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: location, to: file)
            result = .success(file)
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<URL, Error>
        if let error {
            outcome = .failure(error)
        } else {
            outcome = result ?? .failure(URLError(.cannotCreateFile))
        }
        continuation?.resume(with: outcome)
        continuation = nil
    }
}
