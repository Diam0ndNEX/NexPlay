import SwiftUI
import UniformTypeIdentifiers

// 6.3.0: Settings > JIT & Performance and Settings > Setup Center (SPEC-7.0 4.3 and 8.2).

@MainActor
struct JITSettingsView: View {
    @ObservedObject private var jit = JITManager.shared
    @AppStorage(SettingsKey.jitAutoForGames) private var autoForGames = true
    @AppStorage(SettingsKey.jitAtLaunch) private var atLaunch = false
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
                Text("Connect LocalDevVPN first (Wi-Fi or mobile data). JIT lasts until NexPlay closes. Web, Godot, Ren'Py, Flash and mkxp games don't need it; Windows games (7.0) do.")
            }

            Section {
                Button { ImportPicker.pickOneFile { jit.importPairing($0) } } label: {
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

    @State private var rtpMessage: String?

    private var windowsReady: Bool { WindowsEngine.unavailableReason == nil }

    private var entitlementsOK: Bool? {
        guard let task = DeviceInfo.signedDebuggable,
              let memory = DeviceInfo.hasEntitlement(Entitlement.increasedMemory) else { return nil }
        return task && memory
    }

    var body: some View {
        // 8.1.1: custom rows on the profile's backdrop (was a stock Form). Fonts are set here so the sheet stays
        // readable when it opens from a screen that uses the pixel font.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What NexPlay needs for every kind of game, with a fix for each item.")
                    .font(NexType.caption)
                    .foregroundStyle(NexColor.textSoft)
                    .padding(.horizontal, 6)

                NexSectionHeader(title: "JIT", symbol: "bolt.fill", tint: .yellow)
                    .padding(.top, 6)
                NexRowGroup(glass: false) {
                    SetupRow(title: "Pairing File", ok: jit.pairingPresent,
                             why: "Lets NexPlay ask iOS for JIT without a computer.",
                             actionTitle: "Import", action: { ImportPicker.pickOneFile { jit.importPairing($0) } })
                    NexRowDivider()
                    SetupRow(title: "LocalDevVPN Connected", ok: jit.vpnReachable,
                             why: jit.vpnDetail ?? "The JIT helper reaches this iPhone through it.",
                             actionTitle: LocalDevVPN.actionTitle, action: { LocalDevVPN.open() })
                    NexRowDivider()
                    SetupRow(title: "JIT Test Passed", ok: jit.testPassed,
                             why: "Windows games run only with JIT on.",
                             actionTitle: jit.busy ? nil : "Enable JIT", action: { jit.enable() })
                    NexRowDivider()
                    SetupRow(title: "Entitlements Present", ok: entitlementsOK,
                             why: "get-task-allow for JIT, a higher memory limit for big games. Your signing app decides.")
                }
                if let error = jit.error {
                    footer(error, color: NexColor.danger)
                }

                NexSectionHeader(title: "Windows Games", symbol: "pc", tint: .blue)
                    .padding(.top, 10)
                NexRowGroup(glass: false) {
                    SetupRow(title: "Windows Engine in This Build", ok: windowsReady,
                             why: WindowsEngine.unavailableReason
                                ?? "\(WindowsEngine.summary): Wine, FEX and DXMT, built into NexPlay.")
                    NexRowDivider()
                    SetupRow(title: "Free Storage", ok: (DeviceInfo.freeDiskGB ?? 0) >= 10,
                             why: String(format: "%.1f GB free. Windows games and their C: drives need room (10 GB or more).",
                                         DeviceInfo.freeDiskGB ?? 0))
                }
                if windowsReady {
                    footer("Add .exe games to the library like any other game and press Play. Turn JIT on first (above). NexPlay runs one Windows game per app launch.")
                }

                // 7.1.1: EasyRPG and its RTP.
                NexSectionHeader(title: "RPG Maker 2000/2003", symbol: "map", tint: .orange)
                    .padding(.top, 10)
                NexRowGroup(glass: false) {
                    SetupRow(title: "EasyRPG in This Build", ok: EasyRPGCore.isPresent,
                             why: EasyRPGCore.isPresent
                                ? "Runs RPG Maker 2000/2003 games natively\(EasyRPGCore.buildDate.map { " (core from \($0))" } ?? "")."
                                : "Runs RPG Maker 2000/2003 games natively. Comes with builds made by the 7.1.1 workflow.")
                    NexRowDivider()
                    SetupRow(title: "RTP 2000", ok: EasyRPGCore.hasRTP("2000"),
                             why: "Only games shipped without the standard graphics and sounds need it.",
                             actionTitle: "Import Folder", action: { importRTP("2000") })
                    NexRowDivider()
                    SetupRow(title: "RTP 2003", ok: EasyRPGCore.hasRTP("2003"),
                             why: "The same for RPG Maker 2003 games.",
                             actionTitle: "Import Folder", action: { importRTP("2003") })
                }
                footer(rtpMessage ?? "Pick the installed RTP folder (it holds Backdrop, CharSet, Music and the other folders).")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .font(NexType.body)
        .background(ProfileBackdrop().ignoresSafeArea())
        .navigationTitle("Setup Center")
        .navigationBarTitleDisplayMode(.inline)
        // 7.13.5: the pairing file and the RTP folders use the UIKit pickers (ImportPicker), no fileImporter.
        .onAppear { jit.refresh() }
    }

    private func footer(_ text: String, color: Color = NexColor.textSoft) -> some View {
        Text(text)
            .font(NexType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private func importRTP(_ version: String) {
        ImportPicker.pickFolders { urls in
            guard let url = urls.first else { return }
            do {
                try EasyRPGCore.importRTP(from: url, version: version)
                rtpMessage = "RTP \(version) imported."
            } catch {
                rtpMessage = "The RTP couldn't be copied: \(error.localizedDescription)"
            }
        }
    }
}

/// One checklist row: status mark, why it matters, and a fix button while it isn't done.
/// 8.1.1: drawn with the design system (rounded type, status colours, glass fix button).
struct SetupRow: View {
    let title: String
    let ok: Bool?
    let why: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NexStatusMark(ok: ok)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(NexType.label)
                    .foregroundStyle(NexColor.text)
                Text(why)
                    .font(NexType.caption)
                    .foregroundStyle(NexColor.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action, ok != true {
                    Button {
                        NexHaptics.tap()
                        action()
                    } label: {
                        Text(actionTitle)
                    }
                    .buttonStyle(NexGlassButtonStyle(fullWidth: false))
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}
