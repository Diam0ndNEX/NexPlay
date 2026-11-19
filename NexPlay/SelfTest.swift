import SwiftUI

// 7.6.0 (SPEC-7.0-review C8, spec 8.7): Settings > Diagnostics > Run All Checks, and Export Logs ZIP.

/// One line of the self-test.
struct SelfTestResult: Identifiable {
    let id = UUID()
    let title: String
    /// true = fine, false = problem, nil = not checked / not needed yet.
    let ok: Bool?
    let detail: String
}

enum SelfTest {
    /// Runs every check. Nothing here changes the app's data (the storage test writes and deletes one file).
    @MainActor
    static func run() async -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        let signed = DeviceInfo.signedDebuggable
        results.append(SelfTestResult(title: "get-task-allow", ok: signed,
                                      detail: signed == false ? "Removed by the signing app: JIT can't work." : "Needed for JIT."))
        let memory = DeviceInfo.hasEntitlement(Entitlement.increasedMemory)
        results.append(SelfTestResult(title: "Increased Memory Limit", ok: memory,
                                      detail: memory == false ? "Missing: big games may be stopped by iOS." : "Lets big games use more RAM."))
        results.append(SelfTestResult(title: "Pairing File", ok: JITPairingStore.isPresent,
                                      detail: JITPairingStore.kind ?? "Not imported (Setup Center)"))
        let jitActive = JITManager.shared.isActive
        results.append(SelfTestResult(title: "JIT", ok: jitActive ? true : nil,
                                      detail: jitActive ? "Active in this session." : "Not enabled this session. Only Windows games need it."))

        results.append(storageTest())
        results.append(await serverTest())

        let free = DeviceInfo.freeDiskGB
        results.append(SelfTestResult(title: "Free Storage", ok: free.map { $0 >= 2 },
                                      detail: free.map { String(format: "%.1f GB free", $0) } ?? "Unknown"))
        let available = DeviceInfo.availableMemoryMB
        results.append(SelfTestResult(title: "Memory for NexPlay", ok: available >= 1500,
                                      detail: "\(available) MB available of \(DeviceInfo.physicalMemoryMB) MB"))

