import Foundation
import WebKit

// The file lookup (case-insensitive names, symlink-safe root check, background reads) and the write methods
// (PUT, DELETE, MKCOL, MOVE, directory listing, kind and mtime headers) are adapted from Empo's MvmzFileServer.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app and
// https://github.com/mateo-m/mvmz-apple-mobile (GPL-3.0-only with additional terms).

/// Serves a game's files at nexplay://<game-id>/<path>.
/// Each game has its own host, so every game gets its own web origin (separate localStorage, IndexedDB, cookies).
///
/// Besides GET it answers what the NW.js shim needs to keep saves as files:
/// HEAD (stat), PUT (write, atomic), DELETE, MKCOL (mkdir), MOVE (rename, header `Destination`),
/// and GET with header `X-Nex-List: 1` on a folder (JSON array of names).
/// Answers carry `X-Nex-Kind` (`file`/`directory`) and `X-Nex-Mtime` (ms since 1970).
/// The game folder and the folder of the entry page can't be written, deleted or moved.
final class NexSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "nexplay"

    private struct Answer {
        let response: HTTPURLResponse
        let body: Data
    }

    private struct Request {
        let url: URL
        let method: String
        let range: String?
        let list: Bool
        let destination: String?
        let body: Data?
    }

    private let rootPath: String
    private let protectedPaths: Set<String>
    private let queue = DispatchQueue(label: "nexplay.files", qos: .userInitiated)
    /// Tasks WebKit has stopped. Answering a stopped task throws, so they are skipped. Main thread only.
    private let stopped = NSHashTable<AnyObject>.weakObjects()
    /// Optional replacement content for a path relative to the game folder (lowercased), for example a generated
    /// js/plugins.js. Called on the file queue.
    var fileOverride: ((String) -> Data?)?

    init(rootDirectory: URL, protectedDirectories: [URL] = []) {
        let standard = rootDirectory.standardizedFileURL.path
        let root = NexSchemeHandler.realPath(standard) ?? standard
        rootPath = root
        var protected: Set<String> = [root]
        for dir in protectedDirectories {
            let path = dir.standardizedFileURL.path
            protected.insert(NexSchemeHandler.realPath(path) ?? path)
        }
        protectedPaths = protected
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let info = Request(
            url: url,
            method: (request.httpMethod ?? "GET").uppercased(),
            range: request.value(forHTTPHeaderField: "Range"),
            list: request.value(forHTTPHeaderField: "X-Nex-List") == "1",
            destination: request.value(forHTTPHeaderField: "Destination"),
            body: NexSchemeHandler.body(of: request)
        )

        queue.async { [weak self] in
            guard let self else { return }
            let answer = self.answer(info)
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

    /// Request bodies arrive in httpBody, or as a stream for larger bodies.
    private static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        var data = Data()
        stream.open()
        defer { stream.close() }
        let size = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
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

    /// True for the game folder and the entry folder, which must never be changed as a whole.
    private func isProtected(_ path: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        let real = NexSchemeHandler.realPath(standard) ?? standard
        return protectedPaths.contains(real) || protectedPaths.contains(standard)
    }

    private func relative(_ path: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        var rel = String(path.dropFirst(rootPath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    // MARK: - Answers

    private func answer(_ request: Request) -> Answer {
        let url = request.url
        let urlPath = url.path
        guard let path = resolve(urlPath) else { return failure(url, 403) }

        switch request.method {
        case "GET", "HEAD":
            return read(request, path: path)
        case "PUT":
            return put(request, path: path)
        case "MKCOL":
            if isProtected(path) { return failure(url, 403) }
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                return empty(url, 204)
            } catch {
                return failure(url, 500, error.localizedDescription)
            }
        case "DELETE":
            if isProtected(path) { return failure(url, 403) }
            guard FileManager.default.fileExists(atPath: path) else { return failure(url, 404) }
            do {
                try FileManager.default.removeItem(atPath: path)
                return empty(url, 204)
            } catch {
                return failure(url, 500, error.localizedDescription)
            }
        case "MOVE":
            return move(request, path: path)
        default:
            return failure(url, 405)
        }
    }

    private func put(_ request: Request, path: String) -> Answer {
        let url = request.url
        if isProtected(path) { return failure(url, 403) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return failure(url, 409, "is a directory")
        }
        do {
            let folder = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try (request.body ?? Data()).write(to: URL(fileURLWithPath: path), options: .atomic)
            return empty(url, 204)
        } catch {
            return failure(url, 500, error.localizedDescription)
        }
    }

    private func move(_ request: Request, path: String) -> Answer {
        let url = request.url
        guard let destinationString = request.destination,
              let destinationURL = URL(string: destinationString),
              let target = resolve(destinationURL.path)
        else { return failure(url, 403) }
        if isProtected(path) || isProtected(target) { return failure(url, 403) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return failure(url, 404) }
        do {
            // Node's rename replaces the file at the destination.
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: path, toPath: target)
            return empty(url, 204)
        } catch {
            return failure(url, 500, error.localizedDescription)
        }
    }

    private func read(_ request: Request, path startPath: String) -> Answer {
        let url = request.url
        let fm = FileManager.default
        var path = startPath
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)

        if exists && isDirectory.boolValue {
            // HEAD (stat) and listings describe the folder itself; a plain GET serves its index.html.
            if request.method == "HEAD" || request.list {
                var headers = baseHeaders()
                headers["X-Nex-Kind"] = "directory"
                headers["X-Nex-Mtime"] = mtime(of: path)
                var body = Data()
                if request.list {
                    let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
                    body = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
                    headers["Content-Type"] = "application/json; charset=utf-8"
                }
                headers["Content-Length"] = String(body.count)
                if request.method == "HEAD" { body = Data() }
                return make(url, 200, headers, body)
            }
            guard let index = resolve(url.path + "/index.html") else { return failure(url, 403) }
            path = index
        }

        let fileURL = URL(fileURLWithPath: path)
        let data: Data
        if let replaced = fileOverride?(relative(path).lowercased()) {
            data = replaced
        } else {
            guard fm.fileExists(atPath: path),
                  let contents = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else { return failure(url, 404) }
            data = contents
        }

        let size = Int64(data.count)
        var headers = baseHeaders()
        headers["Content-Type"] = MIME.type(for: fileURL)
        headers["Accept-Ranges"] = "bytes"
        headers["X-Nex-Kind"] = "file"
        headers["X-Nex-Mtime"] = mtime(of: path)

        var status = 200
        var body = data
        // Media elements ask for byte ranges; honour them so audio and video can seek.
        if let rangeHeader = request.range, let range = NexSchemeHandler.parseRange(rangeHeader, fileSize: size) {
            status = 206
            body = data.subdata(in: Int(range.lowerBound)..<(Int(range.upperBound) + 1))
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        }
        headers["Content-Length"] = String(body.count)
        if request.method == "HEAD" { body = Data() }
        return make(url, status, headers, body)
    }

    private func mtime(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return String(Int64(date.timeIntervalSince1970 * 1000))
    }

    private func baseHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "X-Nex-Kind, X-Nex-Mtime, Content-Length",
            "Cache-Control": "no-cache",
        ]
    }

    private func make(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data) -> Answer {
        // The status code and header values are always valid, so this initialiser cannot return nil.
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return Answer(response: response, body: body)
    }

    private func empty(_ url: URL, _ status: Int) -> Answer {
        var headers = baseHeaders()
        headers["Content-Length"] = "0"
        return make(url, status, headers, Data())
    }

    private func failure(_ url: URL, _ status: Int, _ message: String? = nil) -> Answer {
        let body = Data((message.map { "\(status) \($0)" } ?? "\(status)").utf8)
        var headers = baseHeaders()
        headers["Content-Type"] = "text/plain"
        headers["Content-Length"] = String(body.count)
        return make(url, status, headers, body)
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
