import SwiftUI
import UIKit

// 7.11.0 (SPEC-7.0 8.4): Performance HUD for web-view games. Turned on per game (Game Settings > Show Stats, the game
// menu, the Game Panel's Display tab). 8.3.2: BCD's HUD structure (BCDHUDCore: layouts Pulse, Strip, Tune, Report on a
// small plate in one of six places; nothing animates, never takes touches) with NexPlay's readings. Windows games show
// BCD's own HUD in the same layout (NexBCDHUD), which reads the engine's real frame times and GPU.

extension SettingsKey {
    static let hudCorner = "hudCorner"
    /// 8.3.2: the HUD's layout (`HUDLayout`), replaces hudDetail.
    static let hudLayout = "hudLayout"
    static let hudKeys: [String] = [hudCorner, hudLayout]
}

/// BCD's four finished layouts (BCDHUDLayout 1-4), same names and meaning.
enum HUDLayout: String, CaseIterable, Identifiable {
    case pulse, strip, tune, report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulse: return "Pulse"
        case .strip: return "Strip"
        case .tune: return "Tune"
        case .report: return "Report"
        }
    }

    var summary: String {
        switch self {
        case .pulse: return "One small number: the frame rate. A dot appears only if something is wrong."
        case .strip: return "One line: frame rate, frame time, memory and heat."
        case .tune: return "Three short lines and a 15 second graph: frame rate and its low, processor, memory, heat."
        case .report: return "The whole picture for a bug report: engine and size, frame rate with its lows, a 30 second graph, load, memory, heat, battery and time."
        }
    }

    /// BCD's raw value for the same layout (BCDHUDLayout).
    var bcdValue: String {
        switch self {
        case .pulse: return "1"
        case .strip: return "2"
        case .tune: return "3"
        case .report: return "4"
        }
    }

    static var current: HUDLayout {
        HUDLayout(rawValue: UserDefaults.standard.string(forKey: SettingsKey.hudLayout) ?? "") ?? .tune
    }
}

/// The six places of BCD's HUD (BCDHUDSlot), stored in hudCorner (older values topLeft... still work).
enum HUDPlace: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    static var current: HUDPlace {
        HUDPlace(rawValue: UserDefaults.standard.string(forKey: SettingsKey.hudCorner) ?? "") ?? .topLeft
    }
}

/// CPU and memory of NexPlay's own process (web content runs in a separate WebKit process, not counted here).
enum PerfSampler {
    static func cpuPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let list = threads else { return 0 }
        let threadCount = Int(count)
        var total: Double = 0
        for index in 0..<threadCount {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let capacity = Int(infoCount)
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                    thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO), raw, &infoCount)
                }
            }
            if result == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        // 8.20.1: task_threads hands over a send right per thread; without giving them back, the once-a-second HUD
        // leaked one port per thread per second until the app's port space ran out on long sessions.
        for index in 0..<threadCount { mach_port_deallocate(mach_task_self_, list[index]) }
        let bytes = vm_size_t(threadCount * MemoryLayout<thread_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), bytes)
        return total.isFinite ? total : 0
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    static var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Too hot"
        @unknown default: return "?"
        }
    }

    static var thermalColor: UIColor {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .systemGreen
        case .fair: return .systemYellow
        case .serious: return .systemOrange
        case .critical: return .systemRed
        @unknown default: return .white
        }
    }
}

