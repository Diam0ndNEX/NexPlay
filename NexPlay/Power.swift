import SwiftUI
import UIKit
import WebKit

// 7.2.0 Power profiles (SPEC-7.0-review, Phase 4):
// - Battery Saver (30 FPS), Balanced (60 FPS, default), Performance (no cap). Global default in Settings >
//   Gameplay & Performance, per game in the Game Panel (AssistOptions.power, "" = app default).
// - The cap is a requestAnimationFrame limiter installed before every other page script, so it sees the browser's
//   own frame times (several loops in one frame all run). RPG Maker MV/MZ keep their game speed: they repeat updates
//   by elapsed time.
// - Thermal guard: at .serious the player offers Battery Saver once per game; at .critical it pauses the game.
// - Idle pause: no touch, key, wheel or gamepad input for N minutes pauses the game and dims the screen; a tap goes
//   on. Off for Ren'Py, Tyrano and Twine and when RPG Maker auto-advance is on.
// Web-view games only (MV/MZ and the web engines). Windows, EasyRPG and the Ruby core are not covered yet.

extension SettingsKey {
    /// PowerProfile raw value, the default for games without their own choice.
    static let powerProfile = "powerProfile"
    /// Minutes without input before a game pauses; 0 is off.
    static let idlePauseMinutes = "idlePauseMinutes"
    /// Offer Battery Saver when the device gets hot, pause when it is critical.
    static let thermalGuard = "thermalGuard"
    /// Cleared by Reset to Defaults.
    static let powerKeys: [String] = [powerProfile, idlePauseMinutes, thermalGuard]
}

enum PowerProfile: String, CaseIterable, Identifiable {
    case saver, balanced, performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saver: return "Battery Saver"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        }
    }

    var shortTitle: String {
        switch self {
        case .saver: return "Saver"
        case .balanced: return "Balanced"
        case .performance: return "Max"
        }
    }

    var symbol: String {
        switch self {
        case .saver: return "leaf.fill"
        case .balanced: return "gauge.medium"
        case .performance: return "bolt.fill"
        }
    }

    /// Frame cap; 0 is no cap.
    var fps: Int {
        switch self {
        case .saver: return 30
        case .balanced: return 60
        case .performance: return 0
        }
    }

    var detail: String {
        switch self {
        case .saver: return "30 FPS. Much less battery and heat; fine for visual novels and turn-based games."
        case .balanced: return "60 FPS, what most games are made for."
        case .performance: return "No frame cap. Uses the most battery."
        }
    }

    static var appDefault: PowerProfile {
        PowerProfile(rawValue: UserDefaults.standard.string(forKey: SettingsKey.powerProfile) ?? "") ?? .balanced
    }

    /// The game's own choice, else the app default.
    static func effective(for gameID: UUID) -> PowerProfile {
        let own = AssistOptions.load(for: gameID).power
        return PowerProfile(rawValue: own) ?? appDefault
    }
}

