import Foundation
import WebKit

// The file lookup (case-insensitive names, symlink-safe root check, background reads) is adapted from
// Empo's MvmzFileServer. Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app
// (GPL-3.0-only with additional terms).

/// Serves a game's files at nexplay://<game-id>/<path>.
/// Each game has its own host, so every game gets its own web origin (separate localStorage, IndexedDB, cookies).
final class NexSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nexplay"

    private struct Answer {
        let response: HTTPURLResponse
        let body: Data
    }

    private let rootPath: String
    private let queue = DispatchQueue(label: "nexplay.files", qos: .userInitiated)
    /// Tasks WebKit has stopped. Answering a stopped task throws, so they are skipped. Main thread only.
    private let stopped = NSHashTable<AnyObject>.weakObjects()

    init(rootDirectory: URL) {
        let standard = rootDirectory.standardizedFileURL.path
        rootPath = NexSchemeHandler.realPath(standard) ?? standard
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let range = request.value(forHTTPHeaderField: "Range")

        queue.async { [weak self] in
            guard let self else { return }
            let answer = self.answer(url: url, method: method, range: range)
            DispatchQueue.main.async {
                if self.stopped.contains(urlSchemeTask as AnyObject) { return }
                urlSchemeTask.didReceive(answer.response)
                if !answer.body.isEmpty { urlSchemeTask.didReceive(answer.body) }
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopped.add(urlSchemeTask as AnyObject)
    }

    // MARK: - Lookup

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The file a URL path names, or nil when it leaves the game folder.
    /// Games made on Windows often use other capitals than the file on disk has, and iOS tells them apart,
    /// so a name that is missing is looked up again without case. Symlinks must stay inside the game folder.
    private func resolve(_ urlPath: String) -> String? {
        let fm = FileManager.default
        var path = rootPath
        for part in urlPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." || part == ".." { return nil }
            var next = (path as NSString).appendingPathComponent(part)
            if !fm.fileExists(atPath: next),
               let names = try? fm.contentsOfDirectory(atPath: path),
               let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                next = (path as NSString).appendingPathComponent(match)
            }
            if fm.fileExists(atPath: next) {
                guard let real = NexSchemeHandler.realPath(next),
                      real == rootPath || real.hasPrefix(rootPath + "/")
                else { return nil }
            }
            path = next
        }
        return path
    }

    // MARK: - Answers

    private func answer(url: URL, method: String, range rangeHeader: String?) -> Answer {
        var urlPath = url.path
        if urlPath.isEmpty || urlPath == "/" { urlPath = "/index.html" }
        guard var path = resolve(urlPath) else { return failure(url, 403) }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let index = resolve(urlPath + "/index.html") else { return failure(url, 403) }
            path = index
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        else { return failure(url, 404) }

        let size = Int64(data.count)
        var headers: [String: String] = [
            "Content-Type": MIME.type(for: fileURL),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]

        var status = 200
        var body = data
        // Media elements ask for byte ranges; honour them so audio and video can seek.
        if let rangeHeader, let range = NexSchemeHandler.parseRange(rangeHeader, fileSize: size) {
            status = 206
            body = data.subdata(in: Int(range.lowerBound)..<(Int(range.upperBound) + 1))
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        }
        headers["Content-Length"] = String(body.count)
        if method == "HEAD" { body = Data() }

        // The status code and header values are always valid, so this initialiser cannot return nil.
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return Answer(response: response, body: body)
    }

    private func failure(_ url: URL, _ status: Int) -> Answer {
        let body = Data("\(status)".utf8)
        let headers = [
            "Content-Type": "text/plain",
            "Content-Length": String(body.count),
            "Access-Control-Allow-Origin": "*",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return Answer(response: response, body: body)
    }

    /// Parses "bytes=start-end", "bytes=start-" and "bytes=-suffix".
    private static func parseRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard header.lowercased().hasPrefix("bytes="), fileSize > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return max(0, fileSize - suffix)...(fileSize - 1)
        }
        guard let first = Int64(parts[0]), first < fileSize else { return nil }
        let last = Int64(parts[1]).map { min($0, fileSize - 1) } ?? (fileSize - 1)
        return last >= first ? first...last : nil
    }
}
