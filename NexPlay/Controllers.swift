import CoreHaptics
import GameController
import SwiftUI
import WebKit

// 8.2.2: one controller system for every engine. Ideas from BCD's controller hub (BCDControllerHub.swift, BCDControllerScreen.swift:
// which pads are connected, players, a live tester, rumble); NexPlay's own code, compiled in every build.
// - `NexControllerHub`: the connected controllers in player order. NexPlay sets GCController.playerIndex from that order (the
//   player lights on the pads); NexPlay's key mapping (PhysicalControllers.swift, Only Player 1) and rumble use it. BCD's XInput
//   slots for Windows games are BCD's own (GamepadInput.swift); not changed. Rumble through each pad's own haptics engine.
// - `RumbleFeature`: web-view games' rumble (Gamepad API vibrationActuator.playEffect / hapticActuators[0].pulse) on the pad.
// - `ControllersView`: Settings > Controls > Controllers: players, battery, Make Player 1, Test Rumble, live tester, button mapping.
// Windows games keep BCD's XInput (several players, rumble, its in-game menu's controller options).

extension SettingsKey {
    static let controllerRumble = "controllerRumble"
    static let controllerKeysPlayerOne = "controllerKeysPlayerOne"
    static let controllerKeys: [String] = [controllerRumble, controllerKeysPlayerOne]
}

struct NexPad: Identifiable, Equatable {
    let id: ObjectIdentifier
    let name: String
    let family: String
    let symbol: String
    let player: Int
    let battery: Float?
    let charging: Bool
    let hasRumble: Bool
}

@MainActor
final class NexControllerHub: ObservableObject {
    static let shared = NexControllerHub()

    @Published private(set) var pads: [NexPad] = []
    /// The live tester (only while a tester is on screen).
    @Published private(set) var reading = Reading()

    struct Reading: Equatable {
        var left = CGPoint.zero
        var right = CGPoint.zero
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var pressed: [String] = []
    }

