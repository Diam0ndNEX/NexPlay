import Foundation
import Security

// 8.5.0: itch.io for NexPlay. Sign in with an API key, read the account's games (purchases and claimed bundles are its
// download keys, plus its collections), search, a game's uploads and an upload's download request.
// The calls are the ones BCD/Madeira's SwiftItch makes (itch.io server API v2, as the itch app does through go-itchio):
// GET /profile, /profile/owned-keys, /profile/collections, /collections/<id>/collection-games, /search/games, /games/<id>,
// /games/<id>/uploads?download_key_id=, /uploads/<id>/download. Rewritten for NexPlay because SwiftItch keeps only Windows
// games and is compiled only with the Windows engine: this client works in every build and keeps every kind of upload
// (HTML5, Flash, Windows, Linux, macOS, Android). Approach adapted from SwiftItch's ItchAPI.swift (Madeira by
// ft7t8drgwf-wq, modified by BCD (thebcd69); GPL-3.0-or-later). Types are prefixed NexItch so they never clash with BCD's.
// The API key lives only in the Keychain (service NexPlayItchKey, this device only) and is never logged.

enum NexItchError: LocalizedError {
    case signedOut
    case badKey
    case http(Int)
    case invalid(String)
    case keychain
    case noUpload

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to itch.io first (Settings › Accounts › itch.io)."
        case .badKey: return "itch.io didn't accept this API key. Make a new one on itch.io (Settings › API keys) and paste it again."
        case .http(let code): return "itch.io answered with an error (HTTP \(code)). Try again later."
        case .invalid(let what): return "itch.io sent something NexPlay couldn't read (\(what))."
        case .keychain: return "NexPlay couldn't keep the key in the Keychain. Try again."
        case .noUpload: return "This game has no download NexPlay can install."
        }
    }
}

/// A game in the account's itch.io library, or one found by search or a link.
struct NexItchGame: Codable, Identifiable, Hashable {
    /// itch.io's game id.
    var id: Int
    var title: String
    var cover: URL?
    /// The download key that proves ownership; 0 = none (free game, or one from a collection or search).
    var downloadKeyID: Int
    var url: URL?
    var author: String?
    var shortText: String?
    /// "web", "flash", "windows", "macos", "linux", "android".
    var platforms: [String]
    var minPrice: Int?

    var owned: Bool { downloadKeyID != 0 }
    var storeID: String { String(id) }

    var platformSummary: String {
        let names: [(String, String)] = [("web", "HTML5"), ("flash", "Flash"), ("windows", "Windows"), ("linux", "Linux"),
                                         ("macos", "macOS"), ("android", "Android")]
        let list = names.filter { platforms.contains($0.0) }.map { $0.1 }
        return list.isEmpty ? "Downloads" : list.joined(separator: " · ")
    }
}

/// One file on a game's page.
struct NexItchUpload: Identifiable, Hashable {
    var id: Int
    var filename: String
    var displayName: String
    var size: Int64
    /// "default", "html", "flash", "soundtrack", "book", "mod", ...
    var type: String
    var platforms: Set<String>
    var demo: Bool
    var preorder: Bool
    var buildID: Int
    var version: String

    var name: String { displayName.isEmpty ? filename : displayName }

    /// What NexPlay would run it as, for the upload list.
    var kindLabel: String {
        if type == "html" { return "HTML5" }
        if type == "flash" || filename.lowercased().hasSuffix(".swf") { return "Flash" }
        if platforms.contains("windows") { return "Windows" }
        if platforms.contains("linux") { return "Linux" }
        if platforms.contains("macos") { return "macOS" }
        if platforms.contains("android") { return "Android" }
        if NexItchFormat.extraTypes.contains(type) { return type.replacingOccurrences(of: "_", with: " ").capitalized }
        return "Game files"
    }

    var symbol: String {
        switch kindLabel {
        case "HTML5": return "globe"
        case "Flash": return "bolt.fill"
        case "Windows": return "pc"
        case "Linux", "macOS": return "desktopcomputer"
        case "Android": return "iphone"
        case "Game files": return "doc.zipper"
        default: return "music.note.list"
        }
    }

