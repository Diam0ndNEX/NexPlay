// NexPlay's code (not BCD's), compiled only with the Windows engine (NexPlay 8.6.2).
// Setup Center's Windows checks: Microsoft's Visual C++ runtime and 32-bit MFC, Wine Mono, Wine Gecko (BCD's live backends,
// download from the row), and BCD's readiness check (BCDReadiness.scan/evaluate: the DLLs each game's programs import
// against what this device has) for every Windows game in NexPlay's library. No BCD file changes. BCD by thebcd69:
// https://github.com/thebcd69/bcd-games (GPL-3.0-only with BCD's additional terms).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

import SwiftUI

/// The findings of one game.
struct NexBCDGameReadiness: Identifiable {
    let id: UUID
    let name: String
    let findings: [BCDReadinessFinding]
}

@MainActor
struct NexBCDReadinessSection: View {
    @StateObject private var vcRuntime = BCDVCRuntimeLive()
    @StateObject private var mfc = BCDVCRuntimeLive(runtime: .x86, name: "32-bit MFC")
    @StateObject private var mono = BCDDotNetLive()
    @StateObject private var gecko = BCDGeckoLive()
    @State private var results: [NexBCDGameReadiness] = []
    @State private var scanning = false
    @State private var scanned = false

    private var windowsGames: [Game] {
        (LibraryStore.current?.games ?? []).filter { GameRuntimes.kind(for: $0) == .windows }
    }

    private func needed(_ id: String) -> Int {
        results.filter { game in game.findings.contains { $0.id == id } }.count
    }