enum PowerScripts {
    /// Frame limiter and idle watch. Must run before WebTools.timeScript (it wraps the real requestAnimationFrame).
    static let script = #"""
    (function () {
        var P = window.__nexPower = window.__nexPower || {};
        if (P.ready) return;
        P.ready = true;
        P.interval = 0;
        P.idleMinutes = 0;
        P.idle = false;

        var realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
        var realCancel = window.cancelAnimationFrame ? window.cancelAnimationFrame.bind(window) : null;
        if (realRAF) {
            var gate = -1, nextId = 1, live = {};
            window.requestAnimationFrame = function (callback) {
                var id = nextId++;
                var tick = function (t) {
                    if (!(id in live)) return;
                    var iv = P.interval;
                    if (iv > 0 && gate >= 0 && t !== gate && t > gate && t - gate < iv - 3) {
                        live[id] = realRAF(tick);
                        return;
                    }
                    if (t !== gate) gate = t;
                    delete live[id];
                    callback(t);
                };
                live[id] = realRAF(tick);
                return id;
            };
            window.cancelAnimationFrame = function (id) {
                if (id in live) {
                    if (realCancel) realCancel(live[id]);
                    delete live[id];
                }
            };
        }
        P.setFPS = function (fps) {
            fps = Number(fps);
            P.interval = fps > 0 ? 1000 / fps : 0;
            return fps;
        };

        var dateNow = Date.now.bind(Date);
        var every = window.setInterval.bind(window);
        var lastInput = dateNow();
        function touched() { if (!P.idle) lastInput = dateNow(); }
        ['touchstart', 'pointerdown', 'mousedown', 'keydown', 'wheel'].forEach(function (name) {
            window.addEventListener(name, touched, true);
        });
        var padStamp = 0;
        function padActivity() {
            if (!navigator.getGamepads) return;
            var pads, sum = 0;
            try { pads = navigator.getGamepads(); } catch (e) { return; }
            for (var i = 0; pads && i < pads.length; i++) {
                if (pads[i]) sum += pads[i].timestamp || 0;
            }
            if (sum !== padStamp) { padStamp = sum; touched(); }
        }
        every(function () {
            padActivity();
            if (P.idle || !(P.idleMinutes > 0)) return;
            if (dateNow() - lastInput < P.idleMinutes * 60000) return;
            P.idle = true;
            if (window.__nex && window.__nex.pause) window.__nex.pause();
            try { window.webkit.messageHandlers.nexIdle.postMessage('idle'); } catch (e) {}
        }, 5000);
        P.setIdle = function (minutes) { P.idleMinutes = Number(minutes) || 0; lastInput = dateNow(); };
        P.wake = function () {
            P.idle = false;
            lastInput = dateNow();
            if (window.__nex && window.__nex.resume) window.__nex.resume();
        };
    })();
    """#
}

/// Owned by GamePanelFeature (which forwards scripts, messages, load and shutdown).
@MainActor
final class PowerFeature: PlayerFeature {
    private(set) var profile: PowerProfile = .balanced
    private var observers: [NSObjectProtocol] = []
    private var offeredSaver = false
    private var pausedForHeat = false
    private weak var idleOverlay: UIView?

    override init(context: PlayerContext) {
        super.init(context: context)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermalChanged() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reapplyPauseAfterResume() }
        })
    }

    override func userScripts(for game: Game) -> [WKUserScript] {
        [WKUserScript(source: PowerScripts.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
    }

    override var messageNames: [String] { ["nexIdle"] }

    override func receive(name: String, body: Any) {
        guard name == "nexIdle" else { return }
        context.gameLog.add("idle pause")
        showIdleOverlay()
    }

    override func didFinishLoad() {
        let game = context.game()
        profile = PowerProfile.effective(for: game.id)
        applyProfile()
        context.evaluate("window.__nexPower && window.__nexPower.setIdle(\(idleMinutes(for: game)))")
        removeIdleOverlay()
        thermalChanged()
    }

    override func shutdown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        removeIdleOverlay()
    }

    // MARK: Profile

    /// nil = follow the app default.
    func choose(_ choice: PowerProfile?) {
        let id = context.game().id
        var options = AssistOptions.load(for: id)
        options.power = choice?.rawValue ?? ""
        options.save(for: id)
        profile = choice ?? PowerProfile.appDefault
        applyProfile()
    }

    var gameChoice: PowerProfile? {
        PowerProfile(rawValue: AssistOptions.load(for: context.game().id).power)
    }

    private func applyProfile() {
        context.evaluate("window.__nexPower && window.__nexPower.setFPS(\(profile.fps))")
        context.gameLog.add("power: \(profile.title) (\(profile.fps == 0 ? "no cap" : "\(profile.fps) FPS"))")
    }

    // MARK: Idle

    private func idleMinutes(for game: Game) -> Int {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.idlePauseMinutes)
        if minutes <= 0 { return 0 }
        switch game.engine {
        case .renpy, .tyrano, .twine:
            return 0
        default:
            break
        }
        if game.engine.isRPGMaker && AssistOptions.load(for: game.id).autoAdvance > 0 { return 0 }
        return minutes
    }

    private func showIdleOverlay() {
        guard idleOverlay == nil, let webView = context.webView, let host = webView.superview else { return }
        let overlay = UIControl(frame: host.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        let label = UILabel()
        label.text = "Paused while you were away\nTap to keep playing"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
        ])
        overlay.addAction(UIAction { [weak self] _ in self?.wakeTapped() }, for: .touchUpInside)
        host.addSubview(overlay)
        idleOverlay = overlay
    }

    private func wakeTapped() {
        removeIdleOverlay()
        pausedForHeat = false
        context.evaluate("window.__nexPower && window.__nexPower.wake()")
        context.gameLog.add("idle pause ended")
    }

    private func removeIdleOverlay() {
        idleOverlay?.removeFromSuperview()
        idleOverlay = nil
    }

    /// Coming back from the background resumes every game; keep it paused while the idle screen is up.
    private func reapplyPauseAfterResume() {
        guard idleOverlay != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.idleOverlay != nil else { return }
            self.context.evaluate("window.__nex && window.__nex.pause && window.__nex.pause()")
        }
    }

    // MARK: Thermal guard

    private func thermalChanged() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.thermalGuard) else { return }
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .critical:
            guard !pausedForHeat else { return }
            pausedForHeat = true
            context.gameLog.add("thermal: critical, game paused")
            context.evaluate("window.__nex && window.__nex.pause && window.__nex.pause()")
            if idleOverlay == nil {
                showIdleOverlay()
                (idleOverlay?.subviews.first as? UILabel)?.text = "Your iPhone is very hot\nThe game is paused. Tap to go on."
            }
        case .serious:
            guard !offeredSaver, profile != .saver else { return }
            offeredSaver = true
            context.gameLog.add("thermal: serious, offered Battery Saver")
            let alert = UIAlertController(title: "iPhone Is Getting Hot",
                                          message: "Battery Saver caps this game at 30 FPS, which cools the phone down.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Use Battery Saver", style: .default) { [weak self] _ in
                self?.choose(.saver)
            })
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
            context.present(alert)
        default:
            break
        }
    }
}

// MARK: - Settings

struct PowerSettingsSection: View {
    @AppStorage(SettingsKey.powerProfile) private var profile = PowerProfile.balanced.rawValue
    @AppStorage(SettingsKey.idlePauseMinutes) private var idleMinutes = 10
    @AppStorage(SettingsKey.thermalGuard) private var thermalGuard = true

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SettingLabel("Power Profile", (PowerProfile(rawValue: profile) ?? .balanced).detail)
                Picker("Power Profile", selection: $profile) {
                    ForEach(PowerProfile.allCases) { item in Text(item.shortTitle).tag(item.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Picker(selection: $idleMinutes) {
                Text("Off").tag(0)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
                Text("20 min").tag(20)
                Text("30 min").tag(30)
            } label: {
                SettingLabel("Idle Pause", "Pause and dim a game after this long without input. Not for visual novels or auto-advance.")
            }
            Toggle(isOn: $thermalGuard) {
                SettingLabel("Thermal Guard", "Offer Battery Saver when the iPhone gets hot, and pause the game if it gets very hot.")
            }
        } header: {
            Text("Power")
        } footer: {
            Text("Each game can choose its own profile in the Game Panel. Applies to RPG Maker MV/MZ and web games.")
        }
    }
}
