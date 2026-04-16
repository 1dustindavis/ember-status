import Foundation

public final class MugSessionCoordinator {
    public enum SessionError: Error, Equatable, LocalizedError {
        case bluetoothUnavailable(BLEAvailability)
        case noDeviceSelected

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
        notifySnapshotChanged()
    }

    @discardableResult
    public func scanAndRankDevices() async throws -> [MugIdentity] {
        status.connectionState = .scanning
        notifySnapshotChanged()

        let devices: [BLEDevice]
        do {
            devices = try await bluetooth.startScanning().sorted { $0.rssi > $1.rssi }
        } catch let error as CoreBluetoothManagerError {
            if case .bluetoothUnavailable(let availability) = error {
                status.connectionState = .disconnected
                notifySnapshotChanged()
                throw SessionError.bluetoothUnavailable(availability)
            }
            throw error
        }

        let identities = devices.map { MugIdentity(id: $0.id, name: $0.name, rssi: $0.rssi) }

        if identities.isEmpty {
            status.connectionState = .disconnected
        }
        notifySnapshotChanged()

        return identities
    }

    public func connect(to identity: MugIdentity) async throws {
        selectedMug = identity
        status.connectionState = .connecting
        appendEvent("Connecting to \(identity.id.uuidString)")

        try await bluetooth.connect(to: identity.id)
        capabilityMap = try await bluetooth.discoverCapabilities(for: identity.id)
        status.connectionState = .connected

        if let capabilityMap {
            diagnostics.discoveredReadableCharacteristics = capabilityMap.readable.map(\.uuid).sorted()
            diagnostics.discoveredNotificationCharacteristics = capabilityMap.notifiable.map(\.uuid).sorted()
        }

        try await refresh()
        try await subscribeToNotificationsIfSupported()
        notifySnapshotChanged()
    }

    public func disconnect() async {
        stopConnectionEventListening()
        guard let selectedMug else { return }
        appendEvent("Manual disconnect")
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

        let event = MugStatusReducer.Event(
            currentTempData: try await readIfSupported(EmberCharacteristic.currentTemp, on: selectedMug.id),
            targetTempData: try await readIfSupported(EmberCharacteristic.targetTemp, on: selectedMug.id),
            batteryData: try await readIfSupported(EmberCharacteristic.battery, on: selectedMug.id),
            liquidStateData: try await readIfSupported(EmberCharacteristic.liquidState, on: selectedMug.id),
            timestamp: timestamp
        )

        status = reducer.reduce(status: status, with: event)
        absorbWarningsFromStatus()
        notifySnapshotChanged()
    }

    public func handleConnectionEvent(_ event: BLEConnectionEvent) async {
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
                self.notifySnapshotChanged()
            }
        }
        appendEvent("Subscribed to push events")
        notifySnapshotChanged()
    }

    private func attemptReconnect(to identity: MugIdentity) async {
        guard reconnectMaxAttempts > 0 else { return }

        for attempt in 1...reconnectMaxAttempts {
            do {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
                appendEvent("Reconnect attempt \(attempt)")
                try await connect(to: identity)
                appendEvent("Reconnect succeeded")
                return
            } catch {
                appendEvent("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
    }

    private func readIfSupported(_ characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data? {
        guard capabilityMap?.readable.contains(characteristic) == true else { return nil }
        return try await bluetooth.readValue(for: characteristic, on: deviceID)
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
}


extension MugSessionCoordinator: @unchecked Sendable {}