    /// Lower is better; nil = not a game (soundtrack, book, preorder...).
    var rank: Int? {
        if preorder || NexItchFormat.extraTypes.contains(type) { return nil }
        var value: Int
        if type == "html" {
            value = 0
        } else if type == "flash" || filename.lowercased().hasSuffix(".swf") {
            value = 1
        } else if platforms.contains("windows") {
            // Ren'Py, RPG Maker, Godot and Twine PC builds land here too: the import finds the engine inside and
            // uses NexPlay's own runtime; only real Windows programs become PC games.
            value = 2
        } else if platforms.isEmpty {
            value = 3
        } else if platforms.contains("linux") {
            value = 4
        } else if platforms.contains("macos") {
            value = 5
        } else if platforms.contains("android") {
            value = 6
        } else {
            value = 7
        }
        if demo { value += 10 }
        return value
    }

    var recommendedNote: String {
        switch kindLabel {
        case "HTML5": return "Runs in NexPlay's web player."
        case "Flash": return "Runs with Ruffle."
        case "Windows": return "NexPlay looks inside: Ren'Py, RPG Maker, Godot and HTML5 games use NexPlay's runtimes, other programs run as PC games."
        case "Linux", "macOS": return "Works when it holds a Ren'Py, RPG Maker, Godot or HTML5 game."
        case "Android": return "Android packages usually can't run in NexPlay."
        default: return "NexPlay looks for a game inside."
        }
    }
}

enum NexItchFormat {
    /// Upload types that are not the game itself.
    static let extraTypes: Set<String> = ["soundtrack", "book", "video", "documentation", "mod", "audio_assets",
                                          "graphical_assets", "sourcecode", "other_assets"]

    /// JSON keys arrive in snake_case (camelCase from some endpoints): both are read.
    static func value(_ object: [String: Any], _ snake: String) -> Any? {
        if let value = object[snake] { return value }
        var camel = ""
        var upper = false
        for c in snake {
            if c == "_" { upper = true; continue }
            camel += upper ? c.uppercased() : String(c)
            upper = false
        }
        return object[camel]
    }

