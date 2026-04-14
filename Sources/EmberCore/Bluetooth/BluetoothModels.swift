import Foundation

public struct BLEDevice: Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int

    public init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum BLEConnectionEvent: Equatable, Sendable {
    case connected(UUID)
    case disconnected(UUID, expected: Bool)
    case connectionFailed(UUID, message: String)
}

public enum BLEAvailability: Equatable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
}

public struct BLECharacteristicID: Hashable, Sendable {
    public let uuid: String

    public init(_ uuid: String) {
        self.uuid = uuid.lowercased()
    }
}

public enum EmberCharacteristic {
    // Canonical IDs are intentionally string-based so parser logic is independent of CoreBluetooth types.
    public static let currentTemp = BLECharacteristicID("fc540002-236c-4c94-8fa9-944a3e5353fa")
    public static let targetTemp = BLECharacteristicID("fc540003-236c-4c94-8fa9-944a3e5353fa")
    public static let battery = BLECharacteristicID("fc540007-236c-4c94-8fa9-944a3e5353fa")
    public static let liquidState = BLECharacteristicID("fc540008-236c-4c94-8fa9-944a3e5353fa")
    public static let pushEvents = BLECharacteristicID("fc540014-236c-4c94-8fa9-944a3e5353fa")

    public static let readOnlyStatus: Set<BLECharacteristicID> = [
        currentTemp,
        targetTemp,
        battery,
        liquidState
    ]

    public static let notificationCharacteristics: Set<BLECharacteristicID> = [
        pushEvents
    ]
}

public struct MugCapabilityMap: Equatable, Sendable {
    public let readable: Set<BLECharacteristicID>
    public let notifiable: Set<BLECharacteristicID>

    public init(readable: Set<BLECharacteristicID>, notifiable: Set<BLECharacteristicID>) {
        self.readable = readable
        self.notifiable = notifiable
    }

    public var supportsCurrentTemp: Bool { readable.contains(EmberCharacteristic.currentTemp) }
    public var supportsTargetTemp: Bool { readable.contains(EmberCharacteristic.targetTemp) }
    public var supportsBattery: Bool { readable.contains(EmberCharacteristic.battery) }
    public var supportsLiquidState: Bool { readable.contains(EmberCharacteristic.liquidState) }
    public var supportsPushEvents: Bool { notifiable.contains(EmberCharacteristic.pushEvents) }
}
