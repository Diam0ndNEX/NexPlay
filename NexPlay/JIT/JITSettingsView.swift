import SwiftUI
import UniformTypeIdentifiers

// 6.3.0: Settings > JIT & Performance and Settings > Setup Center (SPEC-7.0 4.3 and 8.2).

@MainActor
struct JITSettingsView: View {
    @ObservedObject private var jit = JITManager.shared
    @AppStorage(SettingsKey.jitAutoForGames) private var autoForGames = true
    @AppStorage(SettingsKey.jitAtLaunch) private var atLaunch = false
    @State private var importing = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                JITStatusCard(jit: jit)
            } header: {
                SettingsHeader(title: "Status", symbol: "bolt.fill", color: .yellow)
            } footer: {
                if let error = jit.error {
                    Text(error).foregroundStyle(.red)
                } else if let status = jit.status {
                    Text(status)
                }
            }

            Section {
                Button { jit.enable() } label: { Label("Enable JIT Now", systemImage: "bolt.fill") }
                    .disabled(jit.busy)
                Button { jit.checkConnection() } label: {
                    Label("Check Connection & Disk Image", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(jit.busy)
                Button { LocalDevVPN.open() } label: { Label(LocalDevVPN.actionTitle, systemImage: "network") }
                Button { jit.enableWithStikDebug() } label: {
                    Label("Enable with StikDebug Instead", systemImage: "arrow.up.forward.app")
                }
                .disabled(jit.busy)
            } header: {
                SettingsHeader(title: "JIT", symbol: "cpu", color: .orange)
            } footer: {
                Text("Connect LocalDevVPN first (Wi-Fi works best). JIT lasts until NexPlay closes. Web, Godot, Ren'Py, Flash and mkxp games don't need it; Windows games (7.0) do.")
            }

            Section {
                Button { importing = true } label: {
                    Label(jit.pairingPresent ? "Replace Pairing File" : "Import Pairing File", systemImage: "doc.badge.plus")
                }
                if jit.pairingPresent {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Remove Pairing File", systemImage: "trash")
                    }
                }
                Button { jit.resetDDI() } label: {
                    Label("Reset Developer Disk Image", systemImage: "arrow.counterclockwise")
                }
                .disabled(jit.busy)
            } header: {
                SettingsHeader(title: "Pairing", symbol: "key.fill", color: .blue)
            } footer: {
                Text("The pairing file SideStore or StikDebug uses for this iPhone (.mobiledevicepairing or .plist, from idevice_pair or iloader). NexPlay keeps it in this iPhone's Keychain only. Reset the disk image if preparing keeps failing after a reboot.")
            }

            Section {
                Toggle(isOn: $autoForGames) {
                    SettingLabel("Enable JIT When a Game Needs It", "Windows games (7.0) turn JIT on before they start.")
                }
                Toggle(isOn: $atLaunch) {
                    SettingLabel("Enable JIT at App Launch", "Turns JIT on each time NexPlay opens. LocalDevVPN must be connected.")
                }
            } header: {
                SettingsHeader(title: "Automatic", symbol: "wand.and.stars", color: .purple)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { jit.importPairing(url) }
        }
        .confirmationDialog("Remove the pairing file?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { jit.removePairing() }
        } message: {
            Text("Built-in JIT needs it. You can import it again later.")
        }
        .onAppear { jit.refresh() }
    }
}

/// JIT on/off, the path, and each thing JIT depends on.
@MainActor
struct JITStatusCard: View {
    @ObservedObject var jit: JITManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: jit.isActive ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(jit.isActive ? Color.green : Color.gray,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(jit.headline).font(.headline)
                    Text(jit.pathLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if jit.busy { ProgressView() }
            }
            DiagnosticCheckRow(title: "Pairing File", ok: jit.pairingPresent,
                               detail: jit.pairingKind.map { "Saved (\($0))" } ?? "Not imported yet")
            DiagnosticCheckRow(title: "LocalDevVPN", ok: jit.vpnReachable,
                               detail: jit.vpnDetail ?? "Not checked yet")
            DiagnosticCheckRow(title: "get-task-allow", ok: DeviceInfo.signedDebuggable,
                               detail: "Lets a debugger attach to NexPlay")
            DiagnosticCheckRow(title: "JIT Helper", ok: JITHelperHost.unavailableReason == nil,
                               detail: JITHelperHost.unavailableReason ?? "In this build")
            DiagnosticCheckRow(title: "JIT Test", ok: jit.testPassed,
                               detail: jit.testDetail ?? "Not run in this session")
        }
        .padding(.vertical, 4)
    }
}

/// A checklist of what NexPlay needs, each with a live status and a fix.
@MainActor
struct SetupCenterView: View {
    @ObservedObject private var jit = JITManager.shared
    @State private var importing = false

    @AppStorage(SettingsKey.windowsLoadAtLaunch) private var windowsLoadAtLaunch = true
    @State private var windowsError: String?
    @State private var rtpImport: String?
    @State private var rtpMessage: String?

    private var windowsRuntime: Bool { BCDRuntimeInfo.isPresent }

    private var entitlementsOK: Bool? {
        guard let task = DeviceInfo.signedDebuggable,
              let memory = DeviceInfo.hasEntitlement(Entitlement.increasedMemory) else { return nil }
        return task && memory
    }

