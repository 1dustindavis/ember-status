import Foundation
import XCTest
@testable import EmberCore

struct HardwareCaptureFixture: Decodable {
    struct CharacteristicPayloads: Decodable {
        let currentTemp: String
        let targetTemp: String
        let battery: String
        let liquidState: String
    }

    struct ExpectedStatus: Decodable {
        let currentTempC: Double
        let targetTempC: Double
        let batteryPercent: Int
        let isCharging: Bool
        let liquidStateRaw: UInt8
    }

    let captureID: String
    let notes: String
    let characteristics: CharacteristicPayloads
    let expected: ExpectedStatus

    var event: MugStatusReducer.Event {
        MugStatusReducer.Event(
            currentTempData: Data(hex: characteristics.currentTemp),
            targetTempData: Data(hex: characteristics.targetTemp),
            batteryData: Data(hex: characteristics.battery),
            liquidStateData: Data(hex: characteristics.liquidState)
        )
    }

    var expectedLiquidState: LiquidState {
        LiquidState(rawValue: expected.liquidStateRaw)
    }

    var readMap: [BLECharacteristicID: Data] {
        [
            EmberCharacteristic.currentTemp: Data(hex: characteristics.currentTemp),
            EmberCharacteristic.targetTemp: Data(hex: characteristics.targetTemp),
            EmberCharacteristic.battery: Data(hex: characteristics.battery),
            EmberCharacteristic.liquidState: Data(hex: characteristics.liquidState)
        ]
    }
}

enum HardwareFixtureLoader {
    static func loadAll(file: StaticString = #filePath, line: UInt = #line) throws -> [HardwareCaptureFixture] {
        guard let url = Bundle.module.url(forResource: "hardware-regression-fixtures", withExtension: "json") else {
            XCTFail("Missing hardware-regression-fixtures.json in test resources. file=\(file) line=\(line)")
            return []
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([HardwareCaptureFixture].self, from: data)
    }
}

private extension Data {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(cleaned.count % 2 == 0, "Hex payload must have an even number of characters.")

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let chunk = cleaned[index..<next]
            guard let value = UInt8(chunk, radix: 16) else {
                preconditionFailure("Invalid hex byte '\(chunk)'.")
            }
            bytes.append(value)
            index = next
        }

        self = Data(bytes)
    }
}
