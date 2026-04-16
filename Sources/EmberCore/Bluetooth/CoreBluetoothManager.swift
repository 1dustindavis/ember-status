import Foundation
import OSLog

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth

public enum CoreBluetoothManagerError: Error, Equatable, LocalizedError, Sendable {
    case bluetoothUnavailable(BLEAvailability)
    case peripheralNotFound(UUID)
    case notConnected(UUID)
    case connectTimedOut(UUID)
    case characteristicNotFound(BLECharacteristicID)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let availability):
            return "Bluetooth unavailable: \(availability)"
        case .peripheralNotFound(let id):
            return "Peripheral not found: \(id.uuidString)"
        case .notConnected(let id):
            return "Peripheral is not connected: \(id.uuidString)"
        case .connectTimedOut(let id):
            return "Timed out while connecting to peripheral: \(id.uuidString)"
        case .characteristicNotFound(let characteristic):
            return "Characteristic not found: \(characteristic.uuid)"
        }
    }
}

public final class CoreBluetoothManager: NSObject, BluetoothManaging {
    fileprivate let logger = Logger(subsystem: "com.github.1dustindavis.EmberStatusApp", category: "BLE")
    fileprivate let queue = DispatchQueue(label: "ember.core.bluetooth")
    fileprivate let central: CBCentralManager
    fileprivate let delegateProxy: DelegateProxy
    fileprivate var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    fileprivate var connectTimeoutTasks: [UUID: Task<Void, Never>] = [:]
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
        logNotice("BLE scan start")
        await queueAsync {
            self.discoveredDevices.removeAll(keepingCapacity: true)
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }

        // Use a fixed scan window so UI never waits indefinitely.
        // Real devices can advertise slowly, so keep this a bit longer.
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        return await queueSync {
            self.central.stopScan()
            let devices = Array(self.discoveredDevices.values)
            self.logNotice("BLE scan complete: \(devices.count) devices")
            return devices
        }
    }

    public func stopScanning() async {
        await queueAsync {
            self.central.stopScan()
        }
    }

    public func connect(to deviceID: UUID) async throws {
        try await ensurePoweredOn()
        logNotice("BLE connect requested id=\(deviceID.uuidString)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheralsByID[deviceID] else {
                    self.logError("BLE connect failed missing peripheral id=\(deviceID.uuidString)")
                    continuation.resume(throwing: CoreBluetoothManagerError.peripheralNotFound(deviceID))
                    return
                }
                peripheral.delegate = self.delegateProxy
                if peripheral.state == .connected {
                    self.logNotice("BLE connect short-circuit already connected id=\(deviceID.uuidString)")
                    continuation.resume()
                    return
                }
                self.connectContinuations[deviceID] = continuation
                self.startConnectTimeout(for: deviceID)
                self.central.connect(peripheral, options: nil)
            }
        }
    }

    public func disconnect(from deviceID: UUID) async {
        logNotice("BLE disconnect requested id=\(deviceID.uuidString)")
        queue.async {
            guard let peripheral = self.peripheralsByID[deviceID] else { return }
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    public func discoverCapabilities(for deviceID: UUID) async throws -> MugCapabilityMap {
        logNotice("BLE discover capabilities requested id=\(deviceID.uuidString)")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let peripheral = self.peripheralsByID[deviceID] else {
                    self.logError("BLE discover capabilities failed missing peripheral id=\(deviceID.uuidString)")
                    continuation.resume(throwing: CoreBluetoothManagerError.peripheralNotFound(deviceID))
                    return
                }
                guard peripheral.state == .connected else {
                    self.logError("BLE discover capabilities failed not connected id=\(deviceID.uuidString)")
                    continuation.resume(throwing: CoreBluetoothManagerError.notConnected(deviceID))
                    return
                }
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
        logger.debug("BLE read requested id=\(deviceID.uuidString) characteristic=\(characteristic.uuid)")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let peripheral = self.peripheralsByID[deviceID] else {
                    self.logError("BLE read failed missing peripheral id=\(deviceID.uuidString)")
                    continuation.resume(throwing: CoreBluetoothManagerError.peripheralNotFound(deviceID))
                    return
                }
                guard peripheral.state == .connected else {
                    self.logError("BLE read failed not connected id=\(deviceID.uuidString)")
                    continuation.resume(throwing: CoreBluetoothManagerError.notConnected(deviceID))
                    return
                }
                guard let cbCharacteristic = self.characteristicsByPeripheral[deviceID]?[characteristic] else {
                    self.logError("BLE read failed missing characteristic id=\(deviceID.uuidString) characteristic=\(characteristic.uuid)")
                    continuation.resume(throwing: CoreBluetoothManagerError.characteristicNotFound(characteristic))
                    return
                }
                self.readContinuations[ReadRequestKey(deviceID: deviceID, characteristic: characteristic)] = continuation
                peripheral.readValue(for: cbCharacteristic)
            }
        }
    }

    public func subscribe(
        to characteristic: BLECharacteristicID,
        on deviceID: UUID
    ) async throws -> AsyncThrowingStream<Data, Error> {
        logNotice("BLE subscribe requested id=\(deviceID.uuidString) characteristic=\(characteristic.uuid)")
        return AsyncThrowingStream { continuation in
            queue.async {
                guard let peripheral = self.peripheralsByID[deviceID] else {
                    self.logError("BLE subscribe failed missing peripheral id=\(deviceID.uuidString)")
                    continuation.finish(throwing: CoreBluetoothManagerError.peripheralNotFound(deviceID))
                    return
                }
                guard peripheral.state == .connected else {
                    self.logError("BLE subscribe failed not connected id=\(deviceID.uuidString)")
                    continuation.finish(throwing: CoreBluetoothManagerError.notConnected(deviceID))
                    return
                }
                guard let cbCharacteristic = self.characteristicsByPeripheral[deviceID]?[characteristic] else {
                    self.logError("BLE subscribe failed missing characteristic id=\(deviceID.uuidString) characteristic=\(characteristic.uuid)")
                    continuation.finish(throwing: CoreBluetoothManagerError.characteristicNotFound(characteristic))
                    return
                }
                let key = SubscriptionKey(deviceID: deviceID, characteristic: characteristic)
                self.subscriptionContinuations[key] = continuation
                peripheral.setNotifyValue(true, for: cbCharacteristic)
                continuation.onTermination = { [weak self] _ in
                    guard let owner = self else { return }
                    owner.queue.async {
                        owner.subscriptionContinuations.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    public var connectionEvents: AsyncStream<BLEConnectionEvent> { events }

    private func ensurePoweredOn() async throws {
        var availability = await availability

        // On first launch, authorization/state can settle asynchronously after
        // the user responds to the Bluetooth prompt. Give CoreBluetooth time
        // to transition to poweredOn before failing.
        if availability != .poweredOn {
            for _ in 0..<48 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                availability = await self.availability
                if availability == .poweredOn {
                    break
                }
            }
        }

        guard availability == .poweredOn else {
            logError("BLE unavailable: \(String(describing: availability))")
            throw CoreBluetoothManagerError.bluetoothUnavailable(availability)
        }
    }

    private func queueSync<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func queueAsync(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    fileprivate func failPendingOperationsOnDisconnect(deviceID: UUID) {
        let disconnectionError = CoreBluetoothManagerError.notConnected(deviceID)
        logNotice("BLE disconnect cleanup id=\(deviceID.uuidString)")
        clearConnectTimeout(for: deviceID)

        connectContinuations.removeValue(forKey: deviceID)?.resume(throwing: disconnectionError)
        capabilitiesContinuations.removeValue(forKey: deviceID)?.resume(throwing: disconnectionError)

        let pendingReadKeys = readContinuations.keys.filter { $0.deviceID == deviceID }
        for key in pendingReadKeys {
            readContinuations.removeValue(forKey: key)?.resume(throwing: disconnectionError)
        }

        let pendingSubscriptionKeys = subscriptionContinuations.keys.filter { $0.deviceID == deviceID }
        for key in pendingSubscriptionKeys {
            subscriptionContinuations[key]?.finish(throwing: disconnectionError)
            subscriptionContinuations.removeValue(forKey: key)
        }

        characteristicsByPeripheral.removeValue(forKey: deviceID)
        pendingServiceDiscoveryCount.removeValue(forKey: deviceID)
        readableByPeripheral.removeValue(forKey: deviceID)
        notifiableByPeripheral.removeValue(forKey: deviceID)
    }

    fileprivate func startConnectTimeout(for deviceID: UUID) {
        clearConnectTimeout(for: deviceID)
        connectTimeoutTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self else { return }
            self.queue.async {
                guard let continuation = self.connectContinuations.removeValue(forKey: deviceID) else { return }
                self.clearConnectTimeout(for: deviceID)
                self.logError("BLE connect timed out id=\(deviceID.uuidString)")
                if let peripheral = self.peripheralsByID[deviceID] {
                    self.central.cancelPeripheralConnection(peripheral)
                }
                continuation.resume(throwing: CoreBluetoothManagerError.connectTimedOut(deviceID))
                self.eventContinuation?.yield(.connectionFailed(deviceID, message: "Connection timed out"))
            }
        }
    }

    fileprivate func clearConnectTimeout(for deviceID: UUID) {
        connectTimeoutTasks.removeValue(forKey: deviceID)?.cancel()
    }

    fileprivate func logNotice(_ message: String) {
        logger.notice("\(message)")
        NSLog("%@", message)
    }

    fileprivate func logError(_ message: String) {
        logger.error("\(message)")
        NSLog("%@", message)
    }

    fileprivate static func map(state: CBManagerState) -> BLEAvailability {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown, .resetting: return .unknown
        @unknown default: return .unknown
        }
    }

    fileprivate static func looksLikeEmberPeripheral(
        peripheralName: String?,
        advertisementData: [String: Any]
    ) -> Bool {
        func containsEmber(_ value: String?) -> Bool {
            guard let value else { return false }
            return value.localizedCaseInsensitiveContains("ember")
        }

        if containsEmber(peripheralName) {
            return true
        }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if containsEmber(localName) {
            return true
        }

        let allServiceUUIDs = (
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) +
            (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        )
        if allServiceUUIDs.contains(where: Self.isLikelyEmberServiceUUID) {
            return true
        }

        return false
    }

    fileprivate static func isLikelyEmberServiceUUID(_ uuid: CBUUID) -> Bool {
        let normalized = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Ember characteristics use the fc54 family. In advertisements this may appear
        // as 16-bit FC54 or as a full 128-bit UUID with fc54 prefix.
        return normalized.hasPrefix("fc54")
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
        guard let owner else { return }
        let availability = CoreBluetoothManager.map(state: central.state)
        owner.logNotice("Central state update: \(String(describing: availability))")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let owner else { return }
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        guard CoreBluetoothManager.looksLikeEmberPeripheral(peripheralName: name, advertisementData: advertisementData) else {
            owner.logger.debug("Ignoring non-Ember peripheral id=\(id.uuidString) name=\(name ?? "unknown")")
            return
        }
        owner.peripheralsByID[id] = peripheral
        let next = BLEDevice(id: id, name: name, rssi: RSSI.intValue)
        owner.logger.debug("Discovered peripheral id=\(id.uuidString) name=\(name ?? "unknown") rssi=\(RSSI.intValue)")
        if let existing = owner.discoveredDevices[id] {
            owner.discoveredDevices[id] = existing.rssi >= next.rssi ? existing : next
        } else {
            owner.discoveredDevices[id] = next
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let owner else { return }
        let id = peripheral.identifier
        owner.clearConnectTimeout(for: id)
        owner.logNotice("BLE connected id=\(id.uuidString)")
        owner.connectContinuations.removeValue(forKey: id)?.resume()
        owner.eventContinuation?.yield(.connected(id))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        owner.clearConnectTimeout(for: id)
        let message = error?.localizedDescription ?? "Failed to connect"
        owner.logError("BLE failed to connect id=\(id.uuidString) error=\(message)")
        owner.connectContinuations.removeValue(forKey: id)?.resume(throwing: error ?? CoreBluetoothManagerError.peripheralNotFound(id))
        owner.eventContinuation?.yield(.connectionFailed(id, message: message))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        let expected = (error == nil)
        owner.logNotice("BLE disconnected id=\(id.uuidString) expected=\(expected)")
        owner.failPendingOperationsOnDisconnect(deviceID: id)
        owner.eventContinuation?.yield(.disconnected(id, expected: expected))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        if let error {
            owner.logError("BLE discover services failed id=\(id.uuidString) error=\(error.localizedDescription)")
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(throwing: error)
            return
        }

        let services = peripheral.services ?? []
        owner.pendingServiceDiscoveryCount[id] = services.count
        owner.logNotice("BLE services discovered id=\(id.uuidString) count=\(services.count)")
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
            owner.logError("BLE discover characteristics failed id=\(id.uuidString) error=\(error.localizedDescription)")
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
            owner.logNotice("BLE capabilities ready id=\(id.uuidString) readable=\(readable.count) notify=\(notifiable.count)")
            owner.capabilitiesContinuations.removeValue(forKey: id)?.resume(returning: map)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner else { return }
        let id = peripheral.identifier
        let characteristicID = BLECharacteristicID(characteristic.uuid.uuidString.lowercased())

        if let error {
            owner.logError("BLE value update failed id=\(id.uuidString) characteristic=\(characteristicID.uuid) error=\(error.localizedDescription)")
            owner.readContinuations.removeValue(forKey: ReadRequestKey(deviceID: id, characteristic: characteristicID))?.resume(throwing: error)
            owner.subscriptionContinuations[SubscriptionKey(deviceID: id, characteristic: characteristicID)]?.finish(throwing: error)
            owner.subscriptionContinuations.removeValue(forKey: SubscriptionKey(deviceID: id, characteristic: characteristicID))
            return
        }

        let value = characteristic.value ?? Data()
        owner.logger.debug("BLE value update id=\(id.uuidString) characteristic=\(characteristicID.uuid) bytes=\(value.count)")
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
