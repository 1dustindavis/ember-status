import XCTest
@testable import EmberCore

final class StatusParsersTests: XCTestCase {
    func testTemperatureParserParsesLittleEndianCentiDegrees() {
        let data = Data([0xF4, 0x09]) // 2548 => 25.48C
        let result = StatusParsers.parseTemperatureC(from: data)

        XCTAssertEqual(try? result.get(), 25.48)
    }

    func testTemperatureParserRejectsShortPayload() {
        let data = Data([0xF4])
        let result = StatusParsers.parseTemperatureC(from: data)

        XCTAssertEqual(result, .failure(.invalidLength(field: "temperature", expected: 2, actual: 1)))
    }

    func testBatteryParserParsesPercentAndChargingFlag() {
        let data = Data([72, 1])
        let result = StatusParsers.parseBattery(from: data)

        XCTAssertEqual(try? result.get(), ParsedBattery(percent: 72, isCharging: true))
    }

    func testBatteryParserRejectsOutOfRangePercent() {
        let data = Data([255, 0])
        let result = StatusParsers.parseBattery(from: data)

        XCTAssertEqual(result, .failure(.invalidBatteryPercent(255)))
    }

    func testLiquidStateParserHandlesUnknownValuesSafely() {
        let data = Data([200])
        let result = StatusParsers.parseLiquidState(from: data)

        XCTAssertEqual(try? result.get(), .unknown(200))
    }

    func testLiquidStateParserTreatsOneAsEmptyIdle() {
        let data = Data([1])
        let result = StatusParsers.parseLiquidState(from: data)

        XCTAssertEqual(try? result.get(), .empty)
    }

    func testLiquidStateParserMapsKnownShiftedStates() {
        XCTAssertEqual(try? StatusParsers.parseLiquidState(from: Data([2])).get(), .filling)
        XCTAssertEqual(try? StatusParsers.parseLiquidState(from: Data([3])).get(), .cooling)
        XCTAssertEqual(try? StatusParsers.parseLiquidState(from: Data([4])).get(), .heating)
    }
}
