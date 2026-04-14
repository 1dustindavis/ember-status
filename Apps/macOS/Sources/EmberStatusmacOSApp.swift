import SwiftUI
import EmberCore

@main
struct EmberStatusmacOSApp: App {
    var body: some Scene {
        WindowGroup {
            MacSessionRootView(viewModel: MacSessionViewModel())
                .frame(minWidth: 420, minHeight: 280)
        }
    }
}

@MainActor
final class MacSessionViewModel: ObservableObject {
    @Published private(set) var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )

    private var coordinator: MugSessionCoordinator?

    func bind(to coordinator: MugSessionCoordinator) {
        self.coordinator = coordinator
        coordinator.startConnectionEventListening()
        snapshot = coordinator.snapshot
    }

    func unbind() {
        coordinator?.stopConnectionEventListening()
        coordinator = nil
    }
}

struct MacSessionRootView: View {
    @StateObject var viewModel: MacSessionViewModel

    var body: some View {
        List {
            Section("Connection") {
                Text(viewModel.snapshot.identity?.name ?? "No mug selected")
                Text("State: \(String(describing: viewModel.snapshot.status.connectionState))")
                Text("Last update: \(viewModel.snapshot.status.lastUpdated.formatted())")
            }

            Section("Read-only status") {
                Text("Current temp: \(viewModel.snapshot.status.currentTempC.map { String(format: "%.2f°C", $0) } ?? "--")")
                Text("Target temp: \(viewModel.snapshot.status.targetTempC.map { String(format: "%.2f°C", $0) } ?? "--")")
                Text("Charging: \(viewModel.snapshot.status.isCharging.map { $0 ? "Yes" : "No" } ?? "--")")
            }

            Section("Diagnostics") {
                Text("Events: \(viewModel.snapshot.diagnostics.connectionEvents.count)")
                Text("Warnings: \(viewModel.snapshot.diagnostics.parseWarnings.count)")
            }
        }
    }
}