    /// Player order: the first is Player 1.
    private var order: [GCController] = []
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    private var players: [ObjectIdentifier: CHHapticPatternPlayer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var testerTimer: Timer?
    private var started = false

    private init() {}

    /// Called once at launch (NexPlayApp). Watches connections; costs nothing while nothing connects.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.connected(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.disconnected(controller) }
        })
        GCController.controllers().forEach(connected)
    }

    var playerOne: GCController? { order.first }

    /// The pad of a player (0 = Player 1), in hub order.
    func controller(player: Int) -> GCController? {
        player >= 0 && player < order.count ? order[player] : nil
    }

    private func connected(_ controller: GCController) {
        guard !order.contains(where: { $0 === controller }) else { return }
        order.append(controller)
        AppLog.log("controllers: \(controller.vendorName ?? "controller") connected as player \(order.count)")
        assignPlayers()
    }

    private func disconnected(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        order.removeAll { $0 === controller }
        engines[id]?.stop()
        engines[id] = nil
        players[id] = nil
        assignPlayers()
    }

    /// Moves a pad to Player 1.
    func makePlayerOne(_ id: ObjectIdentifier) {
        guard let index = order.firstIndex(where: { ObjectIdentifier($0) == id }), index > 0 else { return }
        let pad = order.remove(at: index)
        order.insert(pad, at: 0)
        assignPlayers()
        NexHaptics.success()
        rumble(pad, strong: 0.6, weak: 0.3, seconds: 0.25)
    }

    private func assignPlayers() {
        let indices: [GCControllerPlayerIndex] = [.index1, .index2, .index3, .index4]
        for (i, pad) in order.enumerated() {
            pad.playerIndex = i < indices.count ? indices[i] : .indexUnset
        }
        refresh()
    }

    func refresh() {
        pads = order.enumerated().map { index, pad in
            NexPad(id: ObjectIdentifier(pad), name: pad.vendorName ?? "Controller", family: Self.family(pad),
                   symbol: Self.symbol(pad), player: index + 1, battery: pad.battery?.batteryLevel,
                   charging: pad.battery?.batteryState == .charging, hasRumble: pad.haptics != nil)
        }
    }

    static func family(_ pad: GCController) -> String {
        let category = pad.productCategory.lowercased()
        if category.contains("dualsense") || category.contains("dualshock") { return "PlayStation" }
        if category.contains("xbox") { return "Xbox" }
        if category.contains("switch") || category.contains("joy-con") { return "Nintendo" }
        if pad.extendedGamepad != nil { return "Controller" }
        return "Basic controller"
    }

    static func symbol(_ pad: GCController) -> String {
        switch family(pad) {
        case "PlayStation": return "playstation.logo"
        case "Xbox": return "xbox.logo"
        default: return "gamecontroller.fill"
        }
    }

    // MARK: Rumble

    /// Rumble on a pad: `strong` (low-frequency motor) and `weak` (high-frequency) 0...1, for `seconds`.
    func rumble(_ pad: GCController, strong: Double, weak: Double, seconds: Double) {
        guard let haptics = pad.haptics else { return }
        let id = ObjectIdentifier(pad)
        let engine: CHHapticEngine
        if let made = engines[id] {
            engine = made
        } else {
            guard let made = haptics.createEngine(withLocality: .default) else { return }
            made.playsHapticsOnly = true
            made.resetHandler = { [weak made] in try? made?.start() }
            engines[id] = made
            engine = made
        }
        let intensity = Float(min(max(max(strong, weak), 0), 1))
        try? players[id]?.stop(atTime: CHHapticTimeImmediate)
        players[id] = nil
        guard intensity > 0.01, seconds > 0 else { return }
        let sharpness = Float(strong + weak > 0 ? weak / (strong + weak) : 0.5)
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
                                  relativeTime: 0, duration: min(seconds, 5))
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            players[id] = player
        } catch {
            AppLog.log("controllers: rumble failed: \(error.localizedDescription)")
        }
    }

    func testRumble(_ id: ObjectIdentifier) {
        guard let pad = order.first(where: { ObjectIdentifier($0) == id }) else { return }
        rumble(pad, strong: 1, weak: 0.4, seconds: 0.4)
    }

    // MARK: Tester

    func watchTester(_ on: Bool) {
        testerTimer?.invalidate()
        testerTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleTester() }
        }
        RunLoop.main.add(timer, forMode: .common)
        testerTimer = timer
    }

    private func sampleTester() {
        guard let pad = order.first?.extendedGamepad else {
            if reading != Reading() { reading = Reading() }
            return
        }
        var next = Reading()
        next.left = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        next.right = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
        next.leftTrigger = pad.leftTrigger.value
        next.rightTrigger = pad.rightTrigger.value
        var pressed: [String] = []
        var buttons: [(GCControllerButtonInput, String)] = [
            (pad.buttonA, "A"), (pad.buttonB, "B"), (pad.buttonX, "X"), (pad.buttonY, "Y"),
            (pad.leftShoulder, "L1"), (pad.rightShoulder, "R1"), (pad.buttonMenu, "Menu"),
            (pad.dpad.up, "↑"), (pad.dpad.down, "↓"), (pad.dpad.left, "←"), (pad.dpad.right, "→"),
        ]
        if let options = pad.buttonOptions { buttons.append((options, "Options")) }
        if let l3 = pad.leftThumbstickButton { buttons.append((l3, "L3")) }
        if let r3 = pad.rightThumbstickButton { buttons.append((r3, "R3")) }
        for (button, name) in buttons where button.isPressed { pressed.append(name) }
        next.pressed = pressed
        if next != reading { reading = next }
    }
}

// MARK: - Rumble for web-view games

