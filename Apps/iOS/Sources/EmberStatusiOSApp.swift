import SwiftUI
import EmberCore

@main
struct EmberStatusiOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSSessionRootView(viewModel: IOSSessionViewModel())
        }
    }
}

@MainActor
final class IOSSessionViewModel: ObservableObject {
    @Published private(set) var snapshot = MugSessionCoordinator.Snapshot(
        identity: nil,
        status: MugStatus(),
        diagnostics: MugDiagnostics(),
        capabilityMap: nil
    )

    // Real app should inject a CoreBluetooth-backed BluetoothManaging implementation.
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

struct IOSSessionRootView: View {
    @StateObject var viewModel: IOSSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.snapshot.identity?.name ?? "No mug selected")
                .font(.headline)
            Text("Connection: \(String(describing: viewModel.snapshot.status.connectionState))")
            Text("Current temp: \(viewModel.snapshot.status.currentTempC.map { String(format: "%.2f°C", $0) } ?? "--")")
            Text("Battery: \(viewModel.snapshot.status.batteryPercent.map(String.init) ?? "--")%")
            Text("Parse warnings: \(viewModel.snapshot.diagnostics.parseWarnings.count)")
        }
        .padding()
    }
}
