// NexPlay's code (not BCD's), compiled only with the Windows engine (NexPlay 8.6.0).
// Settings › Windows Games: BCD's engine-wide settings sections (Memory & performance, Graphics, .NET Framework,
// Visual C++ runtime and 32-bit MFC, Wine Gecko, All settings) drawn with NexPlay's menu rows inside NexPlay's Settings.
// The data and every change go through BCD's own live backends (BCDSettingsLive.swift: BCDMemoryLive, BCDGraphicsLive,
// BCDDotNetLive, BCDVCRuntimeLive, BCDGeckoLive, BCDAllSettingsLive), so no BCD file changes. Left out on purpose:
// store downloads in the background (no stores in NexPlay), helper memory and its test (MadeiraMemoryHost is not built),
// accounts, BCD's JIT and Dock. BCD by thebcd69: https://github.com/thebcd69/bcd-games (GPL-3.0-only with BCD's
// additional terms). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

import SwiftUI

/// BCD's words as NexPlay shows them.
enum NexBCDWords {
    static func nexplay(_ text: String) -> String {
        BCDSettingsText.scrub(text).replacingOccurrences(of: "BCD", with: "NexPlay")
    }

    static let restart = "Applies after NexPlay restarts: close it in the app switcher, then open it again."

    static func memory(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) }
    static func file(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// A row that opens a page (NexMenuRow's look, as a NavigationLink).
struct NexBCDLinkRow<Destination: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var value: String? = nil
    var enabled = true
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NexColor.accentSoft)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(NexType.label).foregroundStyle(NexColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(NexType.caption).foregroundStyle(NexColor.textSoft).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(NexColor.textSoft)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A read-only line: title, value on the right, a note under it.
struct NexBCDInfoRow: View {
    let title: String
    var note: String? = nil
    let value: String
    var tint: Color = NexColor.textSoft

    var body: some View {
        NexMenuCustomRow {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(NexType.label).foregroundStyle(NexColor.text)
                    Spacer(minLength: 8)
                    Text(value).font(NexType.captionStrong).foregroundStyle(tint).multilineTextAlignment(.trailing)
                }
                if let note {
                    Text(note).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A progress bar row.
struct NexBCDProgressRow: View {
    let title: String
    let fraction: Double

    var body: some View {
        NexMenuCustomRow {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(NexType.label).foregroundStyle(NexColor.text)
                    Spacer()
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%").font(NexType.number).foregroundStyle(NexColor.textSoft)
                }
                ProgressView(value: min(max(fraction, 0), 1)).tint(NexColor.accent)
            }
        }
    }
}

/// A page with a scroll view and NexPlay's backdrop.
struct NexBCDPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(16)
                .padding(.bottom, 20)
        }
        .nexClearsTabBar()
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One value out of a list, on its own page.
struct NexBCDChoicePage<Backend: ObservableObject>: View {
    @ObservedObject var backend: Backend
    let title: String
    var note: String? = nil
    let choices: (Backend) -> [BCDSettingsChoice]
    let value: (Backend) -> String
    let set: (Backend, String) -> Void

    var body: some View {
        NexBCDPage(title: title) {
            if let note { NexMenuNote(text: note) }
            NexMenuSection {
                ForEach(choices(backend), id: \.value) { choice in
                    NexMenuRow(title: choice.label, accessory: .check(value(backend) == choice.value)) {
                        set(backend, choice.value)
                        NexHaptics.selection()
                    }
                }
            }
        }
    }
}

/// Settings › Windows Games.
@MainActor
struct NexBCDSettingsView: View {
    @StateObject private var memory = BCDMemoryLive()
    @StateObject private var graphics = BCDGraphicsLive()
    @StateObject private var dotNet = BCDDotNetLive()
    @StateObject private var vcRuntime = BCDVCRuntimeLive()
    @StateObject private var mfc = BCDVCRuntimeLive(runtime: .x86, name: "32-bit MFC")
    @StateObject private var gecko = BCDGeckoLive()
    @StateObject private var all = BCDAllSettingsLive()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NexMenuNote(text: "Settings of the Windows engine, for every Windows game. A game's own choices, on its page under PC Setup, come first. Most of these apply at the next start of NexPlay.",
                        symbol: "info.circle.fill")
            NexMenuSection("Engine") {
                NexBCDLinkRow(title: "Memory & Performance", detail: "JIT pool, video memory, swap file, thread sync, eco mode, the background",
                              symbol: "memorychip") {
                    NexBCDMemoryPage(backend: memory)
                }
                NexBCDLinkRow(title: "Graphics", detail: "Resolution, frame cap, MetalFX, Direct3D 9, orientation, HUD",
                              symbol: "display") {
                    NexBCDGraphicsPage(backend: graphics, all: all)
                }
            }
            NexMenuSection("Windows Components") {
                NexBCDLinkRow(title: ".NET Framework (Wine Mono)", detail: "For games made with .NET", symbol: "cube.fill",
                              value: NexBCDComponents.monoText(dotNet.state)) {
                    NexBCDComponentsPage(dotNet: dotNet, vcRuntime: vcRuntime, mfc: mfc, gecko: gecko)
                }
                NexBCDLinkRow(title: "Visual C++ Runtime", detail: "Microsoft's runtime most Windows games need", symbol: "puzzlepiece.extension.fill",
                              value: NexBCDComponents.vcText(vcRuntime)) {
                    NexBCDComponentsPage(dotNet: dotNet, vcRuntime: vcRuntime, mfc: mfc, gecko: gecko)
                }
                NexBCDLinkRow(title: "HTML Engine for Installers (Wine Gecko)", detail: "For installers that show web pages", symbol: "globe",
                              value: NexBCDComponents.geckoText(gecko.state)) {
                    NexBCDComponentsPage(dotNet: dotNet, vcRuntime: vcRuntime, mfc: mfc, gecko: gecko)
                }
            }
            NexMenuSection("Advanced") {
                NexBCDLinkRow(title: "All Engine Options", detail: "Every option the engine reads from its config file, searchable",
                              symbol: "slider.horizontal.3", value: "\(all.values.count) set") {
                    NexBCDAllSettingsPage(backend: all, initialQuery: "")
                }
            }
        }
        .onAppear {
            dotNet.refresh()
            vcRuntime.refresh()
            mfc.refresh()
            gecko.refresh()
        }
    }
}

