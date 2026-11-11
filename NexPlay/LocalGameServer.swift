import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 for games that need a secure, cross-origin-isolated page (Godot 4 web exports
/// use SharedArrayBuffer for threads). http://127.0.0.1 is a secure context, and the COOP/COEP headers below make
/// the page cross-origin isolated; a custom URL scheme can't promise either.
///
/// Each game gets a fixed port derived from its id, so its origin (and the IndexedDB where Godot keeps user://
/// saves) stays the same between sessions. Only GET and HEAD are served, read-only, from the game folder.
final class LocalGameServer {
    private let rootPath: String
    private let queue = DispatchQueue(label: "nexplay.local-server", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    /// Optional replacement file for a path relative to the game folder (lowercased): mods.
    var overlay: ((String) -> String?)?
    /// Called with problems worth putting in the game log.
    var log: ((String) -> Void)?
    /// Files served from outside the game folder: URL path without the leading "/" -> absolute file path
    /// (the Godot web runtime under __godot/). Set before `start`.
    var virtualFiles: [String: String] = [:]
    /// Generated pages: URL path without the leading "/" -> content (the Godot launcher). Set before `start`.
    var virtualPages: [String: Data] = [:]

    init(root: URL) {
        let standard = root.standardizedFileURL.path
        rootPath = LocalGameServer.realPath(standard) ?? standard
    }

    /// A stable port in 20000...39999 for a game.
    static func port(for game: Game) -> UInt16 {
        var hash: UInt32 = 2_166_136_261
        for byte in game.id.uuidString.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return UInt16(20000 + hash % 20000)
    }

    /// Starts listening on `preferred`, or on one of the next 15 ports if it is taken. Returns the port, or nil.
    func start(preferred: UInt16) async -> UInt16? {
        for offset in 0..<16 {
            let candidate = preferred &+ UInt16(offset)
            if await listen(on: candidate) {
                port = candidate
                if offset > 0 { log?("local server: port \(preferred) busy, using \(candidate) (saves made on the usual port won't show this session)") }
                return candidate
            }
        }
        return nil
    }

    private func listen(on port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        let made: NWListener?
        if let bound = try? NWListener(using: parameters) {
            made = bound
        } else {
            let fallback = NWParameters.tcp
            fallback.acceptLocalOnly = true
            fallback.allowLocalEndpointReuse = true
            made = try? NWListener(using: fallback, on: nwPort)
        }
        guard let listener = made else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            HTTPConnection(connection: connection, server: self).start()
        }
        let ok: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        if ok {
            self.listener = listener
        } else {
            listener.cancel()
        }
        return ok
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Files

    fileprivate struct FileAnswer {
        let status: Int
        let headers: [String: String]
        let path: String?
        let range: ClosedRange<Int64>?
        let body: Data
    }

    fileprivate func answer(method: String, target: String, rangeHeader: String?) -> FileAnswer {
        guard method == "GET" || method == "HEAD" else { return failure(405) }
        var rawPath = target
        if let cut = rawPath.firstIndex(where: { $0 == "?" || $0 == "#" }) { rawPath = String(rawPath[..<cut]) }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let key = String(decoded.drop(while: { $0 == "/" }))
        if let page = virtualPages[key] {
            var headers = baseHeaders()
            headers["Content-Type"] = "text/html; charset=utf-8"
            headers["Content-Length"] = String(page.count)
            return FileAnswer(status: 200, headers: headers, path: nil, range: nil, body: method == "HEAD" ? Data() : page)
        }
        if let file = virtualFiles[key] {
            return fileAnswer(method: method, path: file, rangeHeader: rangeHeader)
        }
        guard var path = resolve(decoded) else { return failure(403) }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let index = resolve(decoded + "/index.html") else { return failure(403) }
            path = index
        }
        if let replaced = overlay?(relative(path).lowercased()), FileManager.default.fileExists(atPath: replaced) {
            path = replaced
        }
        return fileAnswer(method: method, path: path, rangeHeader: rangeHeader)
    }

    private func fileAnswer(method: String, path: String, rangeHeader: String?) -> FileAnswer {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else { return failure(404) }
        let size = sizeNumber.int64Value

        var headers = baseHeaders()
        headers["Content-Type"] = MIME.type(for: URL(fileURLWithPath: path))
        headers["Accept-Ranges"] = "bytes"
        var status = 200
        var range: ClosedRange<Int64>? = size > 0 ? 0...(size - 1) : nil
        if let rangeHeader, let parsed = LocalGameServer.parseRange(rangeHeader, fileSize: size) {
            status = 206
            range = parsed
            headers["Content-Range"] = "bytes \(parsed.lowerBound)-\(parsed.upperBound)/\(size)"
        }
        let length = range.map { $0.upperBound - $0.lowerBound + 1 } ?? 0
        headers["Content-Length"] = String(length)
        return FileAnswer(status: status, headers: headers, path: method == "HEAD" ? nil : path, range: range, body: Data())
    }

    private func baseHeaders() -> [String: String] {
        [
            "Cache-Control": "no-cache",
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "same-origin",
            "Access-Control-Allow-Origin": "*",
            "Connection": "close",
        ]
    }

    private func failure(_ status: Int) -> FileAnswer {
        let body = Data("\(status)".utf8)
        var headers = baseHeaders()
        headers["Content-Type"] = "text/plain"
        headers["Content-Length"] = String(body.count)
        return FileAnswer(status: status, headers: headers, path: nil, range: nil, body: body)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Same rules as NexSchemeHandler: no "..", case-insensitive fallback, symlinks must stay inside the folder.
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
                guard let real = LocalGameServer.realPath(next), real == rootPath || real.hasPrefix(rootPath + "/") else {
                    return nil
                }
            }
            path = next
        }
        return path
    }

    private func relative(_ path: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        var rel = String(path.dropFirst(rootPath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    private static func parseRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard header.lowercased().hasPrefix("bytes="), fileSize > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1].trimmingCharacters(in: .whitespaces)), suffix > 0 else { return nil }
            return max(0, fileSize - suffix)...(fileSize - 1)
        }
        guard let first = Int64(parts[0].trimmingCharacters(in: .whitespaces)), first < fileSize else { return nil }
        let last = Int64(parts[1].trimmingCharacters(in: .whitespaces)).map { min($0, fileSize - 1) } ?? (fileSize - 1)
        return last >= first ? first...last : nil
    }
}

