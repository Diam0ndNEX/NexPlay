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
        try writer.add(name: "app.log", data: Data(log.utf8))
        let jitLines = log.split(separator: "\n").filter { $0.contains("jit:") }.joined(separator: "\n")
        try writer.add(name: "jit.log", data: Data(jitLines.utf8))
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