// MARK: - Memory & performance

@MainActor
struct NexBCDMemoryPage: View {
    @ObservedObject var backend: BCDMemoryLive

    var body: some View {
        let status = backend.status
        NexBCDPage(title: "Memory & Performance") {
            NexMenuSection("This Device") {
                NexBCDInfoRow(title: "NexPlay can use", note: "Measured now. Past this, iOS closes NexPlay and the game with it.",
                              value: status.limitBytes.map(NexBCDWords.memory) ?? "Not measured")
                NexBCDInfoRow(title: "Increased memory limit",
                              note: status.increasedLimit ? "This copy of NexPlay carries Apple's increased-memory entitlement."
                                  : "Missing: iOS closes large games early. Sign NexPlay with a profile that grants it.",
                              value: status.increasedLimit ? "On" : "Off",
                              tint: status.increasedLimit ? NexColor.success : NexColor.warning)
                NexBCDInfoRow(title: "Extended address space",
                              note: status.extendedAddressing
                                  ? "Games can reserve up to \(status.addressSpaceBytes.map(NexBCDWords.memory) ?? "512 GB") of addresses."
                                  : "The standard space of about 64 GB. A few large games need the extended-virtual-addressing entitlement.",
                              value: status.extendedAddressing ? "On" : "Off",
                              tint: status.extendedAddressing ? NexColor.success : NexColor.warning)
                NexBCDInfoRow(title: "Memory in this device", value: NexBCDWords.memory(status.deviceBytes))
            }
            if backend.switchesShown {
                NexMenuSection("Memory for Games") {
                    row(.pool, "JIT Pool", "Set aside when a game starts, for the x86 code the engine has translated. Below 512 MB, big games can run out of room.")
                    row(.videoMemory, "Video Memory", "The graphics memory games are told they have. Automatic decides from what is free at the start.")
                    row(.swap, "Swap File", "When memory runs short, game data moves into a file on this device, up to this size. It costs some speed.")
                    row(.swapCoverage, "What Can Move", "Which of a game's allocations may move into the swap file. The wider, the more memory it saves and the more it can slow a game.",
                        enabled: backend.value(.swap) != "")
                }
                NexMenuSection("Speed and Power") {
                    row(.syncEngine, "Thread Sync", "How a game's threads wait for each other. Fastsync, the standard, does it inside the game; Madsync is the earlier engine of that kind; Wine's own uses neither.")
                    NexMenuToggleRow(title: "Eco Mode", detail: "Every Windows game starts with its threads at low priority: cooler and longer on battery, but slower.",
                                     symbol: "leaf.fill", isOn: backend.eco) { backend.setEco($0) }
                }
            }
            NexMenuSection("In the Background") {
                NexBCDLinkRow(title: "Keep a Windows Game Running",
                              detail: "When you switch apps or lock the screen, a running Windows game keeps going for this long instead of pausing. It draws nothing until you're back. Uses more battery.",
                              symbol: "moon.fill", value: BCDBackgroundRows.label(backend.backgroundGame.isEmpty ? "Off" : backend.backgroundGame)) {
                    NexBCDChoicePage(backend: backend, title: "Keep a Game Running",
                                     choices: { BCDBackgroundRows.choices(current: $0.backgroundGame, steps: BCDBackgroundRows.gameSteps) },
                                     value: { $0.backgroundGame }, set: { $0.setBackgroundGame($1) })
                }
                NexMenuToggleRow(title: "Hear the Game Meanwhile", detail: "Off: the game is muted in the background and other apps' audio plays normally.",
                                 symbol: "speaker.wave.2.fill", isOn: backend.backgroundSound, enabled: backend.backgroundGame != "") {
                    backend.setBackgroundSound($0)
                }
            }
            if backend.restartNeeded {
                NexMenuNote(text: NexBCDWords.restart, symbol: "arrow.clockwise", tint: NexColor.warning)
            }
        }
        .onAppear { backend.refresh() }
    }

