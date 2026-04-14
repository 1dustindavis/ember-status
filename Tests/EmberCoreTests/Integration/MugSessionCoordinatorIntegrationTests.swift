import Foundation
import XCTest
@testable import EmberCore

actor MockBluetoothManager: BluetoothManaging {
    var availability: BLEAvailability = .poweredOn
    var devices: [BLEDevice] = []
    var capabilities: MugCapabilityMap = MugCapabilityMap(readable: EmberCharacteristic.readOnlyStatus, notifiable: [])
    var reads: [BLECharacteristicID: Data] = [:]
    var subscribedCharacteristics: [BLECharacteristicID] = []

    private let events: AsyncStream<BLEConnectionEvent>
    private let continuation: AsyncStream<BLEConnectionEvent>.Continuation

    init() {
        var localContinuation: AsyncStream<BLEConnectionEvent>.Continuation?
        self.events = AsyncStream { continuation in
            localContinuation = continuation
        }
        self.continuation = localContinuation!
    }

    nonisolated var connectionEvents: AsyncStream<BLEConnectionEvent> { events }

    func push(event: BLEConnectionEvent) {
        continuation.yield(event)
    }

    func startScanning() async throws -> [BLEDevice] { devices }
    func stopScanning() async {}

    func connect(to deviceID: UUID) async throws {}
    func disconnect(from deviceID: UUID) async {}

    func discoverCapabilities(for deviceID: UUID) async throws -> MugCapabilityMap { capabilities }

    func readValue(for characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data {
        reads[characteristic] ?? Data()
    }

    func subscribe(to characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> AsyncThrowingStream<Data, Error> {
        subscribedCharacteristics.append(characteristic)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

final class MugSessionCoordinatorIntegrationTests: XCTestCase {
    func testScanRanksByRSSIAndConnectRefreshesState() async throws {
        let mock = MockBluetoothManager()
        let mugA = UUID()
        let mugB = UUID()

        await mock.setDevices([
            BLEDevice(id: mugA, name: "Far", rssi: -80),
            BLEDevice(id: mugB, name: "Near", rssi: -30)
        ])
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0xF4, 0x09]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([75, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock)
        let ranked = try await coordinator.scanAndRankDevices()

        XCTAssertEqual(ranked.map(\.id), [mugB, mugA])

        try await coordinator.connect(to: ranked[0])

        XCTAssertEqual(coordinator.status.connectionState, .connected)
        XCTAssertEqual(coordinator.status.currentTempC, 25.48)
        XCTAssertEqual(coordinator.status.targetTempC, 77.24)
        XCTAssertEqual(coordinator.status.batteryPercent, 75)
        XCTAssertEqual(coordinator.status.isCharging, true)
        XCTAssertEqual(coordinator.status.liquidState, .heating)
    }

    func testUnexpectedDisconnectAttemptsReconnect() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Test", rssi: -40)])
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x10, 0x27]),
            EmberCharacteristic.targetTemp: Data([0x10, 0x27]),
            EmberCharacteristic.battery: Data([80, 0]),
            EmberCharacteristic.liquidState: Data([2])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock, reconnectMaxAttempts: 1)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        await coordinator.handleConnectionEvent(.disconnected(mug, expected: false))

        XCTAssertTrue(coordinator.diagnostics.connectionEvents.contains { $0.message.contains("Reconnect attempt 1") })
    }
}

private extension MockBluetoothManager {
    func setDevices(_ devices: [BLEDevice]) {
        self.devices = devices
    }

    func setReads(_ reads: [BLECharacteristicID: Data]) {
        self.reads = reads
    }
}
