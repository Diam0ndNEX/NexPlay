// NexPlay 8.0.0: NexPlay's side of the merged Windows engine. Not part of BCD.
// BCD's app code (Wine, FEX and DXMT glue, sessions, settings) is compiled into NexPlay from NexPlay/Windows/BCD. This
// file takes the place of BCD's @main app (MadeiraApp.swift, whose init and WindowGroup are copied below) and of its
// front end (library, home, launchers): NexPlay's library starts a game, NexPlay's loading screen covers the start, and
// BCD's session engine (ContentView's session path) runs it. Only compiled in builds with the Windows engine
// (NEXPLAY_WINDOWS, NexPlayWindows.yml).
// Adapted from BCD's MadeiraApp.swift (GPL-3.0-only with BCD's additional terms; portions GPL-3.0-or-later from
// Madeira by Will Faust and Connor Gow). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
import Combine
import Foundation
import SwiftUI
import UIKit

/// The engine's process-wide set-up and the calls NexPlay makes into BCD's code.
@MainActor
enum NexWindowsHost {
    private static var started = false

    /// MadeiraApp's init and its WindowGroup's onAppear, once per app run, at the first Windows game. Not at NexPlay's
    /// launch: BCD's controller services take over GameController's handlers, which NexPlay's library uses.
    static func startOnce() {
        if started { return }
        started = true
        AppLog.log("windows: starting the engine (BCD \(WindowsEngine.version ?? "unknown"))")
        // The Metal Performance HUD's insights cover the game; off unless bcd.cfg turns them on (MadeiraApp.init).
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        // Read the screen on the main thread; library entries take their default resolution from it.
        _ = ResolutionChoices.screen
        // Games keep running in the background only when Windows Games' settings say so (BackgroundRun.swift).
        BackgroundRun.shared.start()
        BCDLibraryController.duoNavigation = BCDDuoFeatures.active
        // MadeiraApp's onAppear: external drives, controllers, the controller hub and keyboard/mouse.
        ExternalDrives.shared.mountAll()
        GamepadInput.shared.start()
        BCDControllerHub.shared.start(.live)
        HardwareInput.shared.start()
    }

    /// The orientations BCD's session lock allows, or nil when no lock is on (NexPlay's AppDelegate asks).
    static var orientationOverride: UIInterfaceOrientationMask? {
        let lock = BCDOrientationLock.shared
        return lock.choice.locked ? lock.supported : nil
    }

    /// Makes (or updates) BCD's library entry for a program on the Windows drive (relative to C:). True when the library
    /// has it. Entries under NexPlay/ whose program is gone are removed first. (7.0.0's nexplay_bcd_add_game.)
    static func addGame(relativePath: String, title: String, arguments: String?) -> Bool {
        let model = LibraryModel.shared
        let fm = FileManager.default
        for old in model.entries where old.desktop != true && old.relativePath.lowercased().hasPrefix("nexplay/")
            && !fm.fileExists(atPath: LibraryModel.drive.appendingPathComponent(old.relativePath).path) {
            model.remove(old.id)
        }
        let key = relativePath.lowercased()
        var entry: LibraryEntry
        if let existing = model.entries.first(where: { $0.desktop != true && $0.relativePath.lowercased() == key }) {
            entry = existing
        } else if let inspected = try? LibraryModel.inspect(LibraryModel.drive.appendingPathComponent(relativePath)) {
            entry = inspected
        } else {
            entry = LibraryEntry(title: title, relativePath: relativePath, bits: 0)
        }
        entry.title = title
        entry.relativePath = relativePath
        if let arguments { entry.arguments = arguments }
        model.save(entry)
        return model.entries.contains(where: { $0.relativePath.lowercased() == key })
    }

    /// Turns JIT on with NexPlay's JIT (the only one in the app). `completion` gets the result and a message.
    static func enableJIT(_ completion: @escaping (Bool, String) -> Void) {
        JITManager.shared.enable { ok in
            let message = ok ? "JIT is on." : (JITManager.shared.error ?? "JIT couldn't be turned on. Open Settings > JIT & Performance.")
            completion(ok, message)
        }
    }
}

/// BCD's session screen as NexPlay shows it: ContentView (its session path) with the modifiers MadeiraApp put on it.
struct NexWindowsRoot: View {
    var body: some View {
        ContentView()
            .modifier(BCDThemeTint())
            .modifier(ClaimGamepadEvents())
    }
}

/// What ContentView shows while no session runs (BCD's front end in BCD). NexPlay's loading screen lies above it,
/// so it is only black.
struct NexWindowsIdleView: View {
    let enableJIT: () -> Void

    var body: some View {
        Color.black.ignoresSafeArea()
    }
}

/// One Windows game start: BCD's session screen and what it reports back to WindowsLaunchController.
@MainActor
final class NexWindowsSession {
    enum Event {
        case stage(String)
        case started
        case ended
        case failed(String)
    }

    let controller: UIViewController
    private var watchers: Set<AnyCancellable> = []
    private var running = false
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        NexWindowsHost.startOnce()
        let host = UIHostingController(rootView: NexWindowsRoot())
        host.view.backgroundColor = .black
        controller = host
        let library = LibraryModel.shared
        library.error = nil
        library.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                Task { @MainActor in self?.sessionChanged(current != nil) }
            }
            .store(in: &watchers)
        library.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let error, !error.isEmpty else { return }
                Task { @MainActor in self?.report(error) }
            }
            .store(in: &watchers)
        // One Wine session per app run: BCD's restart alert becomes NexPlay's error card.
        library.$restartNotice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                guard let notice, !notice.isEmpty else { return }
                Task { @MainActor in
                    LibraryModel.shared.restartNotice = nil
                    self?.report(notice)
                }
            }
            .store(in: &watchers)
        library.$startingJIT
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard id != nil else { return }
                Task { @MainActor in self?.onEvent(.stage("Turning on JIT…")) }
            }
            .store(in: &watchers)
    }

    var isRunning: Bool { LibraryModel.shared.current != nil }

    /// Starts a library entry by its Windows path (C:\NexPlay\<id>\game.exe), as BCD's Home Screen links do.
    func play(windowsPath: String) {
        LibraryModel.shared.error = nil
        AppLog.log("windows: starting \(windowsPath)")
        ShortcutRouter.shared.handle(URL(string: ShortcutRouter.link(for: windowsPath)) ?? URL(fileURLWithPath: "/"))
    }

    /// Quits the running game (BCD's in-game menu's Quit game).
    func quit() {
        LibraryModel.shared.requestQuit()
    }

    func stopWatching() {
        watchers.removeAll()
    }

    private func sessionChanged(_ now: Bool) {
        if now && !running {
            running = true
            onEvent(.started)
        } else if !now && running {
            running = false
            onEvent(.ended)
        }
    }

    private func report(_ error: String) {
        guard !running else { return }
        LibraryModel.shared.error = nil
        onEvent(.failed(error))
    }
}
