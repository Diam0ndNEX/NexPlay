import UIKit

// 7.10.0 (SPEC-7.0 8.6): one loading screen for every runtime (blurred game art, stage, spinner, expandable log,
// Cancel) that turns into an error card (what happened, why, what to try) when starting fails.
// Crash-safe launch (SPEC-7.0-review C9): `LaunchGuard` notes the game being started; if NexPlay dies before the game
// ran 20 seconds, the next launch marks the game "crashed at start" on that runtime.

/// A button on the error card.
struct LoadingAction {
    let title: String
    let symbol: String
    let primary: Bool
    let handler: () -> Void

    init(_ title: String, symbol: String, primary: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.handler = handler
    }
}

final class LoadingScreenView: UIView {
    var onCancel: (() -> Void)?

    private let art = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let card = UIStackView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let stageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let detailLabel = UILabel()
    private let logView = UITextView()
    private let logButton = UIButton(type: .system)
    private let actionsStack = UIStackView()
    private let cancelButton = UIButton(type: .system)
    private var logLines: [String] = []
    private var logOpen = false
    private(set) var isShowingError = false

    init(gameName: String, art image: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = .black

        art.image = image
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.alpha = 0.55
        addSubview(art)
        addSubview(blur)

        icon.tintColor = UIColor(red: 0.62, green: 0.48, blue: 1, alpha: 1)
        icon.contentMode = .scaleAspectFit
        icon.isHidden = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        titleLabel.text = gameName
        titleLabel.font = NexFont.ui(22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center

        stageLabel.font = NexFont.ui(15, weight: .medium)
        stageLabel.textColor = UIColor(red: 0.85, green: 0.82, blue: 1, alpha: 1)
        stageLabel.numberOfLines = 0
        stageLabel.textAlignment = .center

        spinner.color = .white
        spinner.startAnimating()

        detailLabel.font = NexFont.ui(13)
        detailLabel.textColor = UIColor(white: 1, alpha: 0.75)
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        detailLabel.isHidden = true

        logButton.setTitle("Show Log", for: .normal)
        logButton.titleLabel?.font = NexFont.ui(14, weight: .semibold)
        logButton.tintColor = UIColor(white: 1, alpha: 0.8)
        logButton.addTarget(self, action: #selector(toggleLog), for: .touchUpInside)

        logView.isEditable = false
        logView.isHidden = true
        logView.backgroundColor = UIColor(white: 0, alpha: 0.45)
        logView.textColor = UIColor(white: 1, alpha: 0.8)
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.layer.cornerRadius = 12
        logView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        actionsStack.axis = .vertical
        actionsStack.spacing = 10
        actionsStack.isHidden = true

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = NexFont.ui(16, weight: .semibold)
        cancelButton.tintColor = .white
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        card.axis = .vertical
        card.alignment = .fill
        card.spacing = 14
        for view in [icon, titleLabel, stageLabel, spinner, detailLabel, logButton, logView, actionsStack, cancelButton] as [UIView] {
            card.addArrangedSubview(view)
        }
        card.layoutMargins = UIEdgeInsets(top: 22, left: 20, bottom: 18, right: 20)
        card.isLayoutMarginsRelativeArrangement = true
        card.backgroundColor = UIColor(white: 0.08, alpha: 0.82)
        card.layer.cornerRadius = 26
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        let wide = card.widthAnchor.constraint(equalToConstant: 460)
        wide.priority = .defaultLow
        wide.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        art.frame = bounds
        blur.frame = bounds
    }

    func setStage(_ text: String) {
        guard !isShowingError else { return }
        stageLabel.text = text
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        if logOpen { refreshLog() }
    }

    func setLog(_ lines: [String]) {
        logLines = Array(lines.suffix(200))
        if logOpen { refreshLog() }
    }

    private func refreshLog() {
        logView.text = logLines.suffix(60).joined(separator: "\n")
        let end = NSRange(location: max(0, (logView.text as NSString).length - 1), length: 1)
        logView.scrollRangeToVisible(end)
    }

    @objc private func toggleLog() {
        logOpen.toggle()
        logView.isHidden = !logOpen
        logButton.setTitle(logOpen ? "Hide Log" : "Show Log", for: .normal)
        if logOpen { refreshLog() }
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    /// Turns the loading screen into an error card.
    func showError(what: String, why: String?, actions: [LoadingAction]) {
        isShowingError = true
        spinner.stopAnimating()
        spinner.isHidden = true
        icon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        icon.tintColor = .systemOrange
        icon.isHidden = false
        stageLabel.text = what
        stageLabel.textColor = .white
        if let why, !why.isEmpty {
            detailLabel.text = "Why: " + String(why.prefix(300))
            detailLabel.isHidden = false
        } else {
            detailLabel.isHidden = true
        }
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            var config: UIButton.Configuration = action.primary ? .filled() : .gray()
            config.title = action.title
            config.image = UIImage(systemName: action.symbol)
            config.imagePadding = 8
            config.cornerStyle = .capsule
            if action.primary {
                config.baseBackgroundColor = UIColor(red: 0.45, green: 0.3, blue: 0.95, alpha: 1)
            }
            config.baseForegroundColor = .white
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action.handler() })
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            actionsStack.addArrangedSubview(button)
        }
        actionsStack.isHidden = actions.isEmpty
        cancelButton.setTitle("Back to Library", for: .normal)
        if !logOpen && !logLines.isEmpty { toggleLog() }
    }

