import Foundation

public enum ProtocolCompatibilityMode: String, Equatable, Sendable {
    case strict
    case permissive
}

public enum ParseWarningCode: String, Equatable, Sendable {
    case invalidLength
    case invalidBatteryPercent
}

public struct ParseWarningRecord: Equatable, Sendable {
    public let timestamp: Date
    public let field: String
    public let code: ParseWarningCode
    public let detail: String
    public let expectedLength: Int?
    public let actualLength: Int?
    public let rawValue: Int?

    public init(
        timestamp: Date = Date(),
        field: String,
        code: ParseWarningCode,
        detail: String,
        expectedLength: Int? = nil,
        actualLength: Int? = nil,
        rawValue: Int? = nil
    ) {
        self.timestamp = timestamp
        self.field = field
        self.code = code
        self.detail = detail
        self.expectedLength = expectedLength
        self.actualLength = actualLength
        self.rawValue = rawValue
    }
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
    public var parseWarnings: [ParseWarningRecord]
    public var connectionEvents: [ConnectionEventRecord]

    public init(
        discoveredReadableCharacteristics: [String] = [],
        discoveredNotificationCharacteristics: [String] = [],
        parseWarnings: [ParseWarningRecord] = [],
        connectionEvents: [ConnectionEventRecord] = []
    ) {
        self.discoveredReadableCharacteristics = discoveredReadableCharacteristics
        self.discoveredNotificationCharacteristics = discoveredNotificationCharacteristics
        self.parseWarnings = parseWarnings
        self.connectionEvents = connectionEvents
    }
}