    static func int(_ object: [String: Any], _ key: String) -> Int? {
        switch value(object, key) {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func string(_ object: [String: Any], _ key: String) -> String? { value(object, key) as? String }

    static func bool(_ object: [String: Any], _ key: String) -> Bool {
        if let n = value(object, key) as? NSNumber { return n.boolValue }
        return false
    }

    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    /// A game's or upload's platforms: `platforms` (API v2) or `p_*` traits (older answers), plus web/Flash from its type.
    static func platforms(_ object: [String: Any]) -> Set<String> {
        var found = Set<String>()
        let names = ["windows": "windows", "osx": "macos", "linux": "linux", "android": "android"]
        if let dict = value(object, "platforms") as? [String: Any] {
            for key in dict.keys { if let name = names[key] { found.insert(name) } }
        }
        let traits = value(object, "traits") as? [String] ?? []
        for (key, name) in names where traits.contains("p_" + key) || bool(object, "p_" + key) { found.insert(name) }
        switch string(object, "type") ?? "" {
        case "html": found.insert("web")
        case "flash": found.insert("flash")
        default: break
        }
        return found
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count < 64 << 20, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexItchError.invalid("json")
        }
        if let errors = object["errors"] as? [String], !errors.isEmpty {
            if errors.contains(where: { $0.lowercased().contains("invalid key") || $0.lowercased().contains("api key") }) {
                throw NexItchError.badKey
            }
            throw NexItchError.invalid("error")
        }
        return object
    }

    /// A game object; only games (not tools, assets or books) are kept.
    static func game(_ object: [String: Any], id fallback: Int? = nil, key: Int = 0) -> NexItchGame? {
        guard let id = int(object, "id") ?? fallback else { return nil }
        let kind = string(object, "classification") ?? "game"
        guard kind == "game" else { return nil }
        let title = (string(object, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = value(object, "user") as? [String: Any]
        let author = user.flatMap { u in string(u, "display_name").flatMap { $0.isEmpty ? nil : $0 } ?? string(u, "username") }
        return NexItchGame(id: id, title: title.isEmpty ? "itch.io game \(id)" : title,
                           cover: (string(object, "still_cover_url") ?? string(object, "cover_url")).flatMap(httpsURL),
                           downloadKeyID: key, url: string(object, "url").flatMap(httpsURL), author: author,
                           shortText: string(object, "short_text"), platforms: Array(platforms(object)).sorted(),
                           minPrice: int(object, "min_price"))
    }

    static func uploads(_ object: [String: Any]) -> [NexItchUpload] {
        (value(object, "uploads") as? [[String: Any]] ?? []).compactMap { upload in
            guard let id = int(upload, "id") else { return nil }
            let traits = value(upload, "traits") as? [String] ?? []
            let build = value(upload, "build") as? [String: Any]
            return NexItchUpload(id: id, filename: string(upload, "filename") ?? "",
                                 displayName: string(upload, "display_name") ?? "",
                                 size: Int64(int(upload, "size") ?? 0), type: string(upload, "type") ?? "default",
                                 platforms: platforms(upload),
                                 demo: bool(upload, "demo") || traits.contains("demo"),
                                 preorder: bool(upload, "preorder") || traits.contains("preorder"),
                                 buildID: int(upload, "build_id") ?? build.flatMap { int($0, "id") } ?? 0,
                                 version: build.flatMap { string($0, "user_version") } ?? string(upload, "updated_at") ?? "")
        }
    }

    /// Uploads best-first: games by rank (HTML5, Flash, Windows, unmarked, Linux, macOS, Android; demos after), bigger
    /// first on a tie; soundtracks, books and the like last.
    static func sorted(_ uploads: [NexItchUpload]) -> [NexItchUpload] {
        uploads.sorted { a, b in
            let ra = a.rank ?? 1000
            let rb = b.rank ?? 1000
            if ra != rb { return ra < rb }
            return a.size > b.size
        }
    }

    /// The upload NexPlay installs by default; nil when nothing is a game.
    static func choose(_ uploads: [NexItchUpload]) -> NexItchUpload? {
        sorted(uploads).first { $0.rank != nil }
    }

    /// The itch.io game page a pasted link names (https://<author>.itch.io/<game>), as the address of its data.json.
    static func dataURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw), let host = components.host?.lowercased(),
              host.hasSuffix(".itch.io"), host != "api.itch.io", host != "www.itch.io",
              host.split(separator: ".").count == 3 else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let slug = parts.first, !slug.isEmpty,
              slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        components.scheme = "https"
        components.host = host
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/" + slug + "/data.json"
        return components.url
    }

    /// A game page's id from its `itch:path` meta tag ("games/<id>").
    static func pageGameID(_ html: String) -> Int? {
        guard let tag = html.range(of: "name=\"itch:path\"") else { return nil }
        let rest = html[tag.upperBound...].prefix(200)
        guard let start = rest.range(of: "games/") else { return nil }
        return Int(rest[start.upperBound...].prefix { $0.isNumber })
    }
}

/// The API key in the Keychain: service NexPlayItchKey, this device only, readable while unlocked. Never logged.
enum NexItchKeychain {
    private static let service = "NexPlayItchKey"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                   kSecAttrSynchronizable as String: false]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

actor NexItchAPI {
    static let shared = NexItchAPI()
    static let server = URL(string: "https://api.itch.io")!
    /// Where an API key is made.
    static let keysPage = URL(string: "https://itch.io/user/settings/api-keys")!

    private var key: String? = NexItchKeychain.load()

    var signedIn: Bool { key != nil }

    /// The key is kept only once itch.io answers /profile with it. Returns the account's name.
    func signIn(key raw: String) async throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count < 256, !candidate.contains(where: { $0.isWhitespace }) else {
            throw NexItchError.badKey
        }
        let name = try await profileName(key: candidate)
        guard NexItchKeychain.save(candidate) else { throw NexItchError.keychain }
        key = candidate
        return name
    }

    func signOut() {
        NexItchKeychain.delete()
        key = nil
    }

    func accountName() async throws -> String {
        guard let key else { throw NexItchError.signedOut }
        return try await profileName(key: key)
    }

