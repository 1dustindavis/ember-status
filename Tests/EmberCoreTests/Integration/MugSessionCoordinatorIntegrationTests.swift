import Foundation
import XCTest
@testable import EmberCore

actor MockBluetoothManager: BluetoothManaging {
    var availability: BLEAvailability = .poweredOn
    var devices: [BLEDevice] = []
    var capabilities: MugCapabilityMap = MugCapabilityMap(readable: EmberCharacteristic.readOnlyStatus, notifiable: [])
    var reads: [BLECharacteristicID: Data] = [:]
    var subscribedCharacteristics: [BLECharacteristicID] = []
    var notificationContinuations: [BLECharacteristicID: AsyncThrowingStream<Data, Error>.Continuation] = [:]

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
            notificationContinuations[characteristic] = continuation
        }
    }

    func pushNotification(_ data: Data, for characteristic: BLECharacteristicID) {
        notificationContinuations[characteristic]?.yield(data)
    }
}

final class MugSessionCoordinatorIntegrationTests: XCTestCase {
    @MainActor
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

    @MainActor
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

    @MainActor
    func testCoordinatorListenerConsumesConnectionEventsStream() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        let coordinator = MugSessionCoordinator(bluetooth: mock)

        coordinator.startConnectionEventListening()
        await mock.push(event: .connected(mug))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.status.connectionState, .connected)

        coordinator.stopConnectionEventListening()
        await mock.push(event: .disconnected(mug, expected: true))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.status.connectionState, .connected)
    }

    @MainActor
    func testStrictCompatibilityReplacesWarningsAcrossRefreshCycles() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Strict", rssi: -42)])
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x11]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([80, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock, compatibilityMode: .strict)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        XCTAssertTrue(coordinator.diagnostics.parseWarnings.contains { $0.field == "temperature" })

        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0xF4, 0x09]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([80, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        try await coordinator.refresh(at: Date(timeIntervalSince1970: 777))

        XCTAssertTrue(coordinator.diagnostics.parseWarnings.isEmpty)
    }

    @MainActor
    func testPermissiveCompatibilityAccumulatesWarningsAcrossRefreshCycles() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Permissive", rssi: -50)])
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x11]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([80, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock, compatibilityMode: .permissive)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        XCTAssertTrue(coordinator.diagnostics.parseWarnings.contains { $0.field == "temperature" })

        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0xF4, 0x09]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([80, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        try await coordinator.refresh(at: Date(timeIntervalSince1970: 888))

        XCTAssertTrue(coordinator.diagnostics.parseWarnings.contains { $0.field == "temperature" })
    }

    @MainActor
    func testScanThrowsWhenBluetoothUnavailableAndSetsDisconnectedState() async {
        let mock = MockBluetoothManager()
        await mock.setAvailability(.poweredOff)

        let coordinator = MugSessionCoordinator(bluetooth: mock)

        do {
            _ = try await coordinator.scanAndRankDevices()
            XCTFail("Expected scanAndRankDevices() to throw when bluetooth is unavailable")
        } catch let error as MugSessionCoordinator.SessionError {
            XCTAssertEqual(error, .bluetoothUnavailable(.poweredOff))
            XCTAssertEqual(coordinator.status.connectionState, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testDisconnectIsIdempotentAndResetsStateWithoutSelection() async {
        let mock = MockBluetoothManager()
        let coordinator = MugSessionCoordinator(bluetooth: mock)

        await coordinator.handleConnectionEvent(.connected(UUID()))
        await coordinator.disconnect()
        await coordinator.disconnect()

        XCTAssertNil(coordinator.selectedMug)
        XCTAssertNil(coordinator.capabilityMap)
        XCTAssertEqual(coordinator.status.connectionState, .disconnected)
    }

    @MainActor
    func testConnectionEventLogCapsAtFiftyEntries() async throws {
        let mock = MockBluetoothManager()
        let coordinator = MugSessionCoordinator(bluetooth: mock)

        coordinator.startConnectionEventListening()
        for _ in 0..<120 {
            await mock.push(event: .connected(UUID()))
        }
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(coordinator.diagnostics.connectionEvents.count, 50)
    }

    @MainActor
    func testSubscribesToNotificationsOnlyWhenCapabilitySupportsPushEvents() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Notify", rssi: -31)])
        await mock.setCapabilities(MugCapabilityMap(readable: EmberCharacteristic.readOnlyStatus, notifiable: []))
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x10, 0x27]),
            EmberCharacteristic.targetTemp: Data([0x10, 0x27]),
            EmberCharacteristic.battery: Data([80, 0]),
            EmberCharacteristic.liquidState: Data([2])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        let subscriptionsAfterUnsupported = await mock.subscribedCharacteristics
        XCTAssertFalse(subscriptionsAfterUnsupported.contains(EmberCharacteristic.pushEvents))

        await mock.setCapabilities(
            MugCapabilityMap(readable: EmberCharacteristic.readOnlyStatus, notifiable: [EmberCharacteristic.pushEvents])
        )
        try await coordinator.connect(to: ranked[0])

        let subscriptionsAfterSupported = await mock.subscribedCharacteristics
        XCTAssertTrue(subscriptionsAfterSupported.contains(EmberCharacteristic.pushEvents))
    }

    @MainActor
    func testPushEventsTriggerRefreshReads() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Push", rssi: -40)])
        await mock.setCapabilities(
            MugCapabilityMap(readable: EmberCharacteristic.readOnlyStatus, notifiable: [EmberCharacteristic.pushEvents])
        )
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0xF4, 0x09]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([75, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x10, 0x27]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([75, 1]),
            EmberCharacteristic.liquidState: Data([3])
        ])
        await mock.pushNotification(Data([0x01]), for: EmberCharacteristic.pushEvents)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(coordinator.status.currentTempC, 100.0)
    }

    @MainActor
    func testPermissiveWarningRetentionIsBounded() async throws {
        let mock = MockBluetoothManager()
        let mug = UUID()
        await mock.setDevices([BLEDevice(id: mug, name: "Warnings", rssi: -45)])
        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x11]),
            EmberCharacteristic.targetTemp: Data([0x2C, 0x1E]),
            EmberCharacteristic.battery: Data([80, 1]),
            EmberCharacteristic.liquidState: Data([0x01])
        ])

        let coordinator = MugSessionCoordinator(bluetooth: mock, compatibilityMode: .permissive, parseWarningsLimit: 3)
        let ranked = try await coordinator.scanAndRankDevices()
        try await coordinator.connect(to: ranked[0])

        await mock.setReads([
            EmberCharacteristic.currentTemp: Data([0x11, 0x22, 0x33]),
            EmberCharacteristic.targetTemp: Data([0xAA]),
            EmberCharacteristic.battery: Data([255, 1]),
            EmberCharacteristic.liquidState: Data([0x03, 0x04])
        ])
        try await coordinator.refresh()

        XCTAssertEqual(coordinator.diagnostics.parseWarnings.count, 3)
    }
}

private extension MockBluetoothManager {
    func setDevices(_ devices: [BLEDevice]) {
        self.devices = devices
    }

    func setReads(_ reads: [BLECharacteristicID: Data]) {
        self.reads = reads
    }

    func setAvailability(_ availability: BLEAvailability) {
        self.availability = availability
    }

    func setCapabilities(_ capabilities: MugCapabilityMap) {
        self.capabilities = capabilities
    }
}
