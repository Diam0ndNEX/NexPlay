import Foundation
import WebKit

/// Serves a game's files at nexplay://<game-id>/<path>.
/// Each game has its own host, so every game gets its own web origin (separate localStorage, IndexedDB, cookies).
final class NexSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nexplay"

    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        var path = requestURL.path.removingPercentEncoding ?? requestURL.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        var fileURL = rootDirectory.appendingPathComponent(path).standardizedFileURL

        // Never serve anything outside the game's folder.
        guard fileURL.path.hasPrefix(rootDirectory.path) else {
            respondError(urlSchemeTask, url: requestURL, status: 403)
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL),
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        else {
            respondError(urlSchemeTask, url: requestURL, status: 404)
            return
        }
        defer { try? handle.close() }

        var headers: [String: String] = [
            "Content-Type": MIME.type(for: fileURL),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]

        var status = 200
        var start: Int64 = 0
        var length = size

        // Media elements ask for byte ranges; honour them so audio and video can seek.
        if let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
           let range = Self.parseRange(rangeHeader, fileSize: size) {
            status = 206
            start = range.lowerBound
            length = range.upperBound - range.lowerBound + 1
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        }
        headers["Content-Length"] = String(length)

        guard let response = HTTPURLResponse(url: requestURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }

        do {
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Requests are answered synchronously, so there is nothing to cancel.
    }

    private func respondError(_ task: WKURLSchemeTask, url: URL, status: Int) {
        let body = Data("\(status)".utf8)
        let headers = ["Content-Type": "text/plain", "Content-Length": String(body.count), "Access-Control-Allow-Origin": "*"]
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
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
