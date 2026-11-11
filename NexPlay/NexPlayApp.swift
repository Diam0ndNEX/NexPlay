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

    @MainActor
    static func unlock() { lock(.auto) }
}

@main
struct NexPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.silentModeAudio: true,
            SettingsKey.showMenuButton: true,
            SettingsKey.keepScreenAwake: true,
            SettingsKey.desktopMode: true,
            SettingsKey.pixelatedScaling: false,
        ])
        AppLog.noteLaunch()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    Task {
                        await store.importItems([url])
                        // Files opened from other apps are copied into an Inbox folder; remove that copy.
                        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
                    }
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        AppLog.noteActive()
                    case .background:
                        AppLog.noteBackground()
                    default:
                        break
                    }
                }
        }
    }
}
