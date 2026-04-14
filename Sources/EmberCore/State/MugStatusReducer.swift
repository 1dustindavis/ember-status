import Foundation

public struct MugStatusReducer {
    public struct Event: Sendable {
        public var currentTempData: Data?
        public var targetTempData: Data?
        public var batteryData: Data?
        public var liquidStateData: Data?
        public var timestamp: Date

        public init(
            currentTempData: Data? = nil,
            targetTempData: Data? = nil,
            batteryData: Data? = nil,
            liquidStateData: Data? = nil,
            timestamp: Date = Date()
        ) {
            self.currentTempData = currentTempData
            self.targetTempData = targetTempData
            self.batteryData = batteryData
            self.liquidStateData = liquidStateData
            self.timestamp = timestamp
        }
    }

    public init() {}

    public func reduce(status: MugStatus, with event: Event) -> MugStatus {
        var next = status
        next.lastUpdated = event.timestamp

        if let currentTempData = event.currentTempData {
            switch StatusParsers.parseTemperatureC(from: currentTempData) {
            case .success(let value):
                next.currentTempC = value
            case .failure(let warning):
                next.rawDiagnostics["currentTempParseWarning"] = String(describing: warning)
            }
        }

        if let targetTempData = event.targetTempData {
            switch StatusParsers.parseTemperatureC(from: targetTempData) {
            case .success(let value):
                next.targetTempC = value
            case .failure(let warning):
                next.rawDiagnostics["targetTempParseWarning"] = String(describing: warning)
            }
        }

        if let batteryData = event.batteryData {
            switch StatusParsers.parseBattery(from: batteryData) {
            case .success(let value):
                next.batteryPercent = value.percent
                next.isCharging = value.isCharging
            case .failure(let warning):
                next.rawDiagnostics["batteryParseWarning"] = String(describing: warning)
            }
        }

        if let liquidStateData = event.liquidStateData {
            switch StatusParsers.parseLiquidState(from: liquidStateData) {
            case .success(let value):
                next.liquidState = value
            case .failure(let warning):
                next.rawDiagnostics["liquidStateParseWarning"] = String(describing: warning)
            }
        }

        return next
    }
}
