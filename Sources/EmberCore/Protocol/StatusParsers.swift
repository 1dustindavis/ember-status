import Foundation

public enum ParseWarning: Error, Equatable, Sendable {
    case invalidLength(field: String, expected: Int, actual: Int)
    case invalidBatteryPercent(Int)
}

public struct ParsedBattery: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool
}

public enum StatusParsers {
    public static func parseTemperatureC(from data: Data) -> Result<Double, ParseWarning> {
        guard data.count == 2 else {
            return .failure(.invalidLength(field: "temperature", expected: 2, actual: data.count))
        }

        let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
        return .success(Double(raw) / 100.0)
    }

    public static func parseBattery(from data: Data) -> Result<ParsedBattery, ParseWarning> {
        guard data.count >= 2 else {
            return .failure(.invalidLength(field: "battery", expected: 2, actual: data.count))
        }

        let percent = Int(data[0])
        guard (0...100).contains(percent) else {
            return .failure(.invalidBatteryPercent(percent))
        }

        let isCharging = data[1] != 0
        return .success(ParsedBattery(percent: percent, isCharging: isCharging))
    }

    public static func parseLiquidState(from data: Data) -> Result<LiquidState, ParseWarning> {
        guard data.count == 1 else {
            return .failure(.invalidLength(field: "liquidState", expected: 1, actual: data.count))
        }

        return .success(LiquidState(rawValue: data[0]))
    }
}

public extension ParseWarning {
    func toRecord(timestamp: Date = Date()) -> ParseWarningRecord {
        switch self {
        case .invalidLength(let field, let expected, let actual):
            return ParseWarningRecord(
                timestamp: timestamp,
                field: field,
                code: .invalidLength,
                detail: "Invalid payload length for \(field). expected=\(expected) actual=\(actual)",
                expectedLength: expected,
                actualLength: actual
            )
        case .invalidBatteryPercent(let percent):
            return ParseWarningRecord(
                timestamp: timestamp,
                field: "battery",
                code: .invalidBatteryPercent,
                detail: "Battery percent out of range: \(percent)",
                rawValue: percent
            )
        }
    }
}
