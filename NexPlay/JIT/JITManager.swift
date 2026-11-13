import Foundation
import Network
import SwiftUI
import UIKit

// 6.3.0: built-in JIT. NexPlay starts its helper extension (StikJIT inside), which attaches to NexPlay over
// LocalDevVPN and runs NexPlay's JIT script (JITScript.swift). NexPlay then asks the debugger for an executable page
// with BRK #0xf00d (NexJIT.c), runs a test function there and tells the debugger to detach (8.0.0: builds with the
// Windows engine keep it attached; BCD's pool requests need it). JIT lasts until NexPlay closes. The flow, the LocalDevVPN check and the error explanations are adapted from BCD's JITSetup.swift and
// JITNetwork.swift (GPL-3.0-or-later, Madeira Converter Exception). Includes work from BCD by thebcd69
// (https://github.com/thebcd69/bcd-games). The StikDebug link follows StikJIT's INTEGRATION.md
// (https://github.com/StikDebug/StikJIT, MPL-2.0). Every step goes to the app log with a `jit:` prefix.

extension SettingsKey {
    static let jitAutoForGames = "jitAutoForGames"
    static let jitAtLaunch = "jitAtLaunch"
    /// Cleared by Reset to Defaults.
    static let jitKeys: [String] = [jitAutoForGames, jitAtLaunch]
}

struct JITError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The last JIT test, for Diagnostics. Safe from any thread.
enum JITRecord {
    static let lastTestKey = "jitLastTest"

    static var lastTest: String {
        UserDefaults.standard.string(forKey: lastTestKey) ?? "never run"
    }

    static func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        UserDefaults.standard.set("\(formatter.string(from: Date())): \(text)", forKey: lastTestKey)
    }
}

/// LocalDevVPN routes 10.7.0.1 to this iPhone, which is how the JIT helper and StikDebug reach it.
@MainActor
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN come back to NexPlay.
    static let connect = URL(string: "localdevvpn://enable?scheme=nexplayapp")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    static func open() {
        let installed = isInstalled
        AppLog.log("jit: open LocalDevVPN (\(installed ? "connect" : "App Store"))")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// A TCP connection to lockdownd through LocalDevVPN (10.7.0.1:62078). Through a working tunnel it opens in
/// milliseconds. Nothing is sent, and it is closed at once. Address and port from BCD's LoopbackProbe.
enum LoopbackProbe {
    static let host = "10.7.0.1"
    static let port: UInt16 = 62078

    /// `completion` runs once, on the main thread: reachable, and a short detail.
    static func check(timeout: TimeInterval = 6, completion: @escaping (Bool, String) -> Void) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion(false, "bad port")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "nexplay.jit.probe")
        let start = Date()
        var finished = false
        var lastWaiting: String?
        func finish(_ ok: Bool, _ detail: String) {
            if finished { return }
            finished = true
            connection.cancel()
            let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async { completion(ok, "\(detail), \(milliseconds) ms") }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true, "connected")
            case .failed(let error): finish(false, "failed: \(error)")
            // 7.13.5: .waiting is not a failure. Through a VPN tunnel (and on mobile data) NWConnection often
            // reports waiting while the path settles, then becomes ready. Only the timeout or .failed end it.
            case .waiting(let error): lastWaiting = "\(error)"
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(false, lastWaiting.map { "timed out, last: \($0)" } ?? "timed out")
        }
    }
}

/// Runs the C self-test and, unless `detach` is false, detaches the debugger. Off the main thread: BRK waits for the
/// debugger. 8.0.0: with the Windows engine built in, the debugger stays attached (BCD's JIT pool and Wine's code pages
/// are prepared through it while a game runs), as in BCD.
private func runJITSelfTest(detach: Bool) -> (Int64, String) {
    var buffer = [CChar](repeating: 0, count: 512)
    let size = buffer.count
    let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int64 in
        guard let base = pointer.baseAddress else { return -1 }
        return nexjit_selftest(base, size)
    }
    if detach { nexjit_detach() }
    let detail = buffer.withUnsafeBufferPointer { pointer -> String in
        guard let base = pointer.baseAddress else { return "" }
        return String(cString: base)
    }
    return (result, detail)
}

