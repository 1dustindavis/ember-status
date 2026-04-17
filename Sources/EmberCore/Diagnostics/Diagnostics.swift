import Foundation

public enum ProtocolCompatibilityMode: String, Equatable, Sendable {
    case strict
    case permissive
}

public struct ConnectionEventRecord: Equatable, Sendable {
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date = Date(), message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

public struct MugDiagnostics: Equatable, Sendable {
    public var discoveredReadableCharacteristics: [String]
    public var discoveredNotificationCharacteristics: [String]
    public var parseWarnings: [String]
    public var connectionEvents: [ConnectionEventRecord]

    public init(
        discoveredReadableCharacteristics: [String] = [],
        discoveredNotificationCharacteristics: [String] = [],
        parseWarnings: [String] = [],
        connectionEvents: [ConnectionEventRecord] = []
    ) {
        self.discoveredReadableCharacteristics = discoveredReadableCharacteristics
        self.discoveredNotificationCharacteristics = discoveredNotificationCharacteristics
        self.parseWarnings = parseWarnings
        self.connectionEvents = connectionEvents
    }
}

public struct HardwareCaptureCharacteristics: Codable, Equatable, Sendable {
    public let currentTemp: String
    public let targetTemp: String
    public let battery: String
    public let liquidState: String

    public init(currentTemp: String, targetTemp: String, battery: String, liquidState: String) {
        self.currentTemp = currentTemp
        self.targetTemp = targetTemp
        self.battery = battery
        self.liquidState = liquidState
    }
}

public struct HardwareCaptureExpected: Codable, Equatable, Sendable {
    public let currentTempC: Double
    public let targetTempC: Double
    public let batteryPercent: Int
    public let isCharging: Bool
    public let liquidStateRaw: UInt8

    public init(currentTempC: Double, targetTempC: Double, batteryPercent: Int, isCharging: Bool, liquidStateRaw: UInt8) {
        self.currentTempC = currentTempC
        self.targetTempC = targetTempC
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.liquidStateRaw = liquidStateRaw
    }
}

public struct HardwareRegressionCapture: Codable, Equatable, Sendable {
    public let captureID: String
    public let notes: String
    public let characteristics: HardwareCaptureCharacteristics
    public let expected: HardwareCaptureExpected

    public init(
        captureID: String,
        notes: String,
        characteristics: HardwareCaptureCharacteristics,
        expected: HardwareCaptureExpected
    ) {
        self.captureID = captureID
        self.notes = notes
        self.characteristics = characteristics
        self.expected = expected
    }
}
