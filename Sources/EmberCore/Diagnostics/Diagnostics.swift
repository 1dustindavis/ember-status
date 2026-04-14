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
