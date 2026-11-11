import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The orientations the app currently allows. The player changes this per game.
    static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }
}

enum OrientationManager {
    @MainActor
    static func lock(_ mode: OrientationMode) {
        AppDelegate.orientationMask = mode.mask

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

        if var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController {
            while let next = top.presentedViewController { top = next }
            top.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mode.mask)) { _ in }
    }

    /// The orientation outside games: free with Auto-rotate Outside Games, else portrait.
    static var outsideMode: OrientationMode {
        UserDefaults.standard.bool(forKey: SettingsKey.autoRotateOutside) ? .auto : .portrait
    }

    @MainActor
    static func unlock() { lock(outsideMode) }
}

@main
struct NexPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var collections = CollectionStore()
    @StateObject private var privacy = PrivacyLock()
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.theme) private var theme = "dark"

    init() {
        UserDefaults.standard.register(defaults: NexPlayApp.defaultSettings)
        AppDelegate.orientationMask = OrientationManager.outsideMode.mask
        AppLog.noteLaunch()
    }

    static let defaultSettings: [String: Any] = [
        SettingsKey.silentModeAudio: true,
        SettingsKey.showMenuButton: true,
        SettingsKey.keepScreenAwake: true,
        SettingsKey.desktopMode: true,
        SettingsKey.pixelatedScaling: false,
        SettingsKey.nwMode: true,
        SettingsKey.hapticsEnabled: true,
        SettingsKey.hapticStrength: 1,
        SettingsKey.controllerMode: "keys",
        SettingsKey.libraryLayout: "grid",
        SettingsKey.titleUnderCard: true,
        SettingsKey.showContinueCard: true,
        SettingsKey.theme: "dark",
        SettingsKey.autoBackup: true,
        SettingsKey.backupRetention: 10,
        SettingsKey.barOpacity: 0.85,
        SettingsKey.barScale: 1.0,
        SettingsKey.barDrawer: "horizontal",
        SettingsKey.barGlass: true,
        SettingsKey.barAutoHide: true,
        SettingsKey.barShowFastForward: true,
        SettingsKey.barShowScreenshot: true,
        SettingsKey.barShowKeyboard: true,
        SettingsKey.touchPadScale: 1.0,
        SettingsKey.touchPadOpacity: 1.0,
        SettingsKey.touchDirectionalType: "layout",
        SettingsKey.physicalControllerEnabled: true,
        SettingsKey.hidePadWithController: true,
        SettingsKey.barWithController: false,
        SettingsKey.autoRotateInGames: false,
        SettingsKey.newGameOrientation: "landscape",
        SettingsKey.autoRotateOutside: false,
        SettingsKey.portraitGameOffset: 0.0,
        SettingsKey.animatedBackground: true,
        SettingsKey.backgroundTheme: "nebula",
    ]

    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(collections)
                .environmentObject(privacy)
                .environmentObject(appState)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in open(url) }
                .task {
                    OrientationManager.unlock()
                    // A backup pass 30 seconds after launch, like Empo.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    backUpAll()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        AppLog.noteActive()
                    case .background:
                        AppLog.noteBackground()
                        privacy.lock()
                        backUpAll()
                    default:
                        break
                    }
                }
        }
    }

    private func backUpAll() {
        guard AutoBackup.isEnabled else { return }
        let games = store.games
        Task.detached(priority: .utility) {
            let count = AutoBackup.runAll(games)
            if count > 0 { AppLog.log("automatic backup: \(count) game(s)") }
        }
    }

    /// A ZIP of saves opened from another app goes to the backup picker; anything else is imported as a game.
    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if AutoBackup.looksLikeSaveBackup(url) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: url, to: copy)
            if scoped { url.stopAccessingSecurityScopedResource() }
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            appState.pendingBackup = copy
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        Task {
            await store.importItems([url])
            // Files opened from other apps are copied into an Inbox folder; remove that copy.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
    }
}
