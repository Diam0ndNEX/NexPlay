import UIKit
import WebKit

/// Keeps the last lines a game page reported: console output, script errors and files that failed to load.
/// This is how you debug a game from an iPhone with no Mac.
final class GameLog {
    private(set) var lines: [String] = []
    private let limit = 500
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 8.8.2: every line is also written to a file, so the exported logs ZIP has the game's log (the one for the game
    /// that ran last and the one before it).
    static var fileURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NexPlay-game.log") }
    static var previousFileURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NexPlay-game.prev.log") }
    private var handle: FileHandle?

    init() {
        let fm = FileManager.default
        try? fm.removeItem(at: GameLog.previousFileURL)
        try? fm.moveItem(at: GameLog.fileURL, to: GameLog.previousFileURL)
        fm.createFile(atPath: GameLog.fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: GameLog.fileURL)
    }

    deinit { try? handle?.close() }

    /// 8.11.1: a line that repeats (a C# exception thrown every frame printed 5 lines 60 times a second and pushed the
    /// start of the game out of the exported log) is written 25 times per 10 seconds; after that only a count.
    private var repeats: [String: (count: Int, since: Date)] = [:]

    func add(_ text: String) {
        let now = Date()
        var entry = repeats[text] ?? (count: 0, since: now)
        if now.timeIntervalSince(entry.since) > 10 {
            if entry.count > 25 { write("(the line above came \(entry.count - 25) more times in 10 seconds)", now) }
            entry = (count: 0, since: now)
        }
        entry.count += 1
        repeats[text] = entry
        if repeats.count > 2000 { repeats.removeAll() }
        if entry.count > 25 { return }
        write(text, now)
    }

    private func write(_ text: String, _ date: Date) {
        let line = "\(GameLog.formatter.string(from: date))  \(text)"
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
    }

    var text: String { lines.joined(separator: "\n") }
}

/// Receives the lines the diagnostics script reports.
final class LogReceiver: NSObject, WKScriptMessageHandler {
    var onLine: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String { onLine?(text) }
    }
}

/// Shows a log with a share button, so a log can be sent along with a bug report.
/// Used for a game's log and for the app log.
final class LogViewController: UIViewController {
    private let textProvider: () -> String
    private let emptyText: String
    private let textView = UITextView()

    init(log: GameLog, gameName: String) {
        self.textProvider = { log.text }
        self.emptyText = "Nothing logged yet. Console output, script errors and files that failed to load show up here."
        super.init(nibName: nil, bundle: nil)
        title = gameName
    }

    init(title: String, emptyText: String, text: @escaping () -> String) {
        self.textProvider = text
        self.emptyText = emptyText
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let current = textProvider()
        textView.text = current.isEmpty ? emptyText : current
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share))
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func share() {
        let sheet = UIActivityViewController(activityItems: [textProvider()], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }
}