    private func profileName(key: String) async throws -> String {
        let object = try await get("profile", key: key)
        guard let user = NexItchFormat.value(object, "user") as? [String: Any] else { throw NexItchError.invalid("profile") }
        return NexItchFormat.string(user, "display_name").flatMap { $0.isEmpty ? nil : $0 }
            ?? NexItchFormat.string(user, "username") ?? "itch.io account"
    }

    /// Every game the account owns (purchases, claimed bundles and free games it claimed): at most 100 pages of 50.
    func ownedGames() async throws -> [NexItchGame] {
        guard let key else { throw NexItchError.signedOut }
        var all: [NexItchGame] = []
        var seen = Set<Int>()
        for page in 1...100 {
            try Task.checkCancellation()
            let object = try await get("profile/owned-keys", query: [URLQueryItem(name: "page", value: String(page)),
                                                                     URLQueryItem(name: "per_page", value: "50")], key: key)
            let keys = NexItchFormat.value(object, "owned_keys") as? [[String: Any]] ?? []
            for entry in keys {
                guard let keyID = NexItchFormat.int(entry, "id"),
                      let gameObject = NexItchFormat.value(entry, "game") as? [String: Any],
                      let game = NexItchFormat.game(gameObject, id: NexItchFormat.int(entry, "game_id"), key: keyID),
                      seen.insert(game.id).inserted else { continue }
                all.append(game)
            }
            if keys.count < 50 { break }
        }
        return all
    }

    /// The games in the account's collections (at most 20 collections of 20 pages); a collection that fails is skipped.
    func collectionGames() async throws -> [NexItchGame] {
        guard let key else { throw NexItchError.signedOut }
        let list = NexItchFormat.value(try await get("profile/collections", key: key), "collections") as? [[String: Any]] ?? []
        let ids = list.compactMap { NexItchFormat.int($0, "id") }
        var all: [NexItchGame] = []
        var seen = Set<Int>()
        for collection in ids.prefix(20) {
            for page in 1...20 {
                try Task.checkCancellation()
                guard let object = try? await get("collections/\(collection)/collection-games",
                                                  query: [URLQueryItem(name: "page", value: String(page))], key: key) else { break }
                let entries = NexItchFormat.value(object, "collection_games") as? [[String: Any]] ?? []
                for entry in entries {
                    guard let gameObject = NexItchFormat.value(entry, "game") as? [String: Any],
                          let game = NexItchFormat.game(gameObject, id: NexItchFormat.int(entry, "game_id")),
                          seen.insert(game.id).inserted else { continue }
                    all.append(game)
                }
                let perPage = NexItchFormat.int(object, "per_page") ?? 0
                if entries.isEmpty || entries.count < perPage { break }
            }
        }
        return all
    }

    func search(_ query: String) async throws -> [NexItchGame] {
        guard let key else { throw NexItchError.signedOut }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let object = try await get("search/games", query: [URLQueryItem(name: "query", value: String(text.prefix(200)))], key: key)
        return (NexItchFormat.value(object, "games") as? [[String: Any]] ?? []).compactMap { NexItchFormat.game($0) }
    }

    /// The game a pasted itch.io page link names: the page's data.json (or its itch:path tag) gives the id.
    func game(link: String) async throws -> NexItchGame {
        guard let key else { throw NexItchError.signedOut }
        guard let address = NexItchFormat.dataURL(link) else { throw NexItchError.invalid("link") }
        var id = (try? await fetch(address)).flatMap { try? NexItchFormat.json($0) }.flatMap { NexItchFormat.int($0, "id") }
        if id == nil {
            let page = try await fetch(address.deletingLastPathComponent())
            id = NexItchFormat.pageGameID(String(decoding: page.prefix(2 << 20), as: UTF8.self))
        }
        guard let id else { throw NexItchError.invalid("page") }
        guard let object = NexItchFormat.value(try await get("games/\(id)", key: key), "game") as? [String: Any],
              let game = NexItchFormat.game(object, id: id) else { throw NexItchError.invalid("game") }
        return game
    }

    func uploads(game: Int, downloadKey: Int) async throws -> [NexItchUpload] {
        guard let key else { throw NexItchError.signedOut }
        return NexItchFormat.uploads(try await get("games/\(game)/uploads", query: Self.keyQuery(downloadKey), key: key))
    }

