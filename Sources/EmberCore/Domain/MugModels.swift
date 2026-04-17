import Foundation

public struct MugIdentity: Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int?

    public init(id: UUID, name: String? = nil, rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum LiquidState: Equatable, Sendable {
    case empty
    case filling
    case cooling
    case heating
    case atTargetHold
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0, 1: self = .empty
        case 2: self = .filling
        case 3, 4: self = .cooling
        case 5: self = .heating
        case 6: self = .atTargetHold
        default: self = .unknown(rawValue)
        }
    }

    public var displayName: String {
        switch self {
        case .empty: return "Empty"
        case .filling: return "Filling"
        case .cooling: return "Cooling"
        case .heating: return "Heating"
        case .atTargetHold: return "At Target"
        case .unknown(let value): return "Unknown (\(value))"
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case connected
}

public struct MugStatus: Equatable, Sendable {
    public var currentTempC: Double?
    public var targetTempC: Double?
    public var batteryPercent: Int?
    public var isCharging: Bool?
    public var liquidState: LiquidState?
    public var connectionState: ConnectionState
    public var lastUpdated: Date
    public var rawDiagnostics: [String: String]

    public init(
        currentTempC: Double? = nil,
        targetTempC: Double? = nil,
        batteryPercent: Int? = nil,
        isCharging: Bool? = nil,
        liquidState: LiquidState? = nil,
        connectionState: ConnectionState = .disconnected,
        lastUpdated: Date = Date(),
        rawDiagnostics: [String: String] = [:]
    ) {
        self.currentTempC = currentTempC
        self.targetTempC = targetTempC
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.liquidState = liquidState
        self.connectionState = connectionState
        self.lastUpdated = lastUpdated
        self.rawDiagnostics = rawDiagnostics
    }
}
