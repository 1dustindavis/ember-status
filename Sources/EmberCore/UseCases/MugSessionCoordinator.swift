import Foundation

@MainActor
public final class MugSessionCoordinator {
    public enum SessionError: Error, Equatable {
        case bluetoothUnavailable(BLEAvailability)
        case noDeviceSelected
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
    private let parseWarningsLimit: Int
    private var connectionEventsTask: Task<Void, Never>?
    private var pushEventsTask: Task<Void, Never>?

    private(set) public var compatibilityMode: ProtocolCompatibilityMode
    private(set) public var selectedMug: MugIdentity?
    private(set) public var status: MugStatus
    private(set) public var diagnostics: MugDiagnostics
    private(set) public var capabilityMap: MugCapabilityMap?

    public init(
        bluetooth: BluetoothManaging,
        reducer: MugStatusReducer = MugStatusReducer(),
        compatibilityMode: ProtocolCompatibilityMode = .permissive,
        reconnectMaxAttempts: Int = 2,
        parseWarningsLimit: Int = 50
    ) {
        self.bluetooth = bluetooth
        self.reducer = reducer
        self.compatibilityMode = compatibilityMode
        self.reconnectMaxAttempts = reconnectMaxAttempts
        self.parseWarningsLimit = parseWarningsLimit
        self.status = MugStatus()
        self.diagnostics = MugDiagnostics()
    }

    public func setCompatibilityMode(_ mode: ProtocolCompatibilityMode) {
        compatibilityMode = mode
    }

    deinit {
        connectionEventsTask?.cancel()
        pushEventsTask?.cancel()
    }

    public func startConnectionEventListening() {
        connectionEventsTask?.cancel()
        appendEvent("Started connection event listener")

        connectionEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in bluetooth.connectionEvents {
                if Task.isCancelled { break }
                await handleConnectionEvent(event)
            }
        }
    }

    public func stopConnectionEventListening() {
        connectionEventsTask?.cancel()
        connectionEventsTask = nil
        pushEventsTask?.cancel()
        pushEventsTask = nil
        appendEvent("Stopped connection event listener")
    }

    @discardableResult
    public func scanAndRankDevices() async throws -> [MugIdentity] {
        let availability = await bluetooth.availability
        guard availability == .poweredOn else {
            status.connectionState = .disconnected
            throw SessionError.bluetoothUnavailable(availability)
        }

        status.connectionState = .scanning
        let devices = try await bluetooth.startScanning().sorted { $0.rssi > $1.rssi }
        let identities = devices.map { MugIdentity(id: $0.id, name: $0.name, rssi: $0.rssi) }

        if identities.isEmpty {
            status.connectionState = .disconnected
        }

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
    }

    public func disconnect() async {
        stopConnectionEventListening()
        if let selectedMug {
            appendEvent("Manual disconnect")
            await bluetooth.disconnect(from: selectedMug.id)
        }
        self.selectedMug = nil
        self.capabilityMap = nil
        status.connectionState = .disconnected
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
    }

    public func handleConnectionEvent(_ event: BLEConnectionEvent) async {
        switch event {
        case .connected(let id):
            appendEvent("Connected \(id.uuidString)")
            status.connectionState = .connected
        case .disconnected(let id, let expected):
            appendEvent("Disconnected \(id.uuidString) expected=\(expected)")
            status.connectionState = .disconnected
            guard !expected, let selectedMug, selectedMug.id == id else { return }
            await attemptReconnect(to: selectedMug)
        case .connectionFailed(let id, let message):
            appendEvent("Connection failed \(id.uuidString): \(message)")
            status.connectionState = .disconnected
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

        let stream = try await bluetooth.subscribe(to: EmberCharacteristic.pushEvents, on: selectedMug.id)
        pushEventsTask?.cancel()
        pushEventsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in stream {
                    if Task.isCancelled { break }
                    await handlePushNotificationEvent()
                }
            } catch {
                appendEvent("Push event stream failed: \(error.localizedDescription)")
            }
        }
        appendEvent("Subscribed to push events")
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
        let warnings = status.rawDiagnostics.values.map { $0.toRecord(timestamp: status.lastUpdated) }
        let sortedWarnings = warnings.sorted { $0.detail < $1.detail }

        switch compatibilityMode {
        case .strict:
            diagnostics.parseWarnings = capped(sortedWarnings)
        case .permissive:
            let merged = dedupeWarnings(diagnostics.parseWarnings + sortedWarnings)
            diagnostics.parseWarnings = capped(merged)
        }
    }

    private func handlePushNotificationEvent() async {
        appendEvent("Push event received")
        do {
            try await refresh()
        } catch {
            appendEvent("Push-triggered refresh failed: \(error.localizedDescription)")
        }
    }

    private func dedupeWarnings(_ warnings: [ParseWarningRecord]) -> [ParseWarningRecord] {
        var seen: Set<String> = []
        var deduped: [ParseWarningRecord] = []

        for warning in warnings.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = [
                warning.field,
                warning.code.rawValue,
                warning.detail,
                warning.expectedLength.map(String.init) ?? "",
                warning.actualLength.map(String.init) ?? "",
                warning.rawValue.map(String.init) ?? ""
            ].joined(separator: "|")

            if seen.insert(key).inserted {
                deduped.append(warning)
            }
        }

        return deduped
    }

    private func capped(_ warnings: [ParseWarningRecord]) -> [ParseWarningRecord] {
        guard warnings.count > parseWarningsLimit else { return warnings }
        return Array(warnings.suffix(parseWarningsLimit))
    }
}
