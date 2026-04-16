import UIKit
import EmberCore

final class ESMainViewController: UIViewController {
    private let bluetooth = CoreBluetoothManager()
    private lazy var coordinator = MugSessionCoordinator(bluetooth: bluetooth)
    private var discoveredMugs: [MugIdentity] = []
    private var lastErrorMessage: String?

    private var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )

    private let nameLabel = UILabel()
    private let connectionLabel = UILabel()
    private let currentTempLabel = UILabel()
    private let targetTempLabel = UILabel()
    private let batteryLabel = UILabel()
    private let chargingLabel = UILabel()
    private let warningLabel = UILabel()
    private let devicesLabel = UILabel()
    private let lastErrorLabel = UILabel()
    private let lastEventLabel = UILabel()
    private let scanButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)

    private lazy var labels: [UILabel] = [
        nameLabel,
        connectionLabel,
        currentTempLabel,
        targetTempLabel,
        batteryLabel,
        chargingLabel,
        warningLabel,
        devicesLabel,
        lastErrorLabel,
        lastEventLabel
    ]

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    deinit {
        unbind()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ember Status"
        view.backgroundColor = .systemBackground
        configureUI()
        bind(to: coordinator)
        renderSnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutLabels()
    }

    func bind(to coordinator: MugSessionCoordinator) {
        coordinator.onSnapshotChanged = { [weak self] next in
            guard let self else { return }
            Task { @MainActor in
                self.snapshot = next
                self.renderSnapshot()
            }
        }
        coordinator.startConnectionEventListening()
        snapshot = coordinator.snapshot
        renderSnapshot()
    }

    func unbind() {
        coordinator.stopConnectionEventListening()
        coordinator.onSnapshotChanged = nil
    }

    private func configureUI() {
        labels.forEach { label in
            label.numberOfLines = 1
            label.font = .preferredFont(forTextStyle: .body)
            view.addSubview(label)
        }
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        devicesLabel.font = .preferredFont(forTextStyle: .subheadline)
        lastErrorLabel.font = .preferredFont(forTextStyle: .caption1)
        lastEventLabel.font = .preferredFont(forTextStyle: .caption1)

        configureButton(scanButton, title: "Scan", action: #selector(scanTapped))
        configureButton(connectButton, title: "Connect", action: #selector(connectTapped))
        configureButton(refreshButton, title: "Refresh", action: #selector(refreshTapped))
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(button)
    }

    private func layoutLabels() {
        let inset = view.layoutMargins
        let top = view.safeAreaInsets.top + 16
        let width = max(0, view.bounds.width - inset.left - inset.right)
        let lineHeight: CGFloat = 22
        let spacing: CGFloat = 8
        let buttonHeight: CGFloat = 34
        let buttonWidth = min(100, (width - 16) / 3)

        scanButton.frame = CGRect(x: inset.left, y: top, width: buttonWidth, height: buttonHeight)
        connectButton.frame = CGRect(x: scanButton.frame.maxX + 8, y: top, width: buttonWidth, height: buttonHeight)
        refreshButton.frame = CGRect(x: connectButton.frame.maxX + 8, y: top, width: buttonWidth, height: buttonHeight)

        let labelsTop = top + buttonHeight + 18

        for (index, label) in labels.enumerated() {
            let y = labelsTop + CGFloat(index) * (lineHeight + spacing)
            label.frame = CGRect(x: inset.left, y: y, width: width, height: lineHeight)
        }
    }

    private func renderSnapshot() {
        nameLabel.text = snapshot.identity?.name ?? "No mug selected"
        connectionLabel.text = "Connection: \(String(describing: snapshot.status.connectionState))"
        currentTempLabel.text = "Current temp: \(formattedTemperature(snapshot.status.currentTempC))"
        targetTempLabel.text = "Target temp: \(formattedTemperature(snapshot.status.targetTempC))"
        batteryLabel.text = "Battery: \(snapshot.status.batteryPercent.map { "\($0)%" } ?? "--")"
        chargingLabel.text = "Charging: \(snapshot.status.isCharging.map { $0 ? "Yes" : "No" } ?? "--")"
        warningLabel.text = "Parse warnings: \(snapshot.diagnostics.parseWarnings.count)"
        devicesLabel.text = "Discovered mugs: \(discoveredMugs.count)"
        lastErrorLabel.text = "Last error: \(lastErrorMessage ?? "--")"
        lastEventLabel.text = "Last event: \(snapshot.diagnostics.connectionEvents.last?.message ?? "--")"
    }

    private func formattedTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f°C", value)
    }

    @objc
    private func scanTapped() {
        Task { @MainActor in
            do {
                discoveredMugs = try await coordinator.scanAndRankDevices()
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            renderSnapshot()
        }
    }

    @objc
    private func connectTapped() {
        guard !discoveredMugs.isEmpty else {
            lastErrorMessage = "No discovered mugs. Tap Scan first."
            renderSnapshot()
            return
        }

        let sheet = UIAlertController(title: "Connect to Mug", message: nil, preferredStyle: .actionSheet)
        for mug in discoveredMugs {
            let title = mug.name ?? mug.id.uuidString
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.connect(to: mug)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = connectButton
            popover.sourceRect = connectButton.bounds
        }

        present(sheet, animated: true)
    }

    @objc
    private func refreshTapped() {
        Task { @MainActor in
            do {
                try await coordinator.refresh()
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            renderSnapshot()
        }
    }

    private func connect(to mug: MugIdentity) {
        Task { @MainActor in
            do {
                try await coordinator.connect(to: mug)
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            renderSnapshot()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
