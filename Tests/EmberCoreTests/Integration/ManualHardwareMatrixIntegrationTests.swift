import XCTest
@testable import EmberCore

final class ManualHardwareMatrixIntegrationTests: XCTestCase {
    func testManualHardwareMatrixScenariosAreCoveredByExecutableFixtureChecks() async throws {
        let fixtures = try HardwareFixtureLoader.loadAll()
        XCTAssertEqual(fixtures.count, 4, "Expected idle/heating/charging/near-empty captures.")

        for fixture in fixtures {
            let mock = MockBluetoothManager()
            let mug = UUID()
            await mock.setDevicesForMatrix([BLEDevice(id: mug, name: fixture.captureID, rssi: -30)])
            await mock.setReadsForMatrix(fixture.readMap)

            let coordinator = MugSessionCoordinator(bluetooth: mock)
            let ranked = try await coordinator.scanAndRankDevices()
            try await coordinator.connect(to: try XCTUnwrap(ranked.first))
            let currentTemp = try XCTUnwrap(coordinator.status.currentTempC, "capture=\(fixture.captureID)")
            let targetTemp = try XCTUnwrap(coordinator.status.targetTempC, "capture=\(fixture.captureID)")

            XCTAssertEqual(coordinator.status.connectionState, .connected, "capture=\(fixture.captureID)")
            XCTAssertEqual(currentTemp, fixture.expected.currentTempC, accuracy: 0.01, "capture=\(fixture.captureID)")
            XCTAssertEqual(targetTemp, fixture.expected.targetTempC, accuracy: 0.01, "capture=\(fixture.captureID)")
            XCTAssertEqual(coordinator.status.batteryPercent, fixture.expected.batteryPercent, "capture=\(fixture.captureID)")
            XCTAssertEqual(coordinator.status.isCharging, fixture.expected.isCharging, "capture=\(fixture.captureID)")
            XCTAssertEqual(coordinator.status.liquidState, fixture.expectedLiquidState, "capture=\(fixture.captureID)")

            // Display parity check: iOS and macOS consume the same display mapping from EmberCore.
            XCTAssertEqual(coordinator.status.liquidState?.displayName, fixture.expectedLiquidState.displayName, "capture=\(fixture.captureID)")
        }
    }

    func testManualHardwareMatrixConnectionDropReconnectRecoversSession() async throws {
        let fixture = try XCTUnwrap(HardwareFixtureLoader.loadAll().first { $0.captureID.contains("heating") })
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevicesForMatrix([BLEDevice(id: mug, name: "ReconnectCase", rssi: -38)])
        await mock.setReadsForMatrix(fixture.readMap)

        let coordinator = MugSessionCoordinator(bluetooth: mock, reconnectMaxAttempts: 1)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: try XCTUnwrap(ranked.first))

        await coordinator.handleConnectionEvent(.disconnected(mug, expected: false))

        XCTAssertEqual(coordinator.status.connectionState, .connected)
        XCTAssertTrue(coordinator.diagnostics.connectionEvents.contains { $0.message.contains("Reconnect attempt 1") })
        XCTAssertTrue(coordinator.diagnostics.connectionEvents.contains { $0.message.contains("Reconnect succeeded") })
    }

    func testManualHardwareMatrixForegroundBackgroundTransitionsAreExecutable() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        let coordinator = MugSessionCoordinator(bluetooth: mock)

        coordinator.startConnectionEventListening()
        await mock.push(event: .connected(mug))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.status.connectionState, .connected)

        // Simulate app moving to background by stopping listener consumption.
        coordinator.stopConnectionEventListening()
        await mock.push(event: .disconnected(mug, expected: true))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.status.connectionState, .connected)

        // Simulate app returning to foreground: events are handled again.
        await coordinator.handleConnectionEvent(.disconnected(mug, expected: true))
        XCTAssertEqual(coordinator.status.connectionState, .disconnected)
    }
}

private extension MockBluetoothManager {
    func setDevicesForMatrix(_ devices: [BLEDevice]) {
        self.devices = devices
    }

    func setReadsForMatrix(_ reads: [BLECharacteristicID: Data]) {
        self.reads = reads
    }
}