@MainActor
final class JITManager: ObservableObject {
    static let shared = JITManager()

    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var pairingPresent = JITPairingStore.isPresent
    @Published private(set) var pairingKind = JITPairingStore.kind
    @Published private(set) var vpnReachable: Bool?
    @Published private(set) var vpnDetail: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var testPassed: Bool?
    @Published private(set) var testDetail: String?

    private var attempt = 0
    private var attemptOpen = false
    private var waiters: [(Bool) -> Void] = []

    private init() {}

    /// JIT works in this process: the test page ran.
    var isActive: Bool {
        testPassed == true && DeviceInfo.isDebugged && (!JITManager.keepsDebuggerAttached || DeviceInfo.isTraced)
    }

    /// 8.0.0: the Windows engine needs the debugger for as long as a game runs, so it is never told to leave.
    nonisolated static var keepsDebuggerAttached: Bool { WindowsEngine.isBuiltIn }

    var usesTXM: Bool { txmPresent ?? DeviceInfo.likelyTXM }

    var headline: String {
        if busy { return "Working…" }
        return isActive ? "JIT Active" : "JIT Off"
    }

    var pathLabel: String {
        let path = usesTXM ? "TXM path" : "non-TXM path"
        let source = txmPresent == nil ? "guessed" : "reported by iOS"
        return "iOS \(DeviceInfo.systemVersion), \(path) (\(source))"
    }

    // MARK: - Status

    func refresh() {
        pairingPresent = JITPairingStore.isPresent
        pairingKind = JITPairingStore.kind
        probeVPN()
    }

    func probeVPN() {
        LoopbackProbe.check { [weak self] ok, detail in
            Task { @MainActor in
                self?.vpnReachable = ok
                self?.vpnDetail = ok ? "Answers through LocalDevVPN (\(detail))" : "No answer at 10.7.0.1 (\(detail))"
            }
        }
    }

    // MARK: - Pairing file

    func importPairing(_ url: URL) {
        do {
            let kind = try JITPairingStore.importFile(from: url)
            pairingPresent = true
            pairingKind = kind
            error = nil
            status = "Pairing file saved (\(kind))."
            AppLog.log("jit: pairing file imported (\(kind))")
        } catch {
            self.error = error.localizedDescription
            AppLog.log("jit: pairing import failed: \(error.localizedDescription)")
        }
    }

    func removePairing() {
        JITPairingStore.remove()
        pairingPresent = false
        pairingKind = nil
        status = "Pairing file removed."
        AppLog.log("jit: pairing file removed")
    }

    // MARK: - Enable

    /// Turns JIT on with the built-in helper. `completion` gets true once the test page ran.
    func enable(completion: ((Bool) -> Void)? = nil) {
        if busy {
            if let completion { waiters.append(completion) }
            return
        }
        if isActive {
            completion?(true)
            return
        }
        if DeviceInfo.signedDebuggable == false {
            show(false, "Your signing app removed get-task-allow, so JIT can't work. Sign NexPlay with your development certificate.")
            completion?(false)
            return
        }
        if let reason = JITHelperHost.unavailableReason {
            show(false, reason)
            completion?(false)
            return
        }
        guard let pairing = try? JITPairingStore.data() else {
            show(false, "Import your pairing file first.")
            completion?(false)
            return
        }
        beginAttempt(completion)
        let tree = nexjit_txm_in_device_tree()
        AppLog.log("jit: enable (built-in) model=\(DeviceInfo.machine) iOS=\(DeviceInfo.systemVersion) txm-guess=\(DeviceInfo.likelyTXM ? 1 : 0) txm-tree=\(tree) pairing=\(pairingKind ?? "?") cs-debugged=\(DeviceInfo.isDebugged ? 1 : 0)")
        nexjit_install_trap_handler()
        status = "Checking LocalDevVPN…"
        let current = attempt
        LoopbackProbe.check { [weak self] ok, detail in
            Task { @MainActor in
                guard let self, self.attemptOpen, self.attempt == current else { return }
                self.vpnReachable = ok
                self.vpnDetail = ok ? "Answers through LocalDevVPN (\(detail))" : "No answer at 10.7.0.1 (\(detail))"
                AppLog.log("jit: loopback 10.7.0.1:62078 \(ok ? "reachable" : "unreachable") (\(detail))")
                self.startHelper(pairing: pairing)
            }
        }
    }

