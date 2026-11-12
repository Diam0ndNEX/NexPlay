import SwiftUI
import UIKit
import Darwin
import os

// 6.2.0: device, signing and entitlement checks, and Settings > Diagnostics.
// The SecTask, csops and sysctl checks and the provisioning-profile reading are adapted from Madeira/BCD's
// EntitlementChecker.swift (GPL-3.0). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
// Madeira by Will Faust, https://github.com/willfaust/Madeira (GPL-3.0-or-later).

typealias NexSecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
func nexSecTaskCopyValueForEntitlement(_ task: NexSecTaskRef, _ entitlement: NSString, _ error: NSErrorPointer) -> CFTypeRef?

@_silgen_name("SecTaskCreateFromSelf")
func nexSecTaskCreateFromSelf(_ allocator: CFAllocator?) -> NexSecTaskRef?

@_silgen_name("csops")
func nexCsops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum Entitlement {
    static let getTaskAllow = "get-task-allow"
    static let increasedMemory = "com.apple.developer.kernel.increased-memory-limit"
    static let extendedVA = "com.apple.developer.kernel.extended-virtual-addressing"
}

/// A named part of the app and whether this build contains it.
struct ComponentStatus: Identifiable {
    let name: String
    let present: Bool
    var id: String { name }
}

/// Facts about the device, the signature and this build. Safe to call from any thread.
enum DeviceInfo {
    /// The value of one of this process's entitlements: nil when the system doesn't answer.
    static func hasEntitlement(_ name: String) -> Bool? {
        guard let task = nexSecTaskCreateFromSelf(nil) else { return nil }
        guard let value = nexSecTaskCopyValueForEntitlement(task, name as NSString, nil) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    /// The code-signing flags of this process (csops CS_OPS_STATUS); nil when the kernel doesn't answer.
    static var csFlags: UInt32? {
        var flags: UInt32 = 0
        let result = withUnsafeMutablePointer(to: &flags) { pointer in
            nexCsops(getpid(), 0, UnsafeMutableRawPointer(pointer), MemoryLayout<UInt32>.size)
        }
        return result == 0 ? flags : nil
    }

    /// CS_GET_TASK_ALLOW: a debugger may attach (needed for JIT). nil when unknown.
    static var signedDebuggable: Bool? {
        csFlags.map { $0 & 0x4 != 0 }
    }

    /// CS_DEBUGGED: a debugger attached at some point, so the kernel allows JIT memory.
    static var isDebugged: Bool {
        (csFlags ?? 0) & 0x1000_0000 != 0
    }

    /// P_TRACED: a debugger is attached right now.
    static var isTraced: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// The model code, for example "iPhone18,2".
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// iOS 26 or later on an A15 or newer chip: JIT needs the TXM path. A guess from the model code.
    static var likelyTXM: Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return false }
        let id = machine
        func major(_ prefix: String) -> Int? {
            guard id.hasPrefix(prefix) else { return nil }
            let rest = id.dropFirst(prefix.count)
            guard let first = rest.split(separator: ",").first else { return nil }
            return Int(first)
        }
        if let value = major("iPhone") { return value >= 14 }
        if let value = major("iPad") { return value >= 13 }
        return false
    }

    static var physicalMemoryMB: UInt64 {
        ProcessInfo.processInfo.physicalMemory >> 20
    }

    /// What NexPlay may still allocate before iOS stops it.
    static var availableMemoryMB: Int {
        Int(os_proc_available_memory()) >> 20
    }

    static var freeDiskGB: Double? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_073_741_824
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// The Swift compilation conditions this build was made with.
    static var buildFlags: [String] {
        var flags: [String] = []
        #if NEXPLAY_MKXP
        flags.append("NEXPLAY_MKXP")
        #endif
        #if NEXPLAY_WINDOWS
        flags.append("NEXPLAY_WINDOWS")
        #endif
        #if NEXPLAY_STORES
        flags.append("NEXPLAY_STORES")
        #endif
        return flags
    }

    /// The runtimes bundled into this build.
    static var components: [ComponentStatus] {
        let manager = FileManager.default
        func resource(_ name: String) -> Bool {
            Bundle.main.url(forResource: name, withExtension: nil) != nil
        }
        func framework(_ name: String) -> Bool {
            guard let folder = Bundle.main.privateFrameworksURL else { return false }
            return manager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return [
            ComponentStatus(name: "Godot web runtimes", present: resource("GodotRuntimes")),
            ComponentStatus(name: "Ren'Py web runtimes", present: resource("RenPyRuntimes")),
            ComponentStatus(name: "Ruffle (Flash)", present: resource("Ruffle")),
            ComponentStatus(name: "mkxp core (XP/VX/Ace)", present: framework("MkxpCore.framework")),
            ComponentStatus(name: "Windows runtime", present: framework("NexWindows.framework")),
        ]
    }

    /// The kind and lifetime of the embedded provisioning profile and what it grants.
    static var profileSummary: String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let object = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil),
              let plist = object as? [String: Any]
        else { return "no profile" }
        let granted = plist["Entitlements"] as? [String: Any] ?? [:]
        func grants(_ key: String) -> String { (granted[key] as? Bool) == true ? "yes" : "no" }
        let kind: String
        if (plist["ProvisionsAllDevices"] as? Bool) == true {
            kind = "enterprise"
        } else if plist["ProvisionedDevices"] != nil {
            kind = (granted[Entitlement.getTaskAllow] as? Bool) == true ? "development" : "ad-hoc"
        } else {
            kind = "store"
        }
        var text = kind
        if let expires = plist["ExpirationDate"] as? Date {
            text += ", \(Int((expires.timeIntervalSinceNow / 86_400).rounded(.down))) days left"
        }
        text += "; grants get-task-allow \(grants(Entitlement.getTaskAllow))"
        text += ", increased memory \(grants(Entitlement.increasedMemory))"
        text += ", extended VA \(grants(Entitlement.extendedVA))"
        return text
    }

    private static func flag(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "1"
        case .some(false): return "0"
        case .none: return "?"
        }
    }

    /// One line for the app log at each launch.
    static var launchLine: String {
        "device: model=\(machine) iOS=\(systemVersion) txm=\(likelyTXM ? "likely" : "no")"
            + " ram=\(physicalMemoryMB)MB available=\(availableMemoryMB)MB"
            + " get-task-allow=\(flag(signedDebuggable)) cs-debugged=\(isDebugged ? 1 : 0) traced=\(isTraced ? 1 : 0)"
            + " increased-memory=\(flag(hasEntitlement(Entitlement.increasedMemory)))"
            + " extended-va=\(flag(hasEntitlement(Entitlement.extendedVA)))"
            + " flags=\(buildFlags.isEmpty ? "none" : buildFlags.joined(separator: ","))"
    }

    /// Everything on the Diagnostics page as text, for pasting to Claude.
    static func report() -> String {
        var lines: [String] = []
        lines.append("NexPlay \(appVersion)")
        lines.append("Model: \(machine), iOS \(systemVersion), TXM: \(likelyTXM ? "likely" : "no")")
        lines.append("RAM: \(physicalMemoryMB) MB, available to NexPlay: \(availableMemoryMB) MB, thermal: \(thermal)")
        if let free = freeDiskGB { lines.append(String(format: "Free storage: %.1f GB", free)) }
        lines.append("get-task-allow (signature): \(flag(signedDebuggable)), entitlement: \(flag(hasEntitlement(Entitlement.getTaskAllow)))")
        lines.append("increased-memory-limit: \(flag(hasEntitlement(Entitlement.increasedMemory)))")
        lines.append("extended-virtual-addressing: \(flag(hasEntitlement(Entitlement.extendedVA)))")
        lines.append("Profile: \(profileSummary)")
        if let flags = csFlags { lines.append(String(format: "cs-flags: 0x%x", flags)) }
        lines.append("JIT: cs-debugged=\(isDebugged ? 1 : 0) traced=\(isTraced ? 1 : 0)")
        lines.append("Build flags: \(buildFlags.isEmpty ? "none" : buildFlags.joined(separator: ", "))")
        for item in components {
            lines.append("\(item.name): \(item.present ? "present" : "missing")")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Settings > Diagnostics

struct DiagnosticsView: View {
    @State private var refresh = 0
    @State private var message: String?

    var body: some View {
        let signed = DeviceInfo.signedDebuggable
        let memory = DeviceInfo.hasEntitlement(Entitlement.increasedMemory)
        let address = DeviceInfo.hasEntitlement(Entitlement.extendedVA)
        return Form {
            Section {
                LabeledContent("Model", value: DeviceInfo.machine)
                LabeledContent("iOS", value: DeviceInfo.systemVersion)
                LabeledContent("TXM", value: DeviceInfo.likelyTXM ? "Yes (iOS 26+, A15 or newer)" : "No")
                LabeledContent("RAM", value: "\(DeviceInfo.physicalMemoryMB) MB")
                LabeledContent("Available to NexPlay", value: "\(DeviceInfo.availableMemoryMB) MB")
                if let free = DeviceInfo.freeDiskGB {
                    LabeledContent("Free Storage", value: String(format: "%.1f GB", free))
                }
                LabeledContent("Thermal State", value: DeviceInfo.thermal)
            } header: {
                SettingsHeader(title: "Device", symbol: "iphone", color: .mint)
            }

            Section {
                DiagnosticCheckRow(title: "get-task-allow", ok: signed,
                                   detail: "Lets NexPlay enable JIT for itself. Needed for Windows games.")
                DiagnosticCheckRow(title: "Increased Memory Limit", ok: memory,
                                   detail: "Lets big games use more RAM before iOS stops them.")
                DiagnosticCheckRow(title: "Extended Virtual Addressing", ok: address,
                                   detail: "A larger address space, needed by the Windows runtime.")
                LabeledContent("Profile") {
                    Text(DeviceInfo.profileSummary).font(.caption).multilineTextAlignment(.trailing)
                }
            } header: {
                SettingsHeader(title: "Signing & Entitlements", symbol: "checkmark.seal.fill", color: .green)
            } footer: {
                if signed == false {
                    Text("Your signing app removed get-task-allow, so JIT can't work. Sign NexPlay with a development certificate that keeps it.")
                } else if memory == false || address == false {
                    Text("Your signing app didn't keep every memory entitlement. Big games may be stopped by iOS.")
                } else {
                    Text("What your signing app kept. NexPlay asks for all three.")
                }
            }

            Section {
                DiagnosticCheckRow(title: "JIT Enabled (CS_DEBUGGED)", ok: DeviceInfo.isDebugged,
                                   detail: "Set once a debugger attached to NexPlay in this session.")
                DiagnosticCheckRow(title: "Debugger Attached", ok: DeviceInfo.isTraced,
                                   detail: "A debugger is attached right now.")
            } header: {
                SettingsHeader(title: "JIT", symbol: "bolt.fill", color: .yellow)
            } footer: {
                Text("Built-in JIT comes in 6.3.0. Not needed for web, Godot, Ren'Py, Flash or mkxp games.")
            }

            Section {
                LabeledContent("Version", value: DeviceInfo.appVersion)
                LabeledContent("Build Flags", value: DeviceInfo.buildFlags.isEmpty ? "None" : DeviceInfo.buildFlags.joined(separator: ", "))
                ForEach(DeviceInfo.components) { item in
                    DiagnosticCheckRow(title: item.name, ok: item.present, detail: item.present ? "In this build" : "Not in this build")
                }
            } header: {
                SettingsHeader(title: "This Build", symbol: "shippingbox.fill", color: .purple)
            }

            Section {
                Button {
                    UIPasteboard.general.string = DeviceInfo.report()
                    message = "The report is on the clipboard."
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                Button {
                    let lines = AppLog.shared.text.split(separator: "\n").suffix(200)
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    message = "The last \(lines.count) log lines are on the clipboard."
                } label: {
                    Label("Copy Last 200 Log Lines", systemImage: "text.alignleft")
                }
                ShareLink(item: DeviceInfo.report() + "\n\n" + AppLog.shared.text) {
                    Label("Share Report and Log", systemImage: "square.and.arrow.up")
                }
                NavigationLink { AppLogView() } label: { Label("App Log", systemImage: "list.bullet.rectangle") }
                Button {
                    refresh += 1
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            } header: {
                SettingsHeader(title: "Report", symbol: "doc.text.fill", color: .blue)
            } footer: {
                Text("Paste the report or the log lines to Claude when something doesn't work.")
            }
        }
        .id(refresh)
        .alert("Diagnostics", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

/// A title with a one-line explanation and a green, red or orange (unknown) mark.
struct DiagnosticCheckRow: View {
    let title: String
    let ok: Bool?
    let detail: String

    private var symbol: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch ok {
        case .some(true): return Color.green
        case .some(false): return Color.red
        case .none: return Color.orange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingLabel(title, detail)
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
        }
        .accessibilityElement(children: .combine)
    }
}
