import Foundation
import OSLog

public final class MugSessionCoordinator {
    public enum SessionError: Error, Equatable, LocalizedError {
        case bluetoothUnavailable(BLEAvailability)
        case noDeviceSelected
        case notConnected
        case operationTimedOut(operation: String)
        case missingCaptureCharacteristic(String)

        public var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable(let availability):
                switch availability {
                case .poweredOn:
                    return "Bluetooth is available."
                case .unknown:
                    return "Bluetooth is still initializing. Try again in a moment."
                case .poweredOff:
                    return "Bluetooth is turned off. Please enable Bluetooth and try again."
                case .unauthorized:
                    return "Bluetooth permission is not granted. Enable Bluetooth access in Settings."
                case .unsupported:
                    return "Bluetooth is not supported on this device."
                }
            case .noDeviceSelected:
                return "No mug is selected."
            case .notConnected:
                return "Mug is not connected."
            case .operationTimedOut(let operation):
                return "\(operation.capitalized) timed out. Please try again."
            case .missingCaptureCharacteristic(let name):
                return "Capture requires \(name), but it was unavailable from this mug."
            }
        }
    }

    public struct Snapshot: Equatable {
        public let identity: MugIdentity?
        public let status: MugStatus
        public let diagnostics: MugDiagnostics
        public let capabilityMap: MugCapabilityMap?

        public init(
            identity: MugIdentity?,
            status: MugStatus,
            diagnostics: MugDiagnostics,
            capabilityMap: MugCapabilityMap?
        ) {
            self.identity = identity
            self.status = status
            self.diagnostics = diagnostics
            self.capabilityMap = capabilityMap
        }
    }

    private let bluetooth: BluetoothManaging
    private let reducer: MugStatusReducer
    private let reconnectMaxAttempts: Int
    private let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "Session")
    private var connectionEventsTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    private(set) public var compatibilityMode: ProtocolCompatibilityMode
    private(set) public var selectedMug: MugIdentity?
    private(set) public var status: MugStatus
    private(set) public var diagnostics: MugDiagnostics
    private(set) public var capabilityMap: MugCapabilityMap?
    public var onSnapshotChanged: ((Snapshot) -> Void)?

    public init(
        bluetooth: BluetoothManaging,
        reducer: MugStatusReducer = MugStatusReducer(),
        compatibilityMode: ProtocolCompatibilityMode = .permissive,
        reconnectMaxAttempts: Int = 2
    ) {
        self.bluetooth = bluetooth
        self.reducer = reducer
        self.compatibilityMode = compatibilityMode
        self.reconnectMaxAttempts = reconnectMaxAttempts
        self.status = MugStatus()
        self.diagnostics = MugDiagnostics()
    }

    public func setCompatibilityMode(_ mode: ProtocolCompatibilityMode) {
        compatibilityMode = mode
    }

    deinit {
        connectionEventsTask?.cancel()
        notificationTask?.cancel()
    }

    public func startConnectionEventListening() {
        connectionEventsTask?.cancel()
        appendEvent("Started connection event listener")
        logNotice("[Session] connection event listener started")
        notifySnapshotChanged()

        connectionEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.bluetooth.connectionEvents {
                if Task.isCancelled { break }
                await self.handleConnectionEvent(event)
            }
        }
    }

    public func stopConnectionEventListening() {
        connectionEventsTask?.cancel()
        connectionEventsTask = nil
        appendEvent("Stopped connection event listener")
        logNotice("[Session] connection event listener stopped")
        notifySnapshotChanged()
    }

    @discardableResult
    public func scanAndRankDevices() async throws -> [MugIdentity] {
        logNotice("[Session] scan started")
        status.connectionState = .scanning
        notifySnapshotChanged()

        let devices: [BLEDevice]
        do {
            devices = try await bluetooth.startScanning().sorted { $0.rssi > $1.rssi }
        } catch let error as CoreBluetoothManagerError {
            if case .bluetoothUnavailable(let availability) = error {
                status.connectionState = .disconnected
                notifySnapshotChanged()
                logError("[Session] scan failed bluetoothUnavailable availability=\(String(describing: availability))")
                throw SessionError.bluetoothUnavailable(availability)
            }
            logError("[Session] scan failed error=\(error.localizedDescription)")
            throw error
        }

        let identities = devices.map { MugIdentity(id: $0.id, name: $0.name, rssi: $0.rssi) }

        status.connectionState = .disconnected
        logNotice("[Session] scan completed discovered=\(identities.count)")
        notifySnapshotChanged()

        return identities
    }

    public func connect(to identity: MugIdentity) async throws {
        let previousSelection = selectedMug
        let previousCapabilityMap = capabilityMap
        let previousConnectionState = status.connectionState

        selectedMug = identity
        status.connectionState = .connecting
        appendEvent("Connecting to \(identity.id.uuidString)")
        logNotice("[Session] connect started id=\(identity.id.uuidString)")
        notifySnapshotChanged()

        do {
            try await withTimeout(seconds: 12, operation: "connect") {
                try await self.bluetooth.connect(to: identity.id)
            }
            logNotice("[Session] connect transport established id=\(identity.id.uuidString)")
            capabilityMap = try await withTimeout(seconds: 12, operation: "capability discovery") {
                try await self.bluetooth.discoverCapabilities(for: identity.id)
            }
            logNotice("[Session] capabilities discovered id=\(identity.id.uuidString) readable=\(self.capabilityMap?.readable.count ?? 0) notify=\(self.capabilityMap?.notifiable.count ?? 0)")
            status.connectionState = .connected

            if let capabilityMap {
                diagnostics.discoveredReadableCharacteristics = capabilityMap.readable.map(\.uuid).sorted()
                diagnostics.discoveredNotificationCharacteristics = capabilityMap.notifiable.map(\.uuid).sorted()
            }

            try await withTimeout(seconds: 10, operation: "initial refresh") {
                try await self.refresh()
            }
            try await subscribeToNotificationsIfSupported()
            logNotice("[Session] connect completed id=\(identity.id.uuidString)")
            notifySnapshotChanged()
        } catch {
            selectedMug = previousSelection
            capabilityMap = previousCapabilityMap
            status.connectionState = previousConnectionState
            notificationTask?.cancel()
            notificationTask = nil
            await bluetooth.disconnect(from: identity.id)
            appendEvent("Connect failed \(identity.id.uuidString): \(error.localizedDescription)")
            logError("[Session] connect failed id=\(identity.id.uuidString) error=\(error.localizedDescription)")
            notifySnapshotChanged()
            throw error
        }
    }

    public func disconnect() async {
        stopConnectionEventListening()
        guard let selectedMug else { return }
        appendEvent("Manual disconnect")
        logNotice("[Session] disconnect requested id=\(selectedMug.id.uuidString)")
        await bluetooth.disconnect(from: selectedMug.id)
        self.selectedMug = nil
        self.capabilityMap = nil
        status.connectionState = .disconnected
        notificationTask?.cancel()
        notificationTask = nil
        notifySnapshotChanged()
    }

    public func refresh(at timestamp: Date = Date()) async throws {
        guard let selectedMug else { throw SessionError.noDeviceSelected }
        guard status.connectionState == .connected else { throw SessionError.notConnected }
        logger.debug("[Session] refresh started id=\(selectedMug.id.uuidString)")

        let event = MugStatusReducer.Event(
            currentTempData: try await readIfSupported(EmberCharacteristic.currentTemp, on: selectedMug.id),
            targetTempData: try await readIfSupported(EmberCharacteristic.targetTemp, on: selectedMug.id),
            batteryData: try await readIfSupported(EmberCharacteristic.battery, on: selectedMug.id),
            liquidStateData: try await readIfSupported(EmberCharacteristic.liquidState, on: selectedMug.id),
            timestamp: timestamp
        )

        status = reducer.reduce(status: status, with: event)
        absorbWarningsFromStatus()
        logger.debug("[Session] refresh completed id=\(selectedMug.id.uuidString) warnings=\(self.diagnostics.parseWarnings.count)")
        notifySnapshotChanged()
    }

    public func handleConnectionEvent(_ event: BLEConnectionEvent) async {
        logNotice("[Session] connection event=\(String(describing: event))")
        switch event {
        case .connected(let id):
            appendEvent("Connected \(id.uuidString)")
            status.connectionState = .connected
            notifySnapshotChanged()
        case .disconnected(let id, let expected):
            appendEvent("Disconnected \(id.uuidString) expected=\(expected)")
            status.connectionState = .disconnected
            notifySnapshotChanged()
            guard !expected, let selectedMug, selectedMug.id == id else { return }
            await attemptReconnect(to: selectedMug)
        case .connectionFailed(let id, let message):
            appendEvent("Connection failed \(id.uuidString): \(message)")
            status.connectionState = .disconnected
            notifySnapshotChanged()
        }
    }

    public var snapshot: Snapshot {
        Snapshot(
            identity: selectedMug,
            status: status,
            diagnostics: diagnostics,
            capabilityMap: capabilityMap
        )
    }

    public func captureRegressionFixture(captureID: String, notes: String) async throws -> HardwareRegressionCapture {
        guard let selectedMug else { throw SessionError.noDeviceSelected }
        guard status.connectionState == .connected else { throw SessionError.notConnected }

        let currentTempData = try await readIfSupported(EmberCharacteristic.currentTemp, on: selectedMug.id)
        let targetTempData = try await readIfSupported(EmberCharacteristic.targetTemp, on: selectedMug.id)
        let batteryData = try await readIfSupported(EmberCharacteristic.battery, on: selectedMug.id)
        let liquidStateData = try await readIfSupported(EmberCharacteristic.liquidState, on: selectedMug.id)

        guard let currentTempData else { throw SessionError.missingCaptureCharacteristic("current temperature") }
        guard let targetTempData else { throw SessionError.missingCaptureCharacteristic("target temperature") }
        guard let batteryData else { throw SessionError.missingCaptureCharacteristic("battery") }
        guard let liquidStateData else { throw SessionError.missingCaptureCharacteristic("liquid state") }

        let currentTemp = try StatusParsers.parseTemperatureC(from: currentTempData).get()
        let targetTemp = try StatusParsers.parseTemperatureC(from: targetTempData).get()
        let battery = try StatusParsers.parseBattery(from: batteryData).get()
        _ = try StatusParsers.parseLiquidState(from: liquidStateData).get()

        return HardwareRegressionCapture(
            captureID: captureID,
            notes: notes,
            characteristics: HardwareCaptureCharacteristics(
                currentTemp: currentTempData.hexUppercased(),
                targetTemp: targetTempData.hexUppercased(),
                battery: batteryData.hexUppercased(),
                liquidState: liquidStateData.hexUppercased()
            ),
            expected: HardwareCaptureExpected(
                currentTempC: currentTemp,
                targetTempC: targetTemp,
                batteryPercent: battery.percent,
                isCharging: battery.isCharging,
                liquidStateRaw: liquidStateData[0]
            )
        )
    }

    private func subscribeToNotificationsIfSupported() async throws {
        guard let selectedMug, capabilityMap?.supportsPushEvents == true else { return }

        notificationTask?.cancel()
        let stream = try await bluetooth.subscribe(to: EmberCharacteristic.pushEvents, on: selectedMug.id)
        notificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in stream {
                    if Task.isCancelled { break }
                    try await self.refresh()
                }
            } catch {
                self.appendEvent("Push stream failed: \(error.localizedDescription)")
                self.logError("[Session] push stream failed id=\(selectedMug.id.uuidString) error=\(error.localizedDescription)")
                self.notifySnapshotChanged()
            }
        }
        appendEvent("Subscribed to push events")
        logNotice("[Session] push subscription established id=\(selectedMug.id.uuidString)")
        notifySnapshotChanged()
    }

    private func attemptReconnect(to identity: MugIdentity) async {
        guard reconnectMaxAttempts > 0 else { return }
        logNotice("[Session] reconnect started id=\(identity.id.uuidString) maxAttempts=\(self.reconnectMaxAttempts)")

        for attempt in 1...reconnectMaxAttempts {
            do {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
                appendEvent("Reconnect attempt \(attempt)")
                logNotice("[Session] reconnect attempt=\(attempt) id=\(identity.id.uuidString)")
                try await connect(to: identity)
                appendEvent("Reconnect succeeded")
                logNotice("[Session] reconnect succeeded id=\(identity.id.uuidString)")
                return
            } catch {
                appendEvent("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                logError("[Session] reconnect failed attempt=\(attempt) id=\(identity.id.uuidString) error=\(error.localizedDescription)")
            }
        }
    }

    private func readIfSupported(_ characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data? {
        guard capabilityMap?.readable.contains(characteristic) == true else { return nil }
        return try await bluetooth.readValue(for: characteristic, on: deviceID)
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SessionError.operationTimedOut(operation: operation)
            }

            guard let first = try await group.next() else {
                throw SessionError.operationTimedOut(operation: operation)
            }
            group.cancelAll()
            return first
        }
    }

    private func appendEvent(_ message: String) {
        diagnostics.connectionEvents.append(ConnectionEventRecord(message: message))
        if diagnostics.connectionEvents.count > 50 {
            diagnostics.connectionEvents.removeFirst(diagnostics.connectionEvents.count - 50)
        }
    }

    private func absorbWarningsFromStatus() {
        let warnings = status.rawDiagnostics.values.sorted()

        switch compatibilityMode {
        case .strict:
            diagnostics.parseWarnings = warnings
        case .permissive:
            diagnostics.parseWarnings = Array(Set(diagnostics.parseWarnings + warnings)).sorted()
        }
    }

    private func notifySnapshotChanged() {
        onSnapshotChanged?(snapshot)
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


extension MugSessionCoordinator: @unchecked Sendable {}

private extension Data {
    func hexUppercased() -> String {
        map { String(format: "%02X", $0) }.joined()
    }
}