    private func startHelper(pairing: Data) {
        status = "Starting the JIT helper…"
        let current = attempt
        let script = Data(JITScript.source.utf8).base64EncodedString()
        let request = NexJITRequest.enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script)
        JITHelperHost.send(request, started: { [weak self] in
            Task { @MainActor in
                guard let self, self.attemptOpen, self.attempt == current else { return }
                self.status = "The helper is attaching to NexPlay…"
                self.waitForDebuggerThenTest(timeout: 90, attemptID: current)
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let response):
                    if let txm = response.txmPresent { self.txmPresent = txm }
                    AppLog.log("jit: helper finished success=\(response.success ? 1 : 0) txm=\(self.flag(response.txmPresent)): \(response.message)")
                    if !response.success, self.attempt == current {
                        self.finish(false, self.explain(response.message))
                    }
                case .failure(let failure):
                    if self.attempt == current {
                        self.finish(false, failure.localizedDescription)
                    }
                }
            }
        })
    }

    /// Fallback: StikDebug attaches with NexPlay's script (bundle ID, PID and the script in the link).
    func enableWithStikDebug() {
        guard !busy else { return }
        if DeviceInfo.signedDebuggable == false {
            show(false, "Your signing app removed get-task-allow, so JIT can't work.")
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+/=&?")
        let script = Data(JITScript.source.utf8).base64EncodedString()
        let encoded = script.addingPercentEncoding(withAllowedCharacters: allowed) ?? script
        let link = "stikdebug://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())&script-data=\(encoded)"
        guard let url = URL(string: link) else {
            show(false, "NexPlay couldn't make the StikDebug link.")
            return
        }
        beginAttempt(nil)
        nexjit_install_trap_handler()
        status = "Waiting for StikDebug to attach…"
        AppLog.log("jit: open StikDebug (bundle \(bundleID), pid \(getpid()))")
        let current = attempt
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self, !opened, self.attempt == current else { return }
                self.finish(false, "StikDebug isn't installed. Use the built-in JIT instead.")
            }
        }
        waitForDebuggerThenTest(timeout: 180, attemptID: current)
    }

    /// Waits until a debugger is attached (P_TRACED), then runs the test page and detaches.
    private func waitForDebuggerThenTest(timeout: TimeInterval, attemptID: Int) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard self.attemptOpen, self.attempt == attemptID else { return }
                if DeviceInfo.isTraced { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard self.attemptOpen, self.attempt == attemptID else { return }
            guard DeviceInfo.isTraced else {
                self.finish(false, "Nothing attached to NexPlay within \(Int(timeout)) seconds. Check that LocalDevVPN is connected, then try again.")
                return
            }
            AppLog.log("jit: debugger attached (cs-debugged=\(DeviceInfo.isDebugged ? 1 : 0)); running the self-test")
            AppLog.noteGame("JIT self-test")
            _ = AppLog.shared.text   // waits for the log lines above to reach the file, in case the test crashes
            self.status = "Testing JIT…"
            let detach = !JITManager.keepsDebuggerAttached
            let outcome = await Task.detached(priority: .userInitiated) { runJITSelfTest(detach: detach) }.value
            AppLog.noteGame(nil)
            let passed = outcome.0 == 42
            self.testPassed = passed
            self.testDetail = outcome.1
            AppLog.log("jit: self-test result=\(outcome.0): \(outcome.1)")
            let path = self.usesTXM ? "TXM" : "non-TXM"
            JITRecord.note(passed ? "passed (\(path) path)" : "failed: \(outcome.1)")
            if passed {
                self.finish(true, "JIT is on (\(path) path). The test page returned 42.")
            } else {
                self.finish(false, "The JIT test failed: \(outcome.1)")
            }
        }
    }

    // MARK: - Helper checks

    /// Asks the helper to check LocalDevVPN and the Developer Disk Image, without attaching.
    func checkConnection() {
        guard !busy else { return }
        if let reason = JITHelperHost.unavailableReason {
            show(false, reason)
            return
        }
        guard let pairing = try? JITPairingStore.data() else {
            show(false, "Import your pairing file first.")
            return
        }
        busy = true
        error = nil
        status = "Checking LocalDevVPN and the Developer Disk Image…"
        AppLog.log("jit: check connection")
        JITHelperHost.send(.prepare(pairingData: pairing)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let response):
                    if let txm = response.txmPresent { self.txmPresent = txm }
                    AppLog.log("jit: check success=\(response.success ? 1 : 0) txm=\(self.flag(response.txmPresent)): \(response.message)")
                    if response.success {
                        self.vpnReachable = true
                        self.show(true, response.message)
                    } else {
                        self.show(false, self.explain(response.message))
                    }
                case .failure(let failure):
                    self.show(false, failure.localizedDescription)
                }
            }
        }
    }

    func resetDDI() {
        guard !busy else { return }
        if let reason = JITHelperHost.unavailableReason {
            show(false, reason)
            return
        }
        busy = true
        status = "Clearing the cached Developer Disk Image…"
        JITHelperHost.send(.resetDDI) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let response):
                    AppLog.log("jit: reset DDI success=\(response.success ? 1 : 0): \(response.message)")
                    self.show(response.success, response.message)
                case .failure(let failure):
                    self.show(false, failure.localizedDescription)
                }
            }
        }
    }

    // MARK: - Attempts

    private func beginAttempt(_ completion: ((Bool) -> Void)?) {
        attempt += 1
        attemptOpen = true
        busy = true
        error = nil
        if let completion { waiters.append(completion) }
    }

    private func finish(_ ok: Bool, _ message: String) {
        guard attemptOpen else { return }
        attemptOpen = false
        busy = false
        show(ok, message)
        AppLog.log("jit: \(ok ? "done" : "failed"): \(message)")
        let list = waiters
        waiters = []
        for waiter in list { waiter(ok) }
    }

    private func show(_ ok: Bool, _ message: String) {
        if ok {
            status = message
            error = nil
        } else {
            status = nil
            error = message
        }
    }

    /// A connection problem gets a plain explanation (the helper's own text is in the log).
    private func explain(_ message: String) -> String {
        let text = message.lowercased()
        let reset = ["connectionreset", "connection reset", "device refused connection"]
        let vpn = ["connectionrefused", "connection refused", "timedout", "timed out", "networkunreachable",
                   "network unreachable", "hostunreachable", "host unreachable", "no route"]
        if reset.contains(where: { text.contains($0) }) {
            return "This iPhone dropped the connection. It may no longer accept this pairing file: make a new one, import it, and check that LocalDevVPN is connected."
        }
        // 7.13.5: only the helper's own error decides this. The app's probe can fail while the helper still
        // gets through, and then the real reason was hidden behind this message.
        if vpn.contains(where: { text.contains($0) }) {
            return "There's no connection to this iPhone through LocalDevVPN (\(message)). Turn LocalDevVPN off and on, then try again. Wi-Fi or mobile data both work."
        }
        return message
    }

    private func flag(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "1"
        case .some(false): return "0"
        case .none: return "?"
        }
    }
}