    /// The upload's download address; itch.io answers with a redirect to its CDN.
    func downloadRequest(upload: Int, downloadKey: Int) throws -> URLRequest {
        guard let key else { throw NexItchError.signedOut }
        var components = URLComponents(url: Self.server.appendingPathComponent("uploads/\(upload)/download"),
                                       resolvingAgainstBaseURL: false)!
        let query = Self.keyQuery(downloadKey)
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("NexPlay", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func keyQuery(_ downloadKey: Int) -> [URLQueryItem] {
        downloadKey == 0 ? [] : [URLQueryItem(name: "download_key_id", value: String(downloadKey))]
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("NexPlay", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw NexItchError.http(status) }
        return data
    }

    private func get(_ path: String, query: [URLQueryItem] = [], key: String) async throws -> [String: Any] {
        var components = URLComponents(url: Self.server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.itch.v2", forHTTPHeaderField: "Accept")
        request.setValue("NexPlay", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw NexItchError.badKey }
        guard (200..<300).contains(status) else {
            do { _ = try NexItchFormat.json(data) } catch NexItchError.badKey { throw NexItchError.badKey } catch {}
            throw NexItchError.http(status)
        }
        return try NexItchFormat.json(data)
    }
}

/// The account as the screens see it: signed in or not, its name and its games (cached in Application Support/itch;
/// the cache holds no secret).
@MainActor
final class NexItchAccount: ObservableObject {
    static let shared = NexItchAccount()

    @Published private(set) var signedIn = NexItchKeychain.load() != nil
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [NexItchGame] = []
    @Published private(set) var collected: [NexItchGame] = []
    @Published private(set) var loading = false
    @Published var failure: String?
    @Published private(set) var updated: Date?

    private struct Cache: Codable {
        var account: String
        var updated: Date
        var owned: [NexItchGame]
        var collected: [NexItchGame]
    }

    private static var folder: URL { Paths.support.appendingPathComponent("itch", isDirectory: true) }
    private static var cacheURL: URL { folder.appendingPathComponent("library.json") }
    private var started = false

    private init() {}

    /// Loads the cached list and refreshes it when it is older than 10 minutes.
    func start() {
        guard !started else { return }
        started = true
        if signedIn, let data = try? Data(contentsOf: Self.cacheURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let cache = try? decoder.decode(Cache.self, from: data) {
                accountName = cache.account
                owned = cache.owned
                collected = cache.collected
                updated = cache.updated
            }
        }
        if signedIn && (updated.map { Date().timeIntervalSince($0) > 600 } ?? true) {
            Task { await refresh() }
        }
    }

    func signIn(key: String) async throws {
        let name = try await NexItchAPI.shared.signIn(key: key)
        accountName = name
        signedIn = true
        failure = nil
        AppLog.log("itch.io: signed in")
        await refresh()
    }

    func signOut() {
        Task { await NexItchAPI.shared.signOut() }
        signedIn = false
        accountName = nil
        owned = []
        collected = []
        updated = nil
        failure = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        AppLog.log("itch.io: signed out")
    }

    func refresh() async {
        guard signedIn, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let name = try await NexItchAPI.shared.accountName()
            let ownedGames = try await NexItchAPI.shared.ownedGames()
            let collections = (try? await NexItchAPI.shared.collectionGames()) ?? []
            let ownedIDs = Set(ownedGames.map(\.id))
            accountName = name
            owned = ownedGames.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            collected = collections.filter { !ownedIDs.contains($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            updated = Date()
            failure = nil
            writeCache()
            AppLog.log("itch.io: \(owned.count) owned, \(collected.count) in collections")
        } catch NexItchError.badKey {
            failure = NexItchError.badKey.errorDescription
            AppLog.log("itch.io: the key was refused")
        } catch {
            failure = error.localizedDescription
            AppLog.log("itch.io: refresh failed: \(error.localizedDescription)")
        }
    }

    private func writeCache() {
        let cache = Cache(account: accountName ?? "", updated: updated ?? Date(), owned: owned, collected: collected)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