    var body: some View {
        NexSectionHeader(title: "Windows Components", symbol: "puzzlepiece.extension.fill", tint: .cyan)
            .padding(.top, 10)
        NexRowGroup(glass: false) {
            SetupRow(title: "Visual C++ Runtime (64-bit)", ok: busy(vcRuntime) ? nil : vcRuntime.source != .none,
                     why: vcLine(vcRuntime, "Most Windows games need it. NexPlay downloads it from Microsoft (about 25 MB)."),
                     actionTitle: busy(vcRuntime) ? nil : "Download", action: { vcRuntime.install() })
            NexRowDivider()
            SetupRow(title: "32-bit MFC", ok: busy(mfc) ? nil : (mfc.source != .none ? true : (needed("mfc32") > 0 ? false : nil)),
                     why: vcLine(mfc, usedBy("mfc32", "Only older 32-bit games and tools that use Microsoft's MFC need it.")),
                     actionTitle: busy(mfc) ? nil : "Download", action: { mfc.install() })
            NexRowDivider()
            SetupRow(title: ".NET Framework (Wine Mono)", ok: monoOK,
                     why: monoLine,
                     actionTitle: monoBusy ? nil : "Download", action: { mono.install() })
            NexRowDivider()
            SetupRow(title: "HTML Engine for Installers (Wine Gecko)", ok: geckoOK,
                     why: geckoLine,
                     actionTitle: geckoBusy ? nil : "Download", action: { gecko.install() })
        }
        footer("Downloading the Visual C++ runtime or MFC means you accept Microsoft's licence terms (Settings › Windows Games › Windows Components). Each one can be removed there.")

        if !windowsGames.isEmpty {
            NexSectionHeader(title: "Windows Games Check", symbol: "checklist", tint: .blue)
                .padding(.top, 10)
            NexRowGroup(glass: false) {
                if scanning && results.isEmpty {
                    SetupRow(title: "Checking \(windowsGames.count) game\(windowsGames.count == 1 ? "" : "s")…", ok: nil,
                             why: "NexPlay reads which Windows files each game's programs need.")
                } else {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { NexRowDivider() }
                        SetupRow(title: game.name, ok: game.findings.isEmpty ? true : (game.findings.contains { $0.fixable } ? false : nil),
                                 why: game.findings.isEmpty ? "Nothing missing that NexPlay can tell."
                                    : game.findings.prefix(3).map { Self.words($0.text) }.joined(separator: " "))
                    }
                }
            }
            footer(scanning ? "Checking…" : "A guess from the files each game imports; a game can still need something it loads later.")
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(NexType.caption)
            .foregroundStyle(NexColor.textSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .onAppear { startScan() }
    }

    // MARK: Components

    private func busy(_ runtime: BCDVCRuntimeLive) -> Bool {
        switch runtime.state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private func vcLine(_ runtime: BCDVCRuntimeLive, _ base: String) -> String {
        switch runtime.state {
        case .downloading(let received, let expected):
            return "Downloading… \(expected > 0 ? "\(Int(Double(received) / Double(expected) * 100))%" : "")"
        case .installing(let fraction):
            return "Installing… \(Int(fraction * 100))%"
        default:
            if let error = runtime.lastError { return error }
            return NexBCDComponents.vcText(runtime) + ". " + base
        }
    }

    private func usedBy(_ id: String, _ base: String) -> String {
        let count = needed(id)
        return count == 0 ? base : "\(count) of your games need\(count == 1 ? "s" : "") it."
    }

    private var monoBusy: Bool {
        switch mono.state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private var monoOK: Bool? {
        switch mono.state {
        case .installed, .builtIn: return true
        case .downloading, .installing: return nil
        case .missing: return needed("mono") > 0 ? false : nil
        }
    }

    private var monoLine: String {
        switch mono.state {
        case .downloading(let fraction): return "Downloading… \(Int(fraction * 100))%"
        case .installing(let fraction): return "Installing… \(Int(fraction * 100))%"
        default:
            if let error = mono.error { return error }
            return NexBCDComponents.monoText(mono.state) + ". " + usedBy("mono", "Only games made with .NET need it (about 130 MB installed).")
        }
    }

    private var geckoBusy: Bool {
        if case .downloading = gecko.state { return true }
        return false
    }

    private var geckoOK: Bool? {
        switch gecko.state {
        case .installed: return true
        case .downloading, .missing: return nil
        }
    }

    private var geckoLine: String {
        switch gecko.state {
        case .downloading(let received, let total, _):
            return "Downloading… \(total > 0 ? "\(Int(Double(received) / Double(total) * 100))%" : "")"
        default:
            if let error = gecko.lastError { return error }
            return NexBCDComponents.geckoText(gecko.state) + ". Only installers that show web pages need it."
        }
    }

    // MARK: Games

    /// BCD's words, pointed at NexPlay's screens.
    static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "Settings › Visual C++", with: "Setup Center (above)")
            .replacingOccurrences(of: "Settings › .NET Framework", with: "Setup Center (above)")
            .replacingOccurrences(of: "in Settings first", with: "in Setup Center (above) first")
            .replacingOccurrences(of: "BCD cannot", with: "NexPlay cannot")
            .replacingOccurrences(of: "sign BCD", with: "sign NexPlay")
            .replacingOccurrences(of: "gives BCD", with: "gives NexPlay")
    }

    private func startScan() {
        guard !scanned, !scanning else { return }
        let games = windowsGames
        guard !games.isEmpty else { return }
        scanning = true
        let provided = BCDReadinessLive.provided()
        let jobs: [(UUID, String, URL, String)] = games.map { game in
            let program = WindowsGameFiles.program(for: game) ?? ""
            return (game.id, game.name, Paths.folder(for: game),
                    URL(fileURLWithPath: program).lastPathComponent.lowercased())
        }
        Task.detached(priority: .utility) {
            var found: [NexBCDGameReadiness] = []
            for job in jobs.prefix(40) {
                let scan = BCDReadiness.scan(job.2)
                let findings = BCDReadiness.evaluate(modules: scan.modules, files: scan.files, provided: provided,
                                                     complete: scan.complete, mainFile: job.3.isEmpty ? nil : job.3)
                found.append(NexBCDGameReadiness(id: job.0, name: job.1, findings: findings))
            }
            let sorted = found.sorted { a, b in
                if a.findings.isEmpty != b.findings.isEmpty { return !a.findings.isEmpty }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            await MainActor.run {
                results = sorted
                scanning = false
                scanned = true
                AppLog.log("windows: setup check: \(sorted.count) game(s), \(sorted.filter { !$0.findings.isEmpty }.count) with notes")
            }
        }
    }
}
