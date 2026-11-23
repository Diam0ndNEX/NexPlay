import SwiftUI
import UIKit
import Translation

// 8.18.0 On-device machine translation to English with Apple's Translation framework (iOS 18). After the language
// is downloaded once (iOS asks), nothing leaves the iPhone. Used by:
// - the cheat engine (names of items, switches, variables, skills, maps...),
// - RPG Maker MV/MZ games: "Translate Whole Game" reads the game's data files (database, every map, common
//   events, troops) and translates every text with Japanese/Chinese/Korean letters into the game's dictionary;
//   while playing, text the dictionary does not know yet (plugin menus, drawn text) is translated in the
//   background and shown from then on (TranslationFeature).
// Translations are kept per game in Translations/<game-uuid>/machine-en.json (original text -> English). An
// imported MTool TranslateFile.json wins over machine translations.

extension SettingsKey {
    /// Machine translation on for games without their own setting (default off).
    static let machineTranslation = "machineTranslation"
    /// Cheat engine shows English names.
    static let cheatEnglish = "cheatEnglishNames"
}

enum MachineTranslation {
    static let english = Locale.Language(identifier: "en")

    static func cacheURL(_ gameID: UUID) -> URL {
        let dir = TranslationStore.folder.appendingPathComponent(gameID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("machine-en.json")
    }

    static func load(_ gameID: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: cacheURL(gameID)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func save(_ map: [String: String], gameID: UUID) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: cacheURL(gameID), options: .atomic)
        }
    }

    static func clear(_ gameID: UUID) {
        try? FileManager.default.removeItem(at: cacheURL(gameID))
    }

    private static func key(_ game: Game) -> String { "machineTranslation.\(game.id.uuidString)" }

    /// Per-game override, else the app setting. RPG Maker MV/MZ only.
    static func isEnabled(for game: Game) -> Bool {
        guard game.engine.isRPGMaker else { return false }
        if let value = UserDefaults.standard.object(forKey: key(game)) as? Bool { return value }
        return UserDefaults.standard.bool(forKey: SettingsKey.machineTranslation)
    }

    static func setEnabled(_ value: Bool?, for game: Game) {
        if let value { UserDefaults.standard.set(value, forKey: key(game)) } else { UserDefaults.standard.removeObject(forKey: key(game)) }
    }

    /// Text worth translating: it has letters of a script that isn't Latin (Japanese, Chinese, Korean, Cyrillic...).
    static func needsTranslation(_ text: String) -> Bool {
        guard text.count <= 4000 else { return false }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9D,
                 0xAC00...0xD7AF, 0x1100...0x11FF, 0x0400...0x04FF:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// The source language from a sample: kana = Japanese, Hangul = Korean, Han only = Chinese, Cyrillic = Russian.
    static func guessSource(_ texts: [String]) -> Locale.Language? {
        var kana = 0, han = 0, hangul = 0, cyrillic = 0
        for text in texts.prefix(400) {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF, 0xFF66...0xFF9D: kana += 1
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
                case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
                case 0x0400...0x04FF: cyrillic += 1
                default: break
                }
            }
        }
        if kana > 0 { return Locale.Language(identifier: "ja") }
        if hangul > 0 { return Locale.Language(identifier: "ko") }
        if han > 0 { return Locale.Language(identifier: "zh-Hans") }
        if cyrillic > 0 { return Locale.Language(identifier: "ru") }
        return nil
    }

    static func languageName(_ language: Locale.Language?) -> String {
        guard let code = language?.languageCode?.identifier else { return "the game's language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Whether iOS can translate from this language to English, and if it is downloaded.
    static func availability(from source: Locale.Language?) async -> LanguageAvailability.Status? {
        guard let source else { return nil }
        return await LanguageAvailability().status(from: source, to: english)
    }
}

/// Queues translation work for one `.translationTask` (a SwiftUI view must own the session).
/// `translate` adds a job; the view's task runs every queued job and then waits for the next one.
@MainActor
final class TranslationJobs: ObservableObject {
    struct Job {
        let texts: [String]
        let done: ([String: String]) -> Void
    }

    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published var lastError: String?
    @Published private(set) var running = false
    /// Ask iOS to download the language when it is missing (shows iOS's sheet). Off for background work.
    var mayDownload = true
    private var jobs: [Job] = []
    private var source: Locale.Language?
    private var cancelled = false

    var busy: Bool { running || !jobs.isEmpty }

    func translate(_ texts: [String], from source: Locale.Language?, done: @escaping ([String: String]) -> Void) {
        let unique = Array(Set(texts.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { done([:]); return }
        jobs.append(Job(texts: unique, done: done))
        total += unique.count
        cancelled = false
        // A running session takes the new job when it finishes the current one.
        if running { return }
        if configuration == nil || source != self.source {
            self.source = source
            configuration = TranslationSession.Configuration(source: source, target: MachineTranslation.english)
        } else {
            configuration?.invalidate()
        }
    }

    func cancel() {
        cancelled = true
        let pending = jobs
        jobs = []
        pending.forEach { $0.done([:]) }
    }

    /// Called by the view's `.translationTask`.
    func run(_ session: TranslationSession) async {
        guard !running else { return }
        running = true
        defer {
            running = false
            if jobs.isEmpty { done = 0; total = 0 }
        }
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            var out: [String: String] = [:]
            if mayDownload {
                do {
                    try await session.prepareTranslation()
                } catch {
                    lastError = "The language for translation isn't on this iPhone yet (\(error.localizedDescription))."
                    job.done(out)
                    continue
                }
            }
            var index = 0
            while index < job.texts.count, !cancelled, !Task.isCancelled {
                let chunk = Array(job.texts[index..<min(index + 60, job.texts.count)])
                index += chunk.count
                let requests = chunk.enumerated().map { offset, text in
                    TranslationSession.Request(sourceText: Self.prepare(text), clientIdentifier: String(offset))
                }
                do {
                    let responses = try await session.translations(from: requests)
                    for response in responses {
                        guard let id = response.clientIdentifier, let at = Int(id), at < chunk.count else { continue }
                        let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { out[chunk[at]] = text }
                    }
                } catch {
                    // One bad line can fail a whole batch: try the batch's lines one by one.
                    for text in chunk where !cancelled && !Task.isCancelled {
                        if let response = try? await session.translate(Self.prepare(text)) {
                            let english = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !english.isEmpty { out[text] = english }
                        }
                    }
                    if out.isEmpty { lastError = error.localizedDescription }
                }
                done += chunk.count
            }
            job.done(out)
        }
    }

    /// Japanese and Chinese lines of one message are one sentence split for the window: joined without a space.
    private static func prepare(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out = ""
        for line in lines where !line.isEmpty {
            if let last = out.unicodeScalars.last, let first = line.unicodeScalars.first,
               last.value < 0x3000, first.value < 0x3000 {
                out += " "
            }
            out += line
        }
        return out
    }
}

extension View {
    /// Runs `jobs` with an on-device translation session owned by this view.
    func translationJobs(_ jobs: TranslationJobs) -> some View {
        modifier(TranslationJobsModifier(jobs: jobs))
    }
}

private struct TranslationJobsModifier: ViewModifier {
    @ObservedObject var jobs: TranslationJobs

    func body(content: Content) -> some View {
        content.translationTask(jobs.configuration) { session in
            await jobs.run(session)
        }
    }
}

/// A view that only owns a translation session (the player adds it, invisible, for translation while playing).
struct TranslationHostView: View {
    @ObservedObject var jobs: TranslationJobs

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationJobs(jobs)
    }
}

// MARK: - Game text

/// Every text an RPG Maker MV/MZ game shows from its data files.
enum GameTextExtractor {
    /// Escape codes (\C[2], \N[1], \., \|, \!, \>, \<, \^, \{, \}, \$, \\) stay out of what is translated.
    private static let codePattern = try? NSRegularExpression(pattern: #"\\[A-Za-z]+\[[^\]]*\]|\\[A-Za-z]+<[^>]*>|\\[A-Za-z]+|\\[{}\\$.|!<>^]"#)

    /// Texts to translate (whole messages and the pieces between escape codes), and the whole texts with codes
    /// mapped to how to rebuild them: [(whole, pieces)].
    struct Result {
        var plain: Set<String> = []
        var coded: [(whole: String, parts: [String])] = []
    }

    static func dataFolder(for game: Game) -> URL? {
        let entry = Paths.entryDirectory(for: game)
        for name in ["data", "Data", "DATA"] {
            let url = entry.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return nil
    }

    static func collect(for game: Game) -> Result {
        var result = Result()
        guard let folder = dataFolder(for: game),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return result }
        func add(_ value: Any?) {
            guard let text = value as? String, !text.isEmpty, MachineTranslation.needsTranslation(text) else { return }
            split(text, into: &result)
        }
        func json(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        func objects(_ name: String) -> [[String: Any]] {
            (json(name) as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
        for file in files where file.lowercased().hasSuffix(".json") {
            let lower = file.lowercased()
            switch lower {
            case "actors.json":
                for o in objects(file) { add(o["name"]); add(o["nickname"]); add(o["profile"]) }
            case "classes.json", "enemies.json":
                for o in objects(file) { add(o["name"]) }
            case "skills.json":
                for o in objects(file) { add(o["name"]); add(o["description"]); add(o["message1"]); add(o["message2"]) }
            case "items.json", "weapons.json", "armors.json":
                for o in objects(file) { add(o["name"]); add(o["description"]) }
            case "states.json":
                for o in objects(file) { add(o["name"]); for k in ["message1", "message2", "message3", "message4"] { add(o[k]) } }
            case "system.json":
                guard let o = json(file) as? [String: Any] else { continue }
                add(o["gameTitle"]); add(o["currencyUnit"])
                for k in ["elements", "skillTypes", "weaponTypes", "armorTypes", "equipTypes"] {
                    (o[k] as? [Any])?.forEach { add($0) }
                }
                if let terms = o["terms"] as? [String: Any] {
                    for k in ["basic", "commands", "params"] { (terms[k] as? [Any])?.forEach { add($0) } }
                    (terms["messages"] as? [String: Any])?.values.forEach { add($0) }
                }
            case "commonevents.json":
                for o in objects(file) { events(o["list"], add: add) }
            case "troops.json":
                for o in objects(file) {
                    for page in (o["pages"] as? [Any]) ?? [] { events((page as? [String: Any])?["list"], add: add) }
                }
            case "mapinfos.json", "animations.json", "tilesets.json":
                continue
            default:
                guard lower.hasPrefix("map"), let o = json(file) as? [String: Any] else { continue }
                add(o["displayName"])
                for event in (o["events"] as? [Any]) ?? [] {
                    for page in ((event as? [String: Any])?["pages"] as? [Any]) ?? [] {
                        events((page as? [String: Any])?["list"], add: add)
                    }
                }
            }
        }
        return result
    }

    /// Show Text (101 + 401 lines) and Scroll Text (105 + 405) become one text each, lines joined with "\n" like
    /// Game_Message.allText(); choices (102), names (320, 324, 325) and MZ's speaker name are single texts.
    private static func events(_ value: Any?, add: (Any?) -> Void) {
        guard let list = value as? [[String: Any]] else { return }
        var block: [String] = []
        var blockCode = 0
        func flush() {
            if !block.isEmpty { add(block.joined(separator: "\n")) }
            block = []
            blockCode = 0
        }
        for command in list {
            let code = command["code"] as? Int ?? 0
            let params = command["parameters"] as? [Any] ?? []
            if (code == 401 || code == 405), blockCode == code || block.isEmpty {
                blockCode = code
                block.append(params.first as? String ?? "")
                continue
            }
            flush()
            switch code {
            case 101:
                if params.count > 4 { add(params[4]) }
            case 102:
                (params.first as? [Any])?.forEach { add($0) }
            case 320, 324, 325:
                if params.count > 1 { add(params[1]) }
            default:
                break
            }
        }
        flush()
    }

    /// A text without escape codes is translated whole; a text with codes is translated piece by piece and put back
    /// together around the codes, so colours, icons and names keep working.
    static func split(_ text: String, into result: inout Result) {
        guard let regex = codePattern else { result.plain.insert(text); return }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            result.plain.insert(text)
            return
        }
        var parts: [String] = []
        var cursor = 0
        for match in matches {
            parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            parts.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: cursor))
        // Even indexes are text, odd ones are codes.
        for (index, part) in parts.enumerated() where index % 2 == 0 {
            for line in part.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if MachineTranslation.needsTranslation(trimmed) { result.plain.insert(trimmed) }
            }
        }
        result.coded.append((text, parts))
    }

    /// Rebuilds a text with codes from translated pieces.
    static func rebuild(_ parts: [String], using map: [String: String]) -> String? {
        var changed = false
        var out = ""
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 { out += part; continue }
            let lines = part.components(separatedBy: "\n").map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let english = map[trimmed] {
                    changed = true
                    return line.replacingOccurrences(of: trimmed, with: english)
                }
                return line
            }
            out += lines.joined(separator: "\n")
        }
        return changed ? out : nil
    }
}