    private func label(_ key: BCDMemoryKey, _ value: String) -> String {
        BCDMemorySettings<BCDMemoryLive>.label(key, value)
    }

    private func row(_ key: BCDMemoryKey, _ title: String, _ note: String, enabled: Bool = true) -> some View {
        NexBCDLinkRow(title: title, detail: note, value: label(key, backend.value(key)), enabled: enabled) {
            NexBCDChoicePage(backend: backend, title: title, note: note,
                             choices: { live in live.choices(key).map { BCDSettingsChoice(value: $0, label: BCDMemorySettings<BCDMemoryLive>.label(key, $0)) } },
                             value: { $0.value(key) }, set: { $0.set(key, $1) })
        }
    }
}

// MARK: - Graphics

@MainActor
struct NexBCDGraphicsPage: View {
    @ObservedObject var backend: BCDGraphicsLive
    let all: BCDAllSettingsLive

    private static let frameCaps = [24, 30, 40, 60]

    var body: some View {
        NexBCDPage(title: "Graphics") {
            NexMenuNote(text: "A game's own choices, on its page under PC Setup, come first: its resolution, FPS limit, MetalFX and orientation.")
            NexMenuSection("For Every Windows Game") {
                choiceRow("Resolution", "The size of the Windows desktop.", Self.resolutionChoices, { $0.resolution }) { $0.setResolution($1) }
                choiceRow("Frame Cap", "The most frames a second any game draws. Saves heat and battery.", Self.capChoices,
                          { $0.frameCap.map(String.init) ?? "" }) { $0.setFrameCap(Int($1)) }
                choiceRow("MetalFX Upscaling", "Draws each frame smaller and scales it up: faster, a little softer.",
                          { _ in [BCDSettingsChoice(value: "", label: "Off"), BCDSettingsChoice(value: "1.5", label: "1.5×"),
                                  BCDSettingsChoice(value: "2", label: "2×")] },
                          { $0.metalFX }) { $0.setMetalFX($1) }
                choiceRow("Direct3D 9 (32-bit Games)", "Through the emulated frontend (the standard) or a native ARM64 one.",
                          { _ in [BCDSettingsChoice(value: "", label: "Emulated (standard)"),
                                  BCDSettingsChoice(value: "native", label: "Native ARM64")] },
                          { $0.direct3D9 }) { $0.setDirect3D9($1) }
                choiceRow("Screen Orientation", "How the screen turns while a Windows game runs.",
                          { _ in BCDOrientationChoice.offered.map { BCDSettingsChoice(value: $0.setting ?? "", label: $0.label) } },
                          { $0.orientation }) { $0.setOrientation($1) }
                choiceRow("Performance HUD", "The engine's HUD for Windows games that have none of their own: 1 is the frame rate alone, 4 everything for a bug report.",
                          { _ in [BCDSettingsChoice(value: "", label: "Off")] + ["1", "2", "3", "4"].map { BCDSettingsChoice(value: $0, label: $0) } },
                          { $0.hudEveryGame }) { $0.setHUDEveryGame($1) }
            }
            if backend.displaySwitchesShown && backend.displayRate > 60 {
                NexMenuSection("Display") {
                    NexMenuToggleRow(title: "Keep the Screen at \(backend.displayRate) Hz",
                                     detail: "While a game runs at 60 FPS, the screen stays at its highest rate, so a late frame waits less. Uses more power.",
                                     symbol: "gauge.with.dots.needle.67percent", isOn: backend.holdMaximumRate) { backend.setHoldMaximumRate($0) }
                }
            }
            NexMenuSection("OpenGL") {
                NexBCDInfoRow(title: BCDOpenGL.settingsTitle, note: "A game that draws with OpenGL has its own switch on its page (PC Setup, Direct3D, OpenGL).",
                              value: BCDOpenGL.settingsValue)
            }
            NexMenuSection {
                NexBCDLinkRow(title: "More Graphics Options", detail: "Direct3D, DXMT and MetalFX in All Engine Options", symbol: "slider.horizontal.3") {
                    NexBCDAllSettingsPage(backend: all, initialQuery: "Direct3D")
                }
            }
            if backend.restartNeeded {
                NexMenuNote(text: NexBCDWords.restart, symbol: "arrow.clockwise", tint: NexColor.warning)
            }
        }
    }

