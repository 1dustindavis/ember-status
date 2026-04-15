import UIKit
import EmberCore

final class ESMainViewController: UIViewController {
    private var coordinator: MugSessionCoordinator?

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

    private lazy var labels: [UILabel] = [
        nameLabel,
        connectionLabel,
        currentTempLabel,
        targetTempLabel,
        batteryLabel,
        chargingLabel,
        warningLabel
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ember Status"
        view.backgroundColor = .systemBackground
        configureLabels()
        renderSnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutLabels()
    }

    func bind(to coordinator: MugSessionCoordinator) {
        self.coordinator = coordinator
        coordinator.startConnectionEventListening()
        snapshot = coordinator.snapshot
        renderSnapshot()
    }

    func unbind() {
        coordinator?.stopConnectionEventListening()
        coordinator = nil
    }

    private func configureLabels() {
        labels.forEach { label in
            label.numberOfLines = 1
            label.font = .preferredFont(forTextStyle: .body)
            view.addSubview(label)
        }
        nameLabel.font = .preferredFont(forTextStyle: .headline)
    }

    private func layoutLabels() {
        let inset = view.layoutMargins
        let top = view.safeAreaInsets.top + 16
        let width = max(0, view.bounds.width - inset.left - inset.right)
        let lineHeight: CGFloat = 24
        let spacing: CGFloat = 8

        for (index, label) in labels.enumerated() {
            let y = top + CGFloat(index) * (lineHeight + spacing)
            label.frame = CGRect(x: inset.left, y: y, width: width, height: lineHeight)
        }
    }

    private func renderSnapshot() {
        nameLabel.text = snapshot.identity?.name ?? "No mug selected"
        connectionLabel.text = "Connection: \(String(describing: snapshot.status.connectionState))"
        currentTempLabel.text = "Current temp: \(formattedTemperature(snapshot.status.currentTempC))"
        targetTempLabel.text = "Target temp: \(formattedTemperature(snapshot.status.targetTempC))"
        batteryLabel.text = "Battery: \(snapshot.status.batteryPercent.map { \"\\($0)%\" } ?? "--")"
        chargingLabel.text = "Charging: \(snapshot.status.isCharging.map { $0 ? "Yes" : "No" } ?? "--")"
        warningLabel.text = "Parse warnings: \(snapshot.diagnostics.parseWarnings.count)"
    }

    private func formattedTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f°C", value)
    }
}