    var body: some View {
        Form {
            Section {
                SetupRow(title: "Pairing File", ok: jit.pairingPresent,
                         why: "Lets NexPlay ask iOS for JIT without a computer.",
                         actionTitle: "Import", action: { rtpImport = nil; importing = true })
                SetupRow(title: "LocalDevVPN Connected", ok: jit.vpnReachable,
                         why: "The JIT helper reaches this iPhone through it.",
                         actionTitle: LocalDevVPN.actionTitle, action: { LocalDevVPN.open() })
                SetupRow(title: "JIT Test Passed", ok: jit.testPassed,
                         why: "Windows games run only with JIT on.",
                         actionTitle: jit.busy ? nil : "Enable JIT", action: { jit.enable() })
                SetupRow(title: "Entitlements Present", ok: entitlementsOK,
                         why: "get-task-allow for JIT, a higher memory limit for big games. Your signing app decides.")
            } header: {
                SettingsHeader(title: "JIT", symbol: "bolt.fill", color: .yellow)
            } footer: {
                if let error = jit.error { Text(error).foregroundStyle(.red) }
            }

            Section {
                SetupRow(title: "Windows Runtime in This Build", ok: windowsRuntime,
                         why: windowsRuntime
                            ? "BCD \(BCDRuntimeInfo.version ?? "runtime") (Wine, FEX, DXMT)."
                            : "Runs .exe games. Run the \"Build Windows runtime\" workflow once, then build NexPlay again.")
                SetupRow(title: "Free Storage", ok: (DeviceInfo.freeDiskGB ?? 0) >= 10,
                         why: String(format: "%.1f GB free. Windows games and their C: drives need room (10 GB or more).",
                                     DeviceInfo.freeDiskGB ?? 0))
                if windowsRuntime {
                    Button {
                        do {
                            try BCDBridge.show()
                            windowsError = nil
                        } catch {
                            windowsError = (error as? WindowsRuntimeError)?.message ?? error.localizedDescription
                        }
                    } label: {
                        Label("Open Windows Games", systemImage: "play.rectangle.fill")
                    }
                    Toggle("Load at Launch", isOn: $windowsLoadAtLaunch)
                }
            } header: {
                SettingsHeader(title: "Windows Games", symbol: "pc", color: .blue)
            } footer: {
                if let message = windowsError ?? BCDRuntimeInfo.lastError {
                    Text(message).foregroundStyle(.red)
                } else if windowsRuntime {
                    Text("Windows Games opens BCD's own screen: add .exe games and play them there. Turn JIT on first. Load at Launch prepares the runtime when NexPlay starts, so it opens faster.")
                }
            }

            // 7.1.1: EasyRPG and its RTP.
            Section {
                SetupRow(title: "EasyRPG in This Build", ok: EasyRPGCore.isPresent,
                         why: EasyRPGCore.isPresent
                            ? "Runs RPG Maker 2000/2003 games natively\(EasyRPGCore.buildDate.map { " (core from \($0))" } ?? "")."
                            : "Runs RPG Maker 2000/2003 games natively. Comes with builds made by the 7.1.1 workflow.")
                SetupRow(title: "RTP 2000", ok: EasyRPGCore.hasRTP("2000"),
                         why: "Only games shipped without the standard graphics and sounds need it.",
                         actionTitle: "Import Folder", action: { rtpImport = "2000"; importing = true })
                SetupRow(title: "RTP 2003", ok: EasyRPGCore.hasRTP("2003"),
                         why: "The same for RPG Maker 2003 games.",
                         actionTitle: "Import Folder", action: { rtpImport = "2003"; importing = true })
            } header: {
                SettingsHeader(title: "RPG Maker 2000/2003", symbol: "map", color: .orange)
            } footer: {
                Text(rtpMessage ?? "Pick the installed RTP folder (it holds Backdrop, CharSet, Music and the other folders).")
            }
        }
        // 7.13.3: one importer for the pairing file and the RTP folders. Two fileImporter modifiers in one view
        // don't work together (the RTP one sat inside the form and the pairing one outside: one of them never opened).
        // rtpImport stays set until the result arrives (the binding can be cleared before the completion runs).
        .fileImporter(isPresented: $importing, allowedContentTypes: rtpImport != nil ? [.folder] : [.item]) { result in
            let version = rtpImport
            importing = false
            rtpImport = nil
            switch result {
            case .success(let url):
                if let version {
                    do {
                        try EasyRPGCore.importRTP(from: url, version: version)
                        rtpMessage = "RTP \(version) imported."
                    } catch {
                        rtpMessage = "The RTP couldn't be copied: \(error.localizedDescription)"
                    }
                } else {
                    jit.importPairing(url)
                }
            case .failure(let error):
                if version != nil { rtpMessage = error.localizedDescription }
            }
        }
        .onAppear { jit.refresh() }
    }
}

/// One checklist row: status mark, why it matters, and a fix button while it isn't done.
struct SetupRow: View {
    let title: String
    let ok: Bool?
    let why: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticCheckRow(title: title, ok: ok, detail: why)
            if let actionTitle, let action, ok != true {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .font(.caption.bold())
            }
        }
    }
}