    private func choiceRow(_ title: String, _ note: String, _ choices: @escaping (BCDGraphicsLive) -> [BCDSettingsChoice],
                           _ value: @escaping (BCDGraphicsLive) -> String,
                           set: @escaping (BCDGraphicsLive, String) -> Void) -> some View {
        let current = value(backend)
        let label = choices(backend).first { $0.value == current }?.label ?? current
        return NexBCDLinkRow(title: title, detail: note, value: label) {
            NexBCDChoicePage(backend: backend, title: title, note: note, choices: choices, value: value, set: set)
        }
    }

    private static func size(_ value: String) -> String { value.replacingOccurrences(of: "x", with: " × ") }

    private static func resolutionChoices(_ backend: BCDGraphicsLive) -> [BCDSettingsChoice] {
        var list = [BCDSettingsChoice(value: "", label: "Standard · " + size(backend.defaultResolution))]
        list += backend.resolutions.filter { $0.value != backend.defaultResolution }.map { r in
            let shape: String
            switch r.shape {
            case .screen: shape = ""
            case .wide: shape = " · 16:9"
            case .classic: shape = " · 4:3"
            case .native: shape = " · native"
            }
            return BCDSettingsChoice(value: r.value, label: "\(r.width) × \(r.height)\(shape)")
        }
        if !backend.resolution.isEmpty, !list.contains(where: { $0.value == backend.resolution }) {
            list.append(BCDSettingsChoice(value: backend.resolution, label: size(backend.resolution) + " · yours"))
        }
        return list
    }