    /// Back to loading (after a retry).
    func resetToLoading(_ stage: String) {
        isShowingError = false
        icon.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        stageLabel.textColor = UIColor(red: 0.85, green: 0.82, blue: 1, alpha: 1)
        stageLabel.text = stage
        detailLabel.isHidden = true
        actionsStack.isHidden = true
        cancelButton.setTitle("Cancel", for: .normal)
    }
}

/// Crash-safe launch: which game NexPlay was starting, and which games crashed at start before.
enum LaunchGuard {
    private static let startingKey = "launchGuardStarting"
    private static let crashedKey = "launchGuardCrashed"

    /// The game starts on a runtime. Cleared when it has run 20 seconds or is closed.
    @MainActor
    static func begin(_ game: Game, runtime: RuntimeKind) {
        UserDefaults.standard.set("\(game.id.uuidString)|\(runtime.rawValue)", forKey: startingKey)
        let id = game.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            end(id)
        }
    }

    static func end(_ gameID: UUID) {
        guard let value = UserDefaults.standard.string(forKey: startingKey),
              value.hasPrefix(gameID.uuidString) else { return }
        UserDefaults.standard.removeObject(forKey: startingKey)
    }

    /// At app launch: a game still marked as starting means NexPlay died while starting it.
    static func checkAtLaunch() {
        guard let value = UserDefaults.standard.string(forKey: startingKey) else { return }
        UserDefaults.standard.removeObject(forKey: startingKey)
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return }
        var crashed = UserDefaults.standard.dictionary(forKey: crashedKey) as? [String: String] ?? [:]
        crashed[parts[0]] = parts[1]
        UserDefaults.standard.set(crashed, forKey: crashedKey)
        AppLog.log("launch guard: NexPlay closed while starting game \(parts[0]) on \(parts[1])")
    }

    /// The runtime a game crashed on while starting last time, or nil.
    static func crashedRuntime(for gameID: UUID) -> RuntimeKind? {
        let crashed = UserDefaults.standard.dictionary(forKey: crashedKey) as? [String: String] ?? [:]
        return crashed[gameID.uuidString].flatMap { RuntimeKind(rawValue: $0) }
    }

    static func clearCrash(for gameID: UUID) {
        var crashed = UserDefaults.standard.dictionary(forKey: crashedKey) as? [String: String] ?? [:]
        crashed[gameID.uuidString] = nil
        UserDefaults.standard.set(crashed, forKey: crashedKey)
    }
}