/// One HTTP/1.1 request and its response, then the connection closes.
private final class HTTPConnection {
    private let connection: NWConnection
    private let server: LocalGameServer
    private var buffer = Data()
    private var handle: FileHandle?
    private var remaining: Int64 = 0
    private static let chunk = 512 * 1024
    private var keepAlive: HTTPConnection?

    init(connection: NWConnection, server: LocalGameServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || self.buffer.count > 65536 {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func handleRequest(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2 else { connection.cancel(); return }
        var range: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].lowercased() == "range" { range = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let answer = server.answer(method: first[0].uppercased(), target: first[1], rangeHeader: range)
        var text = "HTTP/1.1 \(answer.status) \(HTTPConnection.reason(answer.status))\r\n"
        for (key, value) in answer.headers { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        var head = Data(text.utf8)
        head.append(answer.body)
        if let path = answer.path, let range = answer.range, let file = FileHandle(forReadingAtPath: path) {
            try? file.seek(toOffset: UInt64(range.lowerBound))
            handle = file
            remaining = range.upperBound - range.lowerBound + 1
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.connection.cancel() } else { self?.sendNext() }
            })
        } else {
            connection.send(content: head, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }

    private func sendNext() {
        guard let handle, remaining > 0 else {
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        let count = Int(min(Int64(HTTPConnection.chunk), remaining))
        let data = (try? handle.read(upToCount: count)) ?? Data()
        if data.isEmpty {
            connection.cancel()
            return
        }
        remaining -= Int64(data.count)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.connection.cancel() } else { self?.sendNext() }
        })
    }

    private func finish() {
        try? handle?.close()
        handle = nil
        keepAlive = nil
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }
}
