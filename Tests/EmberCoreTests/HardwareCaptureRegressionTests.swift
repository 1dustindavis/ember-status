import XCTest
@testable import EmberCore

final class HardwareCaptureRegressionTests: XCTestCase {
    func testRealHardwareCaptureFixturesDecodeWithoutWarnings() throws {
        let fixtures = try HardwareFixtureLoader.loadAll()

        for fixture in fixtures {
            let event = fixture.event

            XCTAssertEqual(
                try StatusParsers.parseTemperatureC(from: XCTUnwrap(event.currentTempData)).get(),
                fixture.expected.currentTempC,
                accuracy: 0.01,
                "capture=\(fixture.captureID)"
            )
            XCTAssertEqual(
                try StatusParsers.parseTemperatureC(from: XCTUnwrap(event.targetTempData)).get(),
                fixture.expected.targetTempC,
                accuracy: 0.01,
                "capture=\(fixture.captureID)"
            )

            let battery = try StatusParsers.parseBattery(from: XCTUnwrap(event.batteryData)).get()
            XCTAssertEqual(battery.percent, fixture.expected.batteryPercent, "capture=\(fixture.captureID)")
            XCTAssertEqual(battery.isCharging, fixture.expected.isCharging, "capture=\(fixture.captureID)")

            let liquid = try StatusParsers.parseLiquidState(from: XCTUnwrap(event.liquidStateData)).get()
            XCTAssertEqual(liquid, fixture.expectedLiquidState, "capture=\(fixture.captureID)")
        }
    }

    func testReducerMatchesExpectedStatusForEachHardwareCaptureFixture() throws {
        let reducer = MugStatusReducer()
        let fixtures = try HardwareFixtureLoader.loadAll()

        for fixture in fixtures {
            let reduced = reducer.reduce(status: MugStatus(connectionState: .connected), with: fixture.event)
            let currentTemp = try XCTUnwrap(reduced.currentTempC, "capture=\(fixture.captureID)")
            let targetTemp = try XCTUnwrap(reduced.targetTempC, "capture=\(fixture.captureID)")

            XCTAssertEqual(currentTemp, fixture.expected.currentTempC, accuracy: 0.01, "capture=\(fixture.captureID)")
            XCTAssertEqual(targetTemp, fixture.expected.targetTempC, accuracy: 0.01, "capture=\(fixture.captureID)")
            XCTAssertEqual(reduced.batteryPercent, fixture.expected.batteryPercent, "capture=\(fixture.captureID)")
            XCTAssertEqual(reduced.isCharging, fixture.expected.isCharging, "capture=\(fixture.captureID)")
            XCTAssertEqual(reduced.liquidState, fixture.expectedLiquidState, "capture=\(fixture.captureID)")
            XCTAssertTrue(reduced.rawDiagnostics.isEmpty, "capture=\(fixture.captureID)")
        }
    }
}
