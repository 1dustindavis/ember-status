import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

public struct EmberMugActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var liquidState: String
        public var currentTempC: Double?
        public var batteryPercent: Int?
        public var isCharging: Bool?
        public var secondsSinceLastUpdate: Int
        public var lastUpdatedAt: Date

        public init(
            liquidState: String,
            currentTempC: Double?,
            batteryPercent: Int?,
            isCharging: Bool?,
            secondsSinceLastUpdate: Int,
            lastUpdatedAt: Date
        ) {
            self.liquidState = liquidState
            self.currentTempC = currentTempC
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
            self.secondsSinceLastUpdate = secondsSinceLastUpdate
            self.lastUpdatedAt = lastUpdatedAt
        }
    }

    public var mugName: String

    public init(mugName: String) {
        self.mugName = mugName
    }
}
#endif