    private static func capChoices(_ backend: BCDGraphicsLive) -> [BCDSettingsChoice] {
        var list = [BCDSettingsChoice(value: "", label: "Off")] + frameCaps.map { BCDSettingsChoice(value: String($0), label: "\($0) FPS") }
        if let cap = backend.frameCap, !frameCaps.contains(cap) { list.append(BCDSettingsChoice(value: String(cap), label: "\(cap) FPS")) }
        return list
    }
}

// MARK: - Windows components

@MainActor enum NexBCDComponents {
    static func monoText(_ state: BCDMonoState) -> String {
        switch state {
        case .missing: return "Not installed"
        case .builtIn: return "Built in"
        case .installed(let version): return "Installed · \(version)"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        }
    }

    static func vcText(_ backend: BCDVCRuntimeLive) -> String {
        switch backend.state {
        case .missing: return backend.source == .bundled ? "Built in" : "Not installed"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .installed(let version): return backend.source == .bundled ? "Built in" : "Installed · \(version)"
        }
    }

    static func geckoText(_ state: BCDGeckoState) -> String {
        switch state {
        case .missing: return "Not installed"
        case .downloading: return "Downloading…"
        case .installed: return "Installed"
        }
    }
}

@MainActor
struct NexBCDComponentsPage: View {
    @ObservedObject var dotNet: BCDDotNetLive
    @ObservedObject var vcRuntime: BCDVCRuntimeLive
    @ObservedObject var mfc: BCDVCRuntimeLive
    @ObservedObject var gecko: BCDGeckoLive
    @Environment(\.openURL) private var openURL
    @State private var asking: Question?

