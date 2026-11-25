import Foundation

/// 8.20.0: recognises a Japanese game by its file names (kana, or kanji next to kana), for the Japanese locale hint of
/// Windows games and for RPG Maker games' text. Looks at no more than 400 names in the top three folder levels.
enum JapaneseText {
    nonisolated static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value) }
    }

    nonisolated static func looksJapanese(folder: URL) -> Bool {
        let fm = FileManager.default
        var level = [folder]
        var seen = 0
        var kana = 0
        for _ in 0..<3 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    seen += 1
                    if hasKana(kid.lastPathComponent) { kana += 1 }
                    if kana >= 2 { return true }
                    if seen >= 400 { return kana > 0 }
                    if (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(kid) }
                }
            }
            level = next
        }
        return kana > 0
    }
}