/// The HUD's plate (UIKit, over the game; takes no touches). Call `update` about once a second.
final class PerformanceHUDView: UIView {
    private let labels: [UILabel] = (0..<4).map { _ in UILabel() }
    private let dot = UIView()
    private let graph = CAShapeLayer()
    private let graphBase = CAShapeLayer()
    private var samples: [Int] = []
    private var layoutNow = HUDLayout.tune
    private var showsGraph = false
    private var lineCount = 1
    private var plate = CGSize(width: 60, height: 22)
    /// The engine and the game's size, for Report ("MV · 816×624").
    var context: String?

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let rounded = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: rounded, size: size) }
        return base
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.55)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        for label in labels {
            label.textColor = .white
            label.font = Self.font(11, .semibold)
            addSubview(label)
        }
        dot.layer.cornerRadius = 3
        dot.isHidden = true
        addSubview(dot)
        graphBase.strokeColor = UIColor(white: 1, alpha: 0.15).cgColor
        graphBase.lineWidth = 1
        layer.addSublayer(graphBase)
        graph.strokeColor = UIColor(NexColor.dark(.accent)).cgColor
        graph.fillColor = UIColor.clear.cgColor
        graph.lineWidth = 1.5
        graph.lineJoin = .round
        layer.addSublayer(graph)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called once a second with the page's frame rate (nil when NexPlay can't measure it) and, when known, the
    /// longest frame of that second in ms.
    func update(fps: Int?, worstMs: Double? = nil) {
        layoutNow = HUDLayout.current
        if let fps {
            samples.append(fps)
            if samples.count > 30 { samples.removeFirst(samples.count - 30) }
        }
        let cpu = Int(PerfSampler.cpuPercent().rounded())
        let used = PerfSampler.footprintMB()
        let free = DeviceInfo.availableMemoryMB
        let thermal = ProcessInfo.processInfo.thermalState
        let window = layoutNow == .report ? 30 : 15
        let low = fps == nil ? nil : samples.suffix(window).min()
        let frameMs = fps.flatMap { $0 > 0 ? 1000 / Double($0) : nil }
        let rate = fps.map { "\($0) FPS" }
        let memory = "\(used) MB"
        let freeText = free >= 1024 ? String(format: "%.1f GB free", Double(free) / 1024) : "\(free) MB free"
        let level = UIDevice.current.batteryLevel
        let battery = level < 0 ? nil : "\(Int(level * 100))%"
        let warn = thermal == .serious || thermal == .critical || (fps.map { $0 > 0 && $0 < 24 } ?? false) || free < 300

        var lines: [(String, UIColor)] = []
        switch layoutNow {
        case .pulse:
            lines = [(fps.map { String($0) } ?? "CPU \(cpu)%", .white)]
        case .strip:
            let parts = [rate, frameMs.map { String(format: "%.1f ms", $0) }, memory, PerfSampler.thermalText].compactMap { $0 }
            lines = [(parts.joined(separator: " · "), .white)]
        case .tune:
            let first = [rate, low.map { "low \($0)" }, frameMs.map { String(format: "%.1f ms", $0) }].compactMap { $0 }
            lines = [
                (first.isEmpty ? "CPU \(cpu)% · \(memory)" : first.joined(separator: " · "), .white),
                (first.isEmpty ? freeText : "CPU \(cpu)% · \(memory) · \(freeText)", UIColor(white: 1, alpha: 0.85)),
                (PerfSampler.thermalText, PerfSampler.thermalColor),
            ]
        case .report:
            let first = [rate, low.map { "low \($0)" }, worstMs.map { String(format: "worst %.0f ms", $0) }].compactMap { $0 }
            let last = [PerfSampler.thermalText, battery, ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power" : nil,
                        Self.clock.string(from: Date())].compactMap { $0 }
            lines = [(context ?? "NexPlay", UIColor(white: 1, alpha: 0.7))]
            if !first.isEmpty { lines.append((first.joined(separator: " · "), .white)) }
            lines.append(("CPU \(cpu)% · \(memory) · \(freeText)", UIColor(white: 1, alpha: 0.85)))
            lines.append((last.joined(separator: " · "), PerfSampler.thermalColor))
        }
        lineCount = lines.count
        for (index, label) in labels.enumerated() {
            if index < lines.count {
                label.text = lines[index].0
                label.textColor = lines[index].1
                label.font = layoutNow == .pulse ? Self.font(13, .bold) : Self.font(11, .semibold)
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
        dot.isHidden = !(layoutNow == .pulse && warn)
        dot.backgroundColor = PerfSampler.thermalColor == .systemGreen ? .systemOrange : PerfSampler.thermalColor
        showsGraph = (layoutNow == .tune || layoutNow == .report) && samples.count > 1 && fps != nil
        graph.isHidden = !showsGraph
        graphBase.isHidden = !showsGraph

        let widest = labels.prefix(lines.count).map { $0.sizeThatFits(CGSize(width: 400, height: 20)).width }.max() ?? 40
        let lineHeight: CGFloat = layoutNow == .pulse ? 18 : 15
        var width = ceil(widest) + 14 + (dot.isHidden ? 0 : 10)
        if showsGraph { width = max(width, 190) }
        let height = CGFloat(lines.count) * lineHeight + 6 + (showsGraph ? 30 : 0)
        plate = CGSize(width: width, height: height)
        setNeedsLayout()
    }

    var preferredSize: CGSize { plate }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight: CGFloat = layoutNow == .pulse ? 18 : 15
        let width = bounds.width - 14
        for (index, label) in labels.enumerated() where index < lineCount {
            label.frame = CGRect(x: 7, y: 3 + CGFloat(index) * lineHeight, width: width - (dot.isHidden ? 0 : 10), height: lineHeight)
        }
        dot.frame = CGRect(x: bounds.width - 13, y: (bounds.height - 6) / 2, width: 6, height: 6)
        guard showsGraph else {
            graph.path = nil
            graphBase.path = nil
            return
        }
        let window = layoutNow == .report ? 30 : 15
        let shown = Array(samples.suffix(window))
        let rect = CGRect(x: 7, y: 6 + CGFloat(lineCount) * lineHeight, width: width, height: 22)
        let top = CGFloat(max(60, shown.max() ?? 60))
        let base = UIBezierPath()
        let sixty = rect.maxY - rect.height * 60 / top
        base.move(to: CGPoint(x: rect.minX, y: sixty))
        base.addLine(to: CGPoint(x: rect.maxX, y: sixty))
        graphBase.path = base.cgPath
        let path = UIBezierPath()
        for (index, value) in shown.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, window - 1))
            let y = rect.maxY - rect.height * CGFloat(value) / top
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        graph.path = path.cgPath
    }

    /// Puts the HUD in its place (one of six) in the safe area.
    func place(in bounds: CGRect, insets: UIEdgeInsets) {
        let size = preferredSize
        let place = HUDPlace.current
        let left = insets.left + 10
        let right = bounds.width - insets.right - 10 - size.width
        let center = (bounds.width - size.width) / 2
        let top = insets.top + 8
        let bottom = bounds.height - insets.bottom - 8 - size.height
        let x: CGFloat
        switch place {
        case .topLeft, .bottomLeft: x = left
        case .top, .bottom: x = center
        case .topRight, .bottomRight: x = right
        }
        let y = (place == .bottomLeft || place == .bottom || place == .bottomRight) ? bottom : top
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Settings > Gameplay & Performance > Performance HUD (8.3.2: BCD's layouts and places, for every engine).
struct HUDSettingsSection: View {
    @AppStorage(SettingsKey.hudCorner) private var corner = "topLeft"
    @AppStorage(SettingsKey.hudLayout) private var layout = "tune"

    var body: some View {
        Section {
            Picker("Layout", selection: $layout) {
                ForEach(HUDLayout.allCases) { item in Text(item.title).tag(item.rawValue) }
            }
            .pickerStyle(.segmented)
            Text((HUDLayout(rawValue: layout) ?? .tune).summary)
                .font(NexType.caption)
                .foregroundStyle(.secondary)
            Picker("Place", selection: $corner) {
                ForEach(HUDPlace.allCases) { item in Text(item.title).tag(item.rawValue) }
            }
        } header: {
            SettingsHeader(title: "Performance HUD", symbol: "speedometer", color: .green)
        } footer: {
            Text("Turn it on per game with Show Stats (Game Panel > Display, the game menu or Game Settings). The layouts are BCD's. Windows games use BCD's own HUD in the same layout, with the engine's real frame times; in web games CPU and memory are NexPlay's own process (the page runs in WebKit's process).")
        }
    }
}
