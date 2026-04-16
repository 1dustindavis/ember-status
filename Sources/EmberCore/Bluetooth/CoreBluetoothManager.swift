import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth

public enum CoreBluetoothManagerError: Error, LocalizedError {
    case bluetoothUnavailable(BLEAvailability)
    case peripheralNotFound(UUID)
    case notConnected(UUID)
    case characteristicNotFound(BLECharacteristicID)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let availability):
            return "Bluetooth unavailable: \(availability)"
        case .peripheralNotFound(let id):
            return "Peripheral not found: \(id.uuidString)"
        case .notConnected(let id):
            return "Peripheral is not connected: \(id.uuidString)"
        case .characteristicNotFound(let characteristic):
            return "Characteristic not found: \(characteristic.uuid)"
        }
    }
}

public final class CoreBluetoothManager: NSObject, BluetoothManaging {
    fileprivate let queue = DispatchQueue(label: "ember.core.bluetooth")
    fileprivate let central: CBCentralManager
    fileprivate let delegateProxy: DelegateProxy
    fileprivate var scanContinuation: CheckedContinuation<[BLEDevice], Error>?
    fileprivate var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    fileprivate var capabilitiesContinuations: [UUID: CheckedContinuation<MugCapabilityMap, Error>] = [:]
    fileprivate var readContinuations: [ReadRequestKey: CheckedContinuation<Data, Error>] = [:]
    fileprivate var discoveredDevices: [UUID: BLEDevice] = [:]
    fileprivate var peripheralsByID: [UUID: CBPeripheral] = [:]
    fileprivate var characteristicsByPeripheral: [UUID: [BLECharacteristicID: CBCharacteristic]] = [:]
    fileprivate var pendingServiceDiscoveryCount: [UUID: Int] = [:]
    fileprivate var readableByPeripheral: [UUID: Set<BLECharacteristicID>] = [:]
    fileprivate var notifiableByPeripheral: [UUID: Set<BLECharacteristicID>] = [:]
    fileprivate var subscriptionContinuations: [SubscriptionKey: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    fileprivate var eventContinuation: AsyncStream<BLEConnectionEvent>.Continuation?
    fileprivate let events: AsyncStream<BLEConnectionEvent>

    public override init() {
        let proxy = DelegateProxy()
        self.delegateProxy = proxy

        var continuation: AsyncStream<BLEConnectionEvent>.Continuation?
        self.events = AsyncStream { localContinuation in
            continuation = localContinuation
        }
        self.eventContinuation = continuation

        self.central = CBCentralManager(delegate: proxy, queue: queue)
        super.init()
        proxy.owner = self
    }

    deinit {
        queue.async { [eventContinuation] in
            eventContinuation?.finish()
        }
    }

    public var availability: BLEAvailability {
        get async { queue.sync { Self.map(state: central.state) } }
    }

    public func startScanning() async throws -> [BLEDevice] {
        try await ensurePoweredOn()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.discoveredDevices.removeAll(keepingCapacity: true)
                self.scanContinuation = continuation
                self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

                self.queue.asyncAfter(deadline: .now() + .seconds(2)) {
                    self.finishScanIfNeeded()
                }
            }
        }
    }

    public func stopScanning() async {
        queue.async {
            self.finishScanIfNeeded()
        }
    }

    public func connect(to deviceID: UUID) async throws {
        try await ensurePoweredOn()

        let peripheral = try await queueSyncResult { [self] in
            guard let peripheral = self.peripheralsByID[deviceID] else {
                throw CoreBluetoothManagerError.peripheralNotFound(deviceID)
            }
            return peripheral
        }

        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.connectContinuations[deviceID] = continuation
                peripheral.delegate = self.delegateProxy
                self.central.connect(peripheral, options: nil)
            }
        }
    }

    public func disconnect(from deviceID: UUID) async {
        queue.async {
            guard let peripheral = self.peripheralsByID[deviceID] else { return }
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    public func discoverCapabilities(for deviceID: UUID) async throws -> MugCapabilityMap {
        let peripheral = try await queueSyncResult { [self] in
            guard let peripheral = self.peripheralsByID[deviceID] else {
                throw CoreBluetoothManagerError.peripheralNotFound(deviceID)
            }
            guard peripheral.state == .connected else {
                throw CoreBluetoothManagerError.notConnected(deviceID)
            }
            return peripheral
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readableByPeripheral[deviceID] = []
                self.notifiableByPeripheral[deviceID] = []
                self.characteristicsByPeripheral[deviceID] = [:]
                self.pendingServiceDiscoveryCount[deviceID] = 0
                self.capabilitiesContinuations[deviceID] = continuation
                peripheral.discoverServices(nil)
            }
        }
    }

    public func readValue(for characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data {
        let cbCharacteristic = try await queueSyncResult { [self] in
            guard let peripheral = self.peripheralsByID[deviceID] else {
                throw CoreBluetoothManagerError.peripheralNotFound(deviceID)
            }
            guard peripheral.state == .connected else {
                throw CoreBluetoothManagerError.notConnected(deviceID)
            }
            guard let cbCharacteristic = self.characteristicsByPeripheral[deviceID]?[characteristic] else {
                throw CoreBluetoothManagerError.characteristicNotFound(characteristic)
            }
            return cbCharacteristic
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readContinuations[ReadRequestKey(deviceID: deviceID, characteristic: characteristic)] = continuation
                self.peripheralsByID[deviceID]?.readValue(for: cbCharacteristic)
            }
        }
    }

    public func subscribe(
        to characteristic: BLECharacteristicID,
        on deviceID: UUID
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let cbCharacteristic = try await queueSyncResult { [self] in
            guard let peripheral = self.peripheralsByID[deviceID] else {
                throw CoreBluetoothManagerError.peripheralNotFound(deviceID)
            }
            guard peripheral.state == .connected else {
                throw CoreBluetoothManagerError.notConnected(deviceID)
            }
            guard let cbCharacteristic = self.characteristicsByPeripheral[deviceID]?[characteristic] else {
                throw CoreBluetoothManagerError.characteristicNotFound(characteristic)
            }
            return cbCharacteristic
        }

        return AsyncThrowingStream { continuation in
            queue.async {
                let key = SubscriptionKey(deviceID: deviceID, characteristic: characteristic)
                self.subscriptionContinuations[key] = continuation
                self.peripheralsByID[deviceID]?.setNotifyValue(true, for: cbCharacteristic)
                continuation.onTermination = { [weak self] _ in
                    self?.queue.async {
                        self?.subscriptionContinuations.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    public var connectionEvents: AsyncStream<BLEConnectionEvent> { events }

    private func ensurePoweredOn() async throws {
        let availability = await availability
        guard availability == .poweredOn else {
            throw CoreBluetoothManagerError.bluetoothUnavailable(availability)
        }
    }

    private func finishScanIfNeeded() {
        central.stopScan()
        guard let continuation = scanContinuation else { return }
        scanContinuation = nil
        continuation.resume(returning: Array(discoveredDevices.values))
    }

    private func queueSyncResult<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func map(state: CBManagerState) -> BLEAvailability {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown, .resetting: return .unknown
        @unknown default: return .unknown
        }
    }
}

fileprivate struct ReadRequestKey: Hashable {
    let deviceID: UUID
    let characteristic: BLECharacteristicID
}

fileprivate struct SubscriptionKey: Hashable {
    let deviceID: UUID
    let characteristic: BLECharacteristicID
}

fileprivate final class DelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: CoreBluetoothManager?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // No-op: availability is pulled on-demand.
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let owner else { return }
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        owner.peripheralsByID[id] = peripheral
        let next = BLEDevice(id: id, name: name, rssi: RSSI.intValue)
        if let existing = owner.discoveredDevices[id] {
            owner.discoveredDevices[id] = existing.rssi >= next.rssi ? existing : next
        } else {
            owner.discoveredDevices[id] = next
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let owner else { return }
        let id = peripheral.identifier
        owner.connectContinuations.removeValue(forKey: id)?.resume()
        owner.eventContinuation?.yield(.connected(id))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        let message = error?.localizedDescription ?? "Failed to connect"
        owner.connectContinuations.removeValue(forKey: id)?.resume(throwing: error ?? CoreBluetoothManagerError.peripheralNotFound(id))
        owner.eventContinuation?.yield(.connectionFailed(id, message: message))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        let expected = (error == nil)
        owner.eventContinuation?.yield(.disconnected(id, expected: expected))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        if let error {
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(throwing: error)
            return
        }

        let services = peripheral.services ?? []
        owner.pendingServiceDiscoveryCount[id] = services.count
        if services.isEmpty {
            let capability = MugCapabilityMap(readable: [], notifiable: [])
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(returning: capability)
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier

        if let error {
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(throwing: error)
            return
        }

        var byID = owner.characteristicsByPeripheral[id] ?? [:]
        var readable = owner.readableByPeripheral[id] ?? []
        var notifiable = owner.notifiableByPeripheral[id] ?? []

        for cbCharacteristic in service.characteristics ?? [] {
            let characteristicID = BLECharacteristicID(cbCharacteristic.uuid.uuidString.lowercased())
            if EmberCharacteristic.readOnlyStatus.contains(characteristicID) || EmberCharacteristic.notificationCharacteristics.contains(characteristicID) {
                byID[characteristicID] = cbCharacteristic
            }
            if cbCharacteristic.properties.contains(.read) {
                readable.insert(characteristicID)
            }
            if cbCharacteristic.properties.contains(.notify) {
                notifiable.insert(characteristicID)
            }
        }

        owner.characteristicsByPeripheral[id] = byID
        owner.readableByPeripheral[id] = readable
        owner.notifiableByPeripheral[id] = notifiable

        let remaining = max((owner.pendingServiceDiscoveryCount[id] ?? 1) - 1, 0)
        owner.pendingServiceDiscoveryCount[id] = remaining

        if remaining == 0 {
            let map = MugCapabilityMap(readable: readable, notifiable: notifiable)
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(returning: map)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        let characteristicID = BLECharacteristicID(characteristic.uuid.uuidString.lowercased())

        if let error {
            owner.readContinuations.removeValue(forKey: ReadRequestKey(deviceID: id, characteristic: characteristicID))?.resume(throwing: error)
            owner.subscriptionContinuations[SubscriptionKey(deviceID: id, characteristic: characteristicID)]?.finish(throwing: error)
            owner.subscriptionContinuations.removeValue(forKey: SubscriptionKey(deviceID: id, characteristic: characteristicID))
            return
        }

        let value = characteristic.value ?? Data()
        owner.readContinuations.removeValue(forKey: ReadRequestKey(deviceID: id, characteristic: characteristicID))?.resume(returning: value)
        owner.subscriptionContinuations[SubscriptionKey(deviceID: id, characteristic: characteristicID)]?.yield(value)
    }
}

extension CoreBluetoothManager: @unchecked Sendable {}

#else

public final class CoreBluetoothManager: BluetoothManaging {
    public init() {}

    public var availability: BLEAvailability {
        get async { .unsupported }
    }

    public func startScanning() async throws -> [BLEDevice] { [] }
    public func stopScanning() async {}
    public func connect(to deviceID: UUID) async throws {}
    public func disconnect(from deviceID: UUID) async {}
    public func discoverCapabilities(for deviceID: UUID) async throws -> MugCapabilityMap {
        MugCapabilityMap(readable: [], notifiable: [])
    }
    public func readValue(for characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> Data { Data() }
    public func subscribe(to characteristic: BLECharacteristicID, on deviceID: UUID) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    public var connectionEvents: AsyncStream<BLEConnectionEvent> { AsyncStream { continuation in continuation.finish() } }
}

#endif
