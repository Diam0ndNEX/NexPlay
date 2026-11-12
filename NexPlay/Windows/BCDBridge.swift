import SwiftUI
import UIKit

// 6.4.0: the Windows runtime. BCD's app (Wine + FEX + DXMT, by thebcd69, a fork of Madeira by Will Faust) is built by
// NexPlay's "Build Windows runtime" workflow as a library, BCDCore.framework (tools/windows), and merged into the app
// when NexPlay is built. NexPlay loads it with dlopen and shows BCD's own interface through two C entry points the
// build adds to BCD: nexplay_bcd_make_root() and nexplay_bcd_open_url(). Per-game launch from NexPlay's library is 7.0.
// BCD: https://github.com/thebcd69/bcd-games (GPL-3.0 with BCD's additional terms and the Madeira Converter Exception).
// Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

extension SettingsKey {
    /// Load the Windows runtime when NexPlay starts (BCD sets itself up at launch: prefix, JIT watcher, controllers).
    static let windowsLoadAtLaunch = "windowsLoadAtLaunch"
}

struct WindowsRuntimeError: Error {
    let message: String
}

/// Where the runtime is and whether it loaded. Usable from any thread.
enum BCDRuntimeInfo {
    /// Set while dlopen runs. Still set at the next launch means loading crashed NexPlay: don't load at launch again.
    private static let loadingKey = "windowsRuntimeLoading"
    private static let lock = NSLock()
    private static var handle: UnsafeMutableRawPointer?
    private static var loadError: String?

    static var libraryURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("BCDCore.framework/BCDCore")
    }

    static var isPresent: Bool {
        guard let url = libraryURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The runtime release merged into this build (windows-runtime-<BCD tag>-<run>), or nil.
    static var version: String? {
        guard let url = Bundle.main.url(forResource: "WindowsRuntime", withExtension: "version"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Why the runtime can't be used on this iPhone, or nil.
    static var unavailableReason: String? {
        if !isPresent {
            return "This build has no Windows runtime. Run the \"Build Windows runtime\" workflow once, then build NexPlay again."
        }
        if #unavailable(iOS 18) {
            return "The Windows runtime needs iOS 18 or later."
        }
        return nil
    }

    static var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return handle != nil
    }

    static var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return loadError
    }

    /// True when the last load attempt never finished (NexPlay was closed or crashed while loading).
    static var lastLoadCrashed: Bool {
        UserDefaults.standard.bool(forKey: loadingKey)
    }

    /// Loads BCDCore once. Safe to call again; returns the dlopen handle.
    @discardableResult
    static func load() throws -> UnsafeMutableRawPointer {
        lock.lock(); defer { lock.unlock() }
        if let handle { return handle }
        if let reason = unavailableReason { throw WindowsRuntimeError(message: reason) }
        guard let path = libraryURL?.path else { throw WindowsRuntimeError(message: "No Frameworks folder in this build.") }
        AppLog.log("windows: loading runtime \(version ?? "unknown")")
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: loadingKey)
        defaults.synchronize()
        let start = Date()
        guard let opened = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            defaults.set(false, forKey: loadingKey)
            let detail = dlerror().map { String(cString: $0) } ?? "unknown error"
            loadError = "The Windows runtime didn't load: \(detail)"
            AppLog.log("windows: dlopen failed: \(detail)")
            throw WindowsRuntimeError(message: loadError ?? detail)
        }
        defaults.set(false, forKey: loadingKey)
        handle = opened
        loadError = nil
        AppLog.log(String(format: "windows: runtime loaded in %.2f s", Date().timeIntervalSince(start)))
        return opened
    }

    /// Called once at launch: loads the runtime when the setting is on, unless the last attempt crashed.
    static func loadAtLaunchIfWanted() {
        guard isPresent, UserDefaults.standard.bool(forKey: SettingsKey.windowsLoadAtLaunch) else { return }
        if lastLoadCrashed {
            UserDefaults.standard.set(false, forKey: SettingsKey.windowsLoadAtLaunch)
            UserDefaults.standard.set(false, forKey: loadingKey)
            AppLog.log("windows: last load didn't finish, so Load at Launch was turned off")
            return
        }
        try? load()
    }

    static func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        let handle = try load()
        guard let pointer = dlsym(handle, name) else {
            throw WindowsRuntimeError(message: "The Windows runtime has no \(name). Build it again with this NexPlay version.")
        }
        return pointer
    }
}

/// Shows BCD's interface and passes it links.
@MainActor
enum BCDBridge {
    private typealias MakeRoot = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias OpenURL = @convention(c) (UnsafePointer<CChar>?) -> Void

    private static var host: WindowsHostViewController?

    /// Presents BCD's interface over NexPlay. BCD's screen is made once and kept, so a running game survives closing it.
    static func show() throws {
        let controller = try hostController()
        guard let top = topViewController() else {
            throw WindowsRuntimeError(message: "NexPlay has no window to show Windows Games in.")
        }
        if controller.presentingViewController != nil { return }
        OrientationManager.lock(.auto)
        top.present(controller, animated: true)
    }

    /// Hands a link to BCD (for example madeira://play?exe=...), then shows it.
    static func open(_ url: URL) throws {
        try show()
        let function = unsafeBitCast(try BCDRuntimeInfo.symbol("nexplay_bcd_open_url"), to: OpenURL.self)
        url.absoluteString.withCString { function($0) }
    }

    private static func hostController() throws -> WindowsHostViewController {
        if let host { return host }
        let make = unsafeBitCast(try BCDRuntimeInfo.symbol("nexplay_bcd_make_root"), to: MakeRoot.self)
        guard let raw = make() else {
            throw WindowsRuntimeError(message: "The Windows runtime didn't make its screen.")
        }
        let root = Unmanaged<UIViewController>.fromOpaque(raw).takeRetainedValue()
        let controller = WindowsHostViewController(content: root)
        host = controller
        AppLog.log("windows: interface ready")
        return controller
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let next = top.presentedViewController { top = next }
        return top
    }
}

/// Full-screen holder for BCD's interface with a small button back to NexPlay.
final class WindowsHostViewController: UIViewController {
    private let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        let close = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { OrientationManager.unlock() }
        })
        close.accessibilityLabel = "Back to NexPlay"
        close.alpha = 0.7
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            close.widthAnchor.constraint(equalToConstant: 30),
            close.heightAnchor.constraint(equalToConstant: 30),
        ])
    }
}
