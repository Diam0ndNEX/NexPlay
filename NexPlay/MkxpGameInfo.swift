import Foundation

/// RPG Maker XP/VX/VX Ace helpers: which RTP a game asks for, where NexPlay keeps the RTPs it was given,
/// and which Ruby the mkxp core should boot. Compiled in every build so Setup Center can import the RTP.
enum MkxpRTP {
    /// The names Game.ini uses: XP, VX, VX Ace.
    static let kinds = ["Standard", "RPGVX", "RPGVXAce"]

    static func title(_ kind: String) -> String {
        switch kind {
        case "Standard": return "RTP XP"
        case "RPGVX": return "RTP VX"
        default: return "RTP VX Ace"
        }
    }

    static func folder(_ kind: String) -> URL {
        Paths.support.appendingPathComponent("RTP", isDirectory: true).appendingPathComponent(kind, isDirectory: true)
    }

    static func has(_ kind: String) -> Bool {
        let graphics = folder(kind).appendingPathComponent("Graphics", isDirectory: true).path
        return FileManager.default.fileExists(atPath: graphics)
    }

    enum ImportError: LocalizedError {
        case notAnRTP

        var errorDescription: String? {
            "That folder has no Graphics folder. Pick the installed RTP folder itself (the one with Graphics and Audio inside)."
        }
    }

    static func importFolder(from url: URL, kind: String) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("Graphics").path) else { throw ImportError.notAnRTP }
        let target = folder(kind)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: url, to: target)
    }

    /// The RTP names in the game's Game.ini (RTP=, RTP1= to RTP3=). Empty when the game needs none.
    static func required(in gameFolder: URL) -> [String] {
        let ini = gameFolder.appendingPathComponent("Game.ini")
        guard let text = ImportPipeline.readText(ini) else { return [] }
        var found: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard ["rtp", "rtp1", "rtp2", "rtp3"].contains(key), !value.isEmpty else { continue }
            if let kind = kinds.first(where: { $0.lowercased() == value.lowercased() }), !found.contains(kind) {
                found.append(kind)
            }
        }
        return found
    }

    /// The Ruby the mkxp core boots: "18" for XP and VX, "19" for VX Ace.
    static func rubyVersion(in gameFolder: URL) -> String {
        let fm = FileManager.default
        for dir in [gameFolder, gameFolder.appendingPathComponent("Data")] {
            if fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rvdata2").path) { return "19" }
            if fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rxdata").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("Scripts.rvdata").path) { return "18" }
        }
        let names = (try? fm.contentsOfDirectory(atPath: gameFolder.path)) ?? []
        if names.contains(where: { $0.lowercased().hasSuffix(".rgss3a") }) { return "19" }
        if names.contains(where: { $0.lowercased().hasSuffix(".rgss2a") || $0.lowercased().hasSuffix(".rgssad") }) {
            return "18"
        }
        return "19"
    }
}
