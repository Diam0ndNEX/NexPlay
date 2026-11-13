import SwiftUI
import UIKit

// 7.11.0 (SPEC-7.0 8.4): Performance HUD for web-view games: FPS with a graph of the last minute, CPU %, memory
// used / available, thermal state, battery and time. Turned on per game (Game Settings > Show Stats or the game
// menu); Settings > Gameplay & Performance sets the corner and how much it shows.

extension SettingsKey {
    static let hudCorner = "hudCorner"
    static let hudDetail = "hudDetail"
    static let hudKeys: [String] = [hudCorner, hudDetail]
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
        let bytes = vm_size_t(threadCount * MemoryLayout<thread_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), bytes)
        return total
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

final class PerformanceHUDView: UIView {
    private let line1 = UILabel()
    private let line2 = UILabel()
    private let graph = CAShapeLayer()
    private var samples: [Int] = []
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var full: Bool { UserDefaults.standard.string(forKey: SettingsKey.hudDetail) != "compact" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.6)
        layer.cornerRadius = 10
        clipsToBounds = true
        isUserInteractionEnabled = false
        for label in [line1, line2] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            addSubview(label)
        }
        graph.strokeColor = UIColor(red: 0.62, green: 0.48, blue: 1, alpha: 1).cgColor
        graph.fillColor = UIColor.clear.cgColor
        graph.lineWidth = 1.5
        layer.addSublayer(graph)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called once a second with the page's frame rate.
    func update(fps: Int) {
        samples.append(fps)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        let cpu = Int(PerfSampler.cpuPercent().rounded())
        let used = PerfSampler.footprintMB()
        line1.text = "\(fps) FPS · CPU \(cpu)% · \(used) MB"
        if full {
            let level = UIDevice.current.batteryLevel
            let battery = level < 0 ? "--" : "\(Int(level * 100))%"
            line2.text = "\(PerfSampler.thermalText) · \(DeviceInfo.availableMemoryMB) MB free · \(battery) · \(PerformanceHUDView.clock.string(from: Date()))"
            line2.textColor = PerfSampler.thermalColor
        }
        line2.isHidden = !full
        graph.isHidden = !full
        setNeedsLayout()
    }

    var preferredSize: CGSize {
        full ? CGSize(width: 250, height: 76) : CGSize(width: 190, height: 22)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width - 12
        line1.frame = CGRect(x: 6, y: 3, width: width, height: 16)
        line2.frame = CGRect(x: 6, y: 19, width: width, height: 16)
        guard full, samples.count > 1 else {
            graph.path = nil
            return
        }
        let rect = CGRect(x: 6, y: 38, width: width, height: bounds.height - 42)
        let top = max(60, samples.max() ?? 60)
        let path = UIBezierPath()
        for (index, value) in samples.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, samples.count - 1))
            let y = rect.maxY - rect.height * CGFloat(value) / CGFloat(top)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        graph.path = path.cgPath
    }

    /// Puts the HUD in the chosen corner of the safe area.
    func place(in bounds: CGRect, insets: UIEdgeInsets) {
        let size = preferredSize
        let corner = UserDefaults.standard.string(forKey: SettingsKey.hudCorner) ?? "topLeft"
        let left = insets.left + 10
        let right = bounds.width - insets.right - 10 - size.width
        let top = insets.top + 8
        let bottom = bounds.height - insets.bottom - 8 - size.height
        let x = corner.hasSuffix("Right") ? right : left
        let y = corner.hasPrefix("bottom") ? bottom : top
        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Settings > Gameplay & Performance > Performance HUD.
struct HUDSettingsSection: View {
    @AppStorage(SettingsKey.hudCorner) private var corner = "topLeft"
    @AppStorage(SettingsKey.hudDetail) private var detail = "full"

    var body: some View {
        Section {
            Picker("Corner", selection: $corner) {
                Text("Top Left").tag("topLeft")
                Text("Top Right").tag("topRight")
                Text("Bottom Left").tag("bottomLeft")
                Text("Bottom Right").tag("bottomRight")
            }
            Picker("Detail", selection: $detail) {
                Text("Compact").tag("compact")
                Text("Full").tag("full")
            }
            .pickerStyle(.segmented)
        } header: {
            SettingsHeader(title: "Performance HUD", symbol: "speedometer", color: .green)
        } footer: {
            Text("Turn it on per game with Show Stats (game menu or Game Settings). Full adds a frame-rate graph, temperature, free memory, battery and time. CPU and memory are NexPlay's own process; the game's page runs in WebKit's process.")
        }
    }
}