    private struct Question: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirm: String
        let run: () -> Void
    }

    private static let vcLicence = URL(string: "https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/")!

    var body: some View {
        NexBCDPage(title: "Windows Components") {
            monoSection
            vcSection(vcRuntime, title: "Visual C++ 2015–2022, 64-bit",
                      note: "Most Windows games are built with Microsoft's tools and need this runtime. NexPlay fetches it from Microsoft (about 25 MB), keeps only its DLLs as Microsoft ships them, and runs nothing from the download.")
            vcSection(mfc, title: "32-bit MFC",
                      note: "Microsoft's 32-bit MFC libraries, for older 32-bit games and tools that use them.")
            NexMenuSection {
                NexMenuRow(title: "Microsoft's Licence Terms", detail: "Downloading the Visual C++ runtime means you accept them.",
                           symbol: "doc.text", accessory: .chevron) { openURL(Self.vcLicence) }
            }
            geckoSection
        }
        .onAppear {
            dotNet.refresh()
            vcRuntime.refresh()
            mfc.refresh()
            gecko.refresh()
        }
        .confirmationDialog(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            if let asking {
                Button(asking.confirm, role: .destructive) {
                    asking.run()
                    self.asking = nil
                }
                Button("Cancel", role: .cancel) { self.asking = nil }
            }
        } message: {
            Text(asking?.message ?? "")
        }
    }

    @ViewBuilder private var monoSection: some View {
        NexMenuSection(".NET Framework (Wine Mono)") {
            NexBCDInfoRow(title: "On this device",
                          note: "Games written for Microsoft's .NET Framework run on Wine Mono. Download: about \(NexBCDWords.file(dotNet.downloadBytes)), about 130 MB installed. Most games don't need it.",
                          value: NexBCDComponents.monoText(dotNet.state))
            switch dotNet.state {
            case .downloading(let fraction):
                NexBCDProgressRow(title: "Downloading", fraction: fraction)
            case .installing(let fraction):
                NexBCDProgressRow(title: "Installing", fraction: fraction)
            case .missing:
                NexMenuRow(title: dotNet.error == nil ? "Download Wine Mono \(dotNet.version)" : "Try Again", detail: dotNet.error,
                           symbol: "arrow.down.circle.fill") { dotNet.install() }
            case .installed:
                if let bytes = dotNet.installedBytes {
                    NexBCDInfoRow(title: "Space used", value: NexBCDWords.file(bytes))
                }
                NexMenuRow(title: "Remove Wine Mono", symbol: "trash", destructive: true) {
                    asking = Question(title: "Remove Wine Mono?", message: ".NET games won't start until it is downloaded again.",
                                      confirm: "Remove") { dotNet.remove() }
                }
            case .builtIn:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func vcSection(_ runtime: BCDVCRuntimeLive, title: String, note: String) -> some View {
        NexMenuSection(title) {
            NexBCDInfoRow(title: "On this device", note: note, value: NexBCDComponents.vcText(runtime),
                          tint: runtime.source == .none ? NexColor.textSoft : NexColor.success)
            switch runtime.state {
            case .downloading(let received, let expected):
                NexBCDProgressRow(title: "Downloading", fraction: expected > 0 ? Double(received) / Double(expected) : 0)
                NexMenuRow(title: "Cancel", symbol: "xmark.circle") { runtime.cancel() }
            case .installing(let fraction):
                NexBCDProgressRow(title: "Installing", fraction: fraction)
            case .missing:
                NexMenuRow(title: runtime.lastError == nil ? "Download from Microsoft" : "Try Again", detail: runtime.lastError,
                           symbol: "arrow.down.circle.fill") { runtime.install() }
            case .installed:
                if runtime.source == .downloaded {
                    NexMenuRow(title: "Download Again", detail: runtime.lastError, symbol: "arrow.clockwise") { runtime.install() }
                    NexMenuRow(title: "Remove", symbol: "trash", destructive: true) {
                        asking = Question(title: "Remove \(title)?", message: "Games that need it won't start until it is downloaded again.",
                                          confirm: "Remove") { runtime.remove() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var geckoSection: some View {
        NexMenuSection("HTML Engine for Installers (Wine Gecko)") {
            NexBCDInfoRow(title: "On this device",
                          note: "Some installers show web pages (licences, news). Wine Gecko draws them; downloaded from WineHQ. Games themselves rarely need it.",
                          value: NexBCDComponents.geckoText(gecko.state))
            switch gecko.state {
            case .downloading(let received, let total, _):
                NexBCDProgressRow(title: "Downloading", fraction: total > 0 ? Double(received) / Double(total) : 0)
                NexMenuRow(title: "Cancel", symbol: "xmark.circle") { gecko.cancel() }
            case .missing:
                NexMenuRow(title: gecko.lastError == nil ? "Download Wine Gecko" : "Try Again", detail: gecko.lastError,
                           symbol: "arrow.down.circle.fill") { gecko.install() }
            case .installed:
                NexMenuRow(title: "Remove Wine Gecko", symbol: "trash", destructive: true) {
                    asking = Question(title: "Remove Wine Gecko?", message: "Installers that show web pages show blank pages until it is downloaded again.",
                                      confirm: "Remove") { gecko.remove() }
                }
            }
        }
    }
}

// MARK: - All engine options

@MainActor
struct NexBCDAllSettingsPage: View {
    @ObservedObject var backend: BCDAllSettingsLive
    let initialQuery: String
    @State private var query = ""
    @State private var started = false

    private var shown: [BCDConfigEntry] {
        backend.entries.filter {
            BCDSettingsText.matches(query, key: $0.key, title: $0.title, note: $0.note, category: $0.category)
        }
    }

    var body: some View {
        let list = shown
        NexBCDPage(title: "All Engine Options") {
            NexMenuNote(text: "Every option the Windows engine reads from its config file. Standard leaves an option out of the file. Most are read when NexPlay starts.")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NexColor.textSoft)
                TextField("Search options", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(NexType.body)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(NexColor.textSoft) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .nexGlassCapsule()
            if backend.changed {
                NexMenuNote(text: NexBCDWords.restart, symbol: "arrow.clockwise", tint: NexColor.warning)
            }
            ForEach(categories(list), id: \.self) { category in
                NexMenuSection(category) {
                    ForEach(list.filter { $0.category == category }) { entry in
                        NexBCDLinkRow(title: entry.title.isEmpty ? BCDSettingsText.scrub(entry.key) : entry.title,
                                      detail: BCDSettingsText.scrub(entry.key),
                                      value: summary(entry)) {
                            NexBCDOptionPage(backend: backend, entry: entry)
                        }
                    }
                }
            }
            if list.isEmpty {
                NexMenuNote(text: "Nothing matches \u{201C}\(query)\u{201D}.")
            }
        }
        .onAppear {
            backend.refresh()
            if !started {
                started = true
                query = initialQuery
            }
        }
    }

    private func categories(_ list: [BCDConfigEntry]) -> [String] {
        let used = Set(list.map(\.category))
        var ordered = backend.categories.filter { used.contains($0) }
        for category in used.sorted() where !ordered.contains(category) { ordered.append(category) }
        return ordered
    }

    private func summary(_ entry: BCDConfigEntry) -> String {
        guard let value = backend.values[entry.key], !value.isEmpty else { return "Standard" }
        if entry.kind == .toggle { return value == "1" ? "On" : (value == "0" ? "Off" : value) }
        return entry.choices.first { $0.value == value }?.label ?? value
    }
}

/// One engine option: its note, then its choices or a text field.
@MainActor
struct NexBCDOptionPage: View {
    @ObservedObject var backend: BCDAllSettingsLive
    let entry: BCDConfigEntry
    @State private var draft = ""
    @State private var loaded = false

    private var current: String { backend.values[entry.key] ?? "" }

    private var choices: [BCDSettingsChoice] {
        if entry.kind == .toggle {
            let standard = entry.defaultValue == "1" ? "Standard (on)" : entry.defaultValue == "0" ? "Standard (off)" : "Standard"
            return [BCDSettingsChoice(value: "", label: standard), BCDSettingsChoice(value: "1", label: "On"),
                    BCDSettingsChoice(value: "0", label: "Off")]
        }
        let standard = entry.defaultValue.isEmpty ? "Standard" : "Standard (\(BCDSettingsText.scrub(entry.defaultValue)))"
        return [BCDSettingsChoice(value: "", label: standard)] + entry.choices
    }

    var body: some View {
        NexBCDPage(title: entry.title.isEmpty ? BCDSettingsText.scrub(entry.key) : entry.title) {
            NexMenuSection {
                NexBCDInfoRow(title: "Option", value: BCDSettingsText.scrub(entry.key))
                if !entry.defaultValue.isEmpty {
                    NexBCDInfoRow(title: "Standard", value: BCDSettingsText.scrub(entry.defaultValue))
                }
            }
            if !entry.note.isEmpty {
                NexMenuNote(text: NexBCDWords.nexplay(entry.note))
            }
            switch entry.kind {
            case .toggle, .choice:
                NexMenuSection {
                    ForEach(choices, id: \.value) { choice in
                        NexMenuRow(title: choice.label, accessory: .check(current == choice.value)) {
                            backend.set(entry.key, choice.value.isEmpty ? nil : choice.value)
                        }
                    }
                }
            case .number, .text:
                NexMenuSection {
                    NexMenuCustomRow {
                        TextField(entry.defaultValue.isEmpty ? "Value" : BCDSettingsText.scrub(entry.defaultValue), text: $draft)
                            .font(NexType.body)
                            .keyboardType(entry.kind == .number ? .numbersAndPunctuation : .default)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    NexMenuRow(title: "Save", symbol: "checkmark", enabled: draft != current) {
                        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        backend.set(entry.key, value.isEmpty ? nil : value)
                        NexHaptics.success()
                    }
                    NexMenuRow(title: "Back to Standard", symbol: "arrow.uturn.backward", enabled: !current.isEmpty) {
                        backend.set(entry.key, nil)
                        draft = ""
                    }
                }
            }
            if backend.changed {
                NexMenuNote(text: NexBCDWords.restart, symbol: "arrow.clockwise", tint: NexColor.warning)
            }
        }
        .onAppear {
            if !loaded {
                loaded = true
                draft = current
            }
        }
    }
}