        for item in DeviceInfo.components {
            results.append(SelfTestResult(title: item.name, ok: item.present,
                                          detail: item.present ? "In this build" : "Not in this build"))
        }
        AppLog.log("self-test: \(results.filter { $0.ok == false }.count) problem(s) in \(results.count) checks")
        return results
    }

    /// Writes, reads back and deletes a small file in Application Support.
    private static func storageTest() -> SelfTestResult {
        let url = Paths.support.appendingPathComponent("selftest-\(UUID().uuidString).tmp")
        let payload = Data("NexPlay self-test".utf8)
        do {
            try payload.write(to: url, options: .atomic)
            let back = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            let same = back == payload
            return SelfTestResult(title: "Storage Write/Read", ok: same, detail: same ? "Application Support is writable." : "Read back different data.")
        } catch {
            try? FileManager.default.removeItem(at: url)
            return SelfTestResult(title: "Storage Write/Read", ok: false, detail: error.localizedDescription)
        }
    }

    /// Starts and stops the loopback server Godot, Ren'Py and Flash games use.
    private static func serverTest() async -> SelfTestResult {
        let server = LocalGameServer(root: FileManager.default.temporaryDirectory)
        let port = await server.start(preferred: 39_900)
        server.stop()
        if let port {
            return SelfTestResult(title: "Local Game Server", ok: true, detail: "Started on port \(port).")
        }
        return SelfTestResult(title: "Local Game Server", ok: false, detail: "Couldn't listen on 127.0.0.1. Godot, Ren'Py and Flash games need it.")
    }

    static func text(_ results: [SelfTestResult]) -> String {
        var lines = ["NexPlay self-test (\(DeviceInfo.appVersion))"]
        for item in results {
            let mark: String
            switch item.ok {
            case .some(true): mark = "OK  "
            case .some(false): mark = "FAIL"
            case .none: mark = "--  "
            }
            lines.append("\(mark) \(item.title): \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// The last `bytes` of a file, or nil when it is missing or empty.
    private static func tail(of url: URL, bytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return try? handle.readToEnd()
    }

    /// Engine log lines that repeat every second and say nothing about a game.
    private static let noisyMarkers = ["[CB_SUMMARY]", "[CB_COST]", "[cb-sample]", "[iOS-xrem]"].map { Data($0.utf8) }

    /// The last `bytes` of a log file without its noisy lines, read in chunks (the file can be hundreds of MB).
    private static func filteredTail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var kept = Data()
        var partial = Data()
        let newline = Data([0x0A])
        while true {
            let chunk = (try? handle.read(upToCount: 4 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            partial.append(chunk)
            guard let last = partial.lastIndex(of: 0x0A) else { continue }
            let complete = partial[partial.startIndex...last]
            partial = Data(partial[partial.index(after: last)...])
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true)
            where !noisyMarkers.contains(where: { line.range(of: $0) != nil }) {
                kept.append(line)
                kept.append(newline)
            }
            if kept.count > bytes * 3 { kept = Data(kept.suffix(bytes)) }
        }
        if !partial.isEmpty { kept.append(partial) }
        guard !kept.isEmpty else { return nil }
        return kept.count > bytes ? Data(kept.suffix(bytes)) : kept
    }

    /// The newest two files of every Windows program's logs/ and mono/mono_logs/ folder under AppData/Roaming (last 300 KB each).
    private static func gameLogs(docs: URL) -> [(String, Data)] {
        let fm = FileManager.default
        let users = docs.appendingPathComponent("wine/drive_c/users", isDirectory: true)
        var out: [(String, Data)] = []
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let roaming = user.appendingPathComponent("AppData/Roaming", isDirectory: true)
            for app in (try? fm.contentsOfDirectory(at: roaming, includingPropertiesForKeys: nil)) ?? [] {
                for sub in ["logs", "mono/mono_logs"] {
                    let folder = app.appendingPathComponent(sub, isDirectory: true)
                    let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                        .sorted {
                            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                            return a > b
                        }
                    for file in files.prefix(2) {
                        if let data = tail(of: file, bytes: 300_000) {
                            out.append(("game-logs/\(app.lastPathComponent)/\(sub)/\(file.lastPathComponent)", data))
                        }
                    }
                }
            }
        }
        return out
    }

    /// A ZIP with the report, the self-test (if run), the app log and the JIT lines of the log.
    static func exportLogsZIP(selfTest: [SelfTestResult]) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NexPlay-logs-\(stamp).zip")
        let log = AppLog.shared.text
        let writer = try StoredZipWriter(url: url)
        try writer.add(name: "report.txt", data: Data(DeviceInfo.report().utf8))
        if !selfTest.isEmpty {
            try writer.add(name: "self-test.txt", data: Data(text(selfTest).utf8))
        }
        // 8.15.6: the whole log file (several sessions, up to 8 MB), not only the lines in memory (the run before this
        // launch was cut to its last 200 lines).
        let full = tail(of: AppLog.shared.fileURL, bytes: 8_000_000) ?? Data(log.utf8)
        try writer.add(name: "app.log", data: full)
        let jitLines = log.split(separator: "\n").filter { $0.contains("jit:") }.joined(separator: "\n")
        try writer.add(name: "jit.log", data: Data(jitLines.utf8))
        // 8.7.14: the Windows engine's own logs (Wine, FEX, DXMT, the graphics set-up), the last 6 MB of each. The app log
        // only gets their last 60 lines, which never show why a game's picture stays black.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // 8.7.15: without FEX's per-second counter lines, which filled the whole 6 MB after a session.
        for name in ["bcd-log.txt", "bcd-log.prev.txt"] {
            if let data = filteredTail(of: docs.appendingPathComponent(name), bytes: 6_000_000) {
                try writer.add(name: name, data: data)
            }
        }
        // 8.8.2: the Game Log of the game that ran last and the one before (native engines: Godot, Ren'Py, RPG Maker, web).
        for (name, file) in [("game-log.txt", GameLog.fileURL), ("game-log.prev.txt", GameLog.previousFileURL)] {
            if let data = tail(of: file, bytes: 500_000), !data.isEmpty {
                try writer.add(name: name, data: data)
            }
        }
        // 8.13.11: the mkxp core's own debug log (script loading, rescued Ruby errors with their backtraces).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["mkxp-session.log", "mkxp-session.prev.log"] {
            if let data = tail(of: caches.appendingPathComponent(name), bytes: 3_000_000), !data.isEmpty {
                try writer.add(name: name, data: data)
            }
        }
        // 8.7.15: the games' own logs in the Windows drive (Godot's logs/ and mono/mono_logs/), the newest two of each.
        for (name, data) in gameLogs(docs: docs) {
            try writer.add(name: name, data: data)
        }
        try writer.finish()
        return url
    }
}

/// The self-test card at the top of Diagnostics.
struct SelfTestSection: View {
    @Binding var results: [SelfTestResult]
    @State private var running = false
    @State private var copied = false

    var body: some View {
        Section {
            Button {
                guard !running else { return }
                running = true
                Task {
                    results = await SelfTest.run()
                    running = false
                }
            } label: {
                HStack {
                    Label(results.isEmpty ? "Run All Checks" : "Run Again", systemImage: "checklist.checked")
                    Spacer()
                    if running { ProgressView() }
                }
            }
            .disabled(running)
            if !results.isEmpty {
                let problems = results.filter { $0.ok == false }.count
                Text(problems == 0 ? "No problems found." : "\(problems) problem\(problems == 1 ? "" : "s") found.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(problems == 0 ? Color.green : Color.orange)
                ForEach(results) { item in
                    DiagnosticCheckRow(title: item.title, ok: item.ok, detail: item.detail)
                }
                Button {
                    UIPasteboard.general.string = SelfTest.text(results)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Results for Claude", systemImage: "doc.on.doc")
                }
            }
        } header: {
            SettingsHeader(title: "Self-Test", symbol: "checklist", color: .pink)
        } footer: {
            Text("Checks signing, JIT, storage, the local game server, memory, free space and every runtime in this build.")
        }
    }
}