enum ControllerScripts {
    /// Gives every Gamepad a vibrationActuator (and hapticActuators) that WebKit lacks, posting `nexRumble`. Gamepads that
    /// already have one keep theirs. navigator.getGamepads itself is left alone (CLAUDE.md rule).
    static let rumble = #"""
    (function () {
        if (window.__nexRumble || typeof Gamepad === 'undefined') return;
        window.__nexRumble = true;
        function post(index, strong, weak, ms) {
            try { window.webkit.messageHandlers.nexRumble.postMessage({ index: index, strong: strong, weak: weak, ms: ms }); } catch (e) {}
        }
        function actuatorFor(pad) {
            return {
                type: 'dual-rumble',
                effects: ['dual-rumble'],
                canPlayEffectType: function (t) { return t === 'dual-rumble'; },
                playEffect: function (type, p) {
                    p = p || {};
                    var delay = p.startDelay || 0;
                    setTimeout(function () {
                        post(pad.index, p.strongMagnitude || 0, p.weakMagnitude || 0, p.duration || 200);
                    }, delay);
                    return Promise.resolve('complete');
                },
                reset: function () { post(pad.index, 0, 0, 0); return Promise.resolve('complete'); },
                pulse: function (value, ms) { post(pad.index, value || 0, value || 0, ms || 200); return Promise.resolve(true); }
            };
        }
        var proto = Gamepad.prototype;
        var own = Object.getOwnPropertyDescriptor(proto, 'vibrationActuator');
        if (!own) {
            Object.defineProperty(proto, 'vibrationActuator', {
                configurable: true,
                get: function () { return this.__nexAct || (this.__nexAct = actuatorFor(this)); }
            });
        }
        if (!Object.getOwnPropertyDescriptor(proto, 'hapticActuators')) {
            Object.defineProperty(proto, 'hapticActuators', {
                configurable: true,
                get: function () { return [this.vibrationActuator]; }
            });
        }
    })();
    """#
}

/// Plays a web game's rumble on the pad of that Gamepad index (Setting: Controls > Controllers > Rumble in Games).
@MainActor
final class RumbleFeature: PlayerFeature {
    override func userScripts(for game: Game) -> [WKUserScript] {
        guard UserDefaults.standard.bool(forKey: SettingsKey.controllerRumble) else { return [] }
        return [WKUserScript(source: ControllerScripts.rumble, injectionTime: .atDocumentStart, forMainFrameOnly: false)]
    }

    override var messageNames: [String] {
        UserDefaults.standard.bool(forKey: SettingsKey.controllerRumble) ? ["nexRumble"] : []
    }

    override func receive(name: String, body: Any) {
        guard name == "nexRumble", let info = body as? [String: Any] else { return }
        let index = (info["index"] as? NSNumber)?.intValue ?? 0
        let strong = (info["strong"] as? NSNumber)?.doubleValue ?? 0
        let weak = (info["weak"] as? NSNumber)?.doubleValue ?? 0
        let ms = (info["ms"] as? NSNumber)?.doubleValue ?? 0
        let hub = NexControllerHub.shared
        guard let pad = hub.controller(player: index) ?? hub.playerOne else { return }
        hub.rumble(pad, strong: strong, weak: weak, seconds: ms / 1000)
    }

    override func shutdown() {
        for pad in GCController.controllers() {
            NexControllerHub.shared.rumble(pad, strong: 0, weak: 0, seconds: 0)
        }
    }
}

// MARK: - Settings screen

struct ControllersView: View {
    @ObservedObject private var hub = NexControllerHub.shared
    @AppStorage(SettingsKey.controllerRumble) private var rumble = true
    @AppStorage(SettingsKey.controllerKeysPlayerOne) private var playerOneOnly = false
    @State private var showMap = false

    var body: some View {
        ScrollView {
            VStack(spacing: NexMetrics.spacingL) {
                VStack(alignment: .leading, spacing: NexMetrics.spacingM) {
                    Label("Connected", systemImage: "gamecontroller.fill").font(NexType.heading)
                    if hub.pads.isEmpty {
                        Text("No controller is connected. Pair one in the iPhone's Settings > Bluetooth.")
                            .font(NexType.body).foregroundStyle(NexColor.textSoft)
                    }
                    ForEach(hub.pads) { pad in padRow(pad) }
                    Text("NexPlay sets the player lights in this order. Player 1 is the pad NexPlay's button mapping and rumble use. Windows games give out their XInput slots themselves (BCD).")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nexCard()

                if !hub.pads.isEmpty {
                    VStack(alignment: .leading, spacing: NexMetrics.spacingM) {
                        Label("Tester (Player 1)", systemImage: "scope").font(NexType.heading)
                        ControllerTesterView(reading: hub.reading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nexCard()
                }

                VStack(alignment: .leading, spacing: NexMetrics.spacingM) {
                    Label("In Games", systemImage: "slider.horizontal.3").font(NexType.heading)
                    Toggle(isOn: $rumble) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rumble").font(NexType.label)
                            Text("Web games that rumble the controller (Gamepad API) shake your pad. Windows games rumble through BCD's XInput.")
                                .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        }
                    }
                    .tint(NexColor.accent)
                    Toggle(isOn: $playerOneOnly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only Player 1 Presses Keys").font(NexType.label)
                            Text("With several pads, only Player 1 is turned into keys (Send Keys mode). Games that read controllers still see every pad.")
                                .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        }
                    }
                    .tint(NexColor.accent)
                    Button {
                        showMap = true
                    } label: {
                        Label("Button Mapping", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Windows games: several players, rumble and controller-as-keyboard are in the game's in-game menu (BCD).")
                        .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nexCard()
            }
            .padding(NexMetrics.spacingL)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle("Controllers")
        .navigationBarTitleDisplayMode(.inline)
        .fontDesign(.rounded)
        .onAppear {
            hub.refresh()
            hub.watchTester(true)
        }
        .onDisappear { hub.watchTester(false) }
        .sheet(isPresented: $showMap) { ControllerMapView(gameID: nil, gameName: nil) }
    }

    private func padRow(_ pad: NexPad) -> some View {
        HStack(spacing: NexMetrics.spacingM) {
            Image(systemName: pad.symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 40, height: 40)
                .nexGlass(in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(pad.name).font(NexType.label).foregroundStyle(NexColor.text)
                HStack(spacing: 6) {
                    Text("Player \(pad.player)").font(NexType.captionStrong).foregroundStyle(NexColor.accent)
                    Text(pad.family).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                    if let battery = pad.battery {
                        Label("\(Int((battery * 100).rounded()))%", systemImage: pad.charging ? "battery.100.bolt" : "battery.75")
                            .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                    }
                }
            }
            Spacer()
            Menu {
                if pad.player > 1 {
                    Button { hub.makePlayerOne(pad.id) } label: { Label("Make Player 1", systemImage: "1.circle") }
                }
                if pad.hasRumble {
                    Button { hub.testRumble(pad.id) } label: { Label("Test Rumble", systemImage: "waveform") }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 36).nexGlass(in: Circle(), interactive: true)
            }
        }
    }
}

/// Both sticks, both triggers and the buttons held, for Player 1.
struct ControllerTesterView: View {
    let reading: NexControllerHub.Reading

    var body: some View {
        VStack(spacing: NexMetrics.spacingM) {
            HStack(spacing: NexMetrics.spacingL) {
                stick(reading.left, "Left")
                VStack(spacing: 8) {
                    trigger(reading.leftTrigger, "L2")
                    trigger(reading.rightTrigger, "R2")
                }
                stick(reading.right, "Right")
            }
            Text(reading.pressed.isEmpty ? "Press a button" : reading.pressed.joined(separator: "  "))
                .font(NexType.number)
                .foregroundStyle(reading.pressed.isEmpty ? NexColor.textSoft : NexColor.text)
                .frame(maxWidth: .infinity)
        }
    }

    private func stick(_ point: CGPoint, _ title: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(NexColor.stroke, lineWidth: 2)
                Circle().fill(NexColor.accent)
                    .frame(width: 16, height: 16)
                    .offset(x: point.x * 26, y: -point.y * 26)
            }
            .frame(width: 70, height: 70)
            Text(title).font(NexType.caption).foregroundStyle(NexColor.textSoft)
        }
    }

    private func trigger(_ value: Float, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(NexType.captionStrong).frame(width: 24)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NexColor.stroke)
                    Capsule().fill(NexColor.accent).frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 8)
        }
        .frame(width: 110)
    }
}
