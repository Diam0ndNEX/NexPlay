import Foundation

/// App-wide log for import, backup and crash notes (game problems go to `GameLog`).
/// Keeps the last lines in memory and appends every line to a file in Caches, so it survives a crash.
/// Safe to call from any thread.
final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "nexplay.applog")
    private var lines: [String] = []
    private let limit = 1000
    private let maxFileBytes: UInt64 = 512 * 1024
    let fileURL: URL
    private let formatter: DateFormatter

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("NexPlay-app.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Keep the file small: start over when it grows too large.
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > maxFileBytes {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(old.split(separator: "\n").suffix(200).map(String.init))
        }
    }

    /// Shorthand for `AppLog.shared.add(text)`.
    static func log(_ text: String) {
        shared.add(text)
    }

    func add(_ text: String) {
        let line = "\(formatter.string(from: Date()))  \(text)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.limit {
                self.lines.removeFirst(self.lines.count - self.limit)
            }
            self.appendToFile(line + "\n")
        }
    }

    private func appendToFile(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    var text: String {
        queue.sync { lines.joined(separator: "\n") }
    }

    var isEmpty: Bool {
        queue.sync { lines.isEmpty }
    }

    // MARK: - Unclean exit note (idea from Empo's CrashTracker)

    private static let sessionOpenKey = "appSessionOpen"
    private static let sessionGameKey = "appSessionGame"

    /// Call once at launch. Logs a note when the previous session did not end cleanly.
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: sessionOpenKey) {
            let game = defaults.string(forKey: sessionGameKey) ?? ""
            let suffix = game.isEmpty ? "" : " (playing \(game))"
            log("previous session did not end cleanly\(suffix): the app crashed or was stopped by iOS")
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        log("launch NexPlay \(version) (\(build)), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // 6.2.0: model, iOS, TXM guess, memory, signing and JIT state (see Diagnostics.swift).
        log(DeviceInfo.launchLine)
        defaults.set(true, forKey: sessionOpenKey)
        defaults.removeObject(forKey: sessionGameKey)
    }

    /// The app is in the foreground again.
    static func noteActive() {
        UserDefaults.standard.set(true, forKey: sessionOpenKey)
    }

    /// The app went to the background: a later stop by iOS is normal, not a crash.
    static func noteBackground() {
        UserDefaults.standard.set(false, forKey: sessionOpenKey)
    }

    /// Remembers which game is running, so a crash note can name it. Pass nil when the game ends.
    static func noteGame(_ name: String?) {
        if let name {
            UserDefaults.standard.set(name, forKey: sessionGameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionGameKey)
        }
    }
}
