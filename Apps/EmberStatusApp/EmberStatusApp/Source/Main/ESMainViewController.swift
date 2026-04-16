import UIKit
import EmberCore
import OSLog

final class ESMainViewController: UIViewController {
    private enum ViewError: Error, LocalizedError {
        case scanTimedOut

        var errorDescription: String? {
            switch self {
            case .scanTimedOut:
                return "Scan timed out. Please try again."
            }
        }
    }

    private var coordinator: MugSessionCoordinator?
    private var discoveredMugs: [MugIdentity] = []
    private var lastErrorMessage: String?
    private var isScanning = false

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
    private let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "UI")

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
        renderSnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutLabels()
    }

    func bind(to coordinator: MugSessionCoordinator) {
        logNotice("[UI] binding coordinator")
        coordinator.onSnapshotChanged = { [weak self] next in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshot = next
                self.renderSnapshot()
                self.logger.debug("[UI] snapshot updated state=\(String(describing: next.status.connectionState)) selected=\(next.identity?.id.uuidString ?? "none")")
            }
        }
        coordinator.startConnectionEventListening()
        snapshot = coordinator.snapshot
        renderSnapshot()
    }

    func unbind() {
        logNotice("[UI] unbinding coordinator")
        coordinator?.stopConnectionEventListening()
        coordinator?.onSnapshotChanged = nil
    }

    @MainActor
    private func ensureCoordinator() -> MugSessionCoordinator {
        if let coordinator {
            return coordinator
        }

        logNotice("[UI] creating coordinator")
        let coordinator = MugSessionCoordinator(bluetooth: CoreBluetoothManager())
        bind(to: coordinator)
        self.coordinator = coordinator
        return coordinator
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
        scanButton.setTitle(isScanning ? "Scanning..." : "Scan", for: .normal)
        scanButton.isEnabled = !isScanning
    }

    private func formattedTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f°C", value)
    }

    @objc
    private func scanTapped() {
        isScanning = true
        lastErrorMessage = nil
        logNotice("[UI] scan tapped")
        renderSnapshot()

        Task {
            do {
                let coordinator = await MainActor.run { self.ensureCoordinator() }
                let devices = try await self.withTimeout(seconds: 12) {
                    try await coordinator.scanAndRankDevices()
                }
                await MainActor.run {
                    self.discoveredMugs = devices
                    self.lastErrorMessage = devices.isEmpty ? "Scan completed: no mugs found nearby." : nil
                    self.isScanning = false
                    self.logNotice("[UI] scan completed count=\(devices.count)")
                    self.renderSnapshot()
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = error.localizedDescription
                    self.isScanning = false
                    self.logError("[UI] scan failed error=\(error.localizedDescription)")
                    self.renderSnapshot()
                }
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ViewError.scanTimedOut
            }

            guard let first = try await group.next() else {
                throw ViewError.scanTimedOut
            }
            group.cancelAll()
            return first
        }
    }

    @objc
    private func connectTapped() {
        guard !self.discoveredMugs.isEmpty else {
            lastErrorMessage = "No discovered mugs. Tap Scan first."
            logNotice("[UI] connect tapped with no discovered mugs")
            renderSnapshot()
            return
        }
        logNotice("[UI] connect tapped options=\(self.discoveredMugs.count)")

        let sheet = UIAlertController(title: "Connect to Mug", message: nil, preferredStyle: .actionSheet)
        for mug in self.discoveredMugs {
            let title = mug.name ?? mug.id.uuidString
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.connect(to: mug)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self.connectButton
            popover.sourceRect = self.connectButton.bounds
        }

        self.present(sheet, animated: true)
    }

    @objc
    private func refreshTapped() {
        logNotice("[UI] refresh tapped")
        Task { @MainActor in
            do {
                try await ensureCoordinator().refresh()
                lastErrorMessage = nil
                logNotice("[UI] refresh succeeded")
            } catch {
                lastErrorMessage = error.localizedDescription
                logError("[UI] refresh failed error=\(error.localizedDescription)")
            }
            renderSnapshot()
        }
    }

    private func connect(to mug: MugIdentity) {
        logNotice("[UI] connect selected id=\(mug.id.uuidString) name=\(mug.name ?? "unknown")")
        Task { @MainActor in
            do {
                try await ensureCoordinator().connect(to: mug)
                lastErrorMessage = nil
                logNotice("[UI] connect succeeded id=\(mug.id.uuidString)")
            } catch {
                lastErrorMessage = error.localizedDescription
                logError("[UI] connect failed id=\(mug.id.uuidString) error=\(error.localizedDescription)")
            }
            renderSnapshot()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func logNotice(_ message: String) {
        logger.notice("\(message)")
        NSLog("%@", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message)")
        NSLog("%@", message)
    }
}
