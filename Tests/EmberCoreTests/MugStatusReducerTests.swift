import XCTest
@testable import EmberCore

final class MugStatusReducerTests: XCTestCase {
    func testReducerAppliesValidEventAtomically() {
        let reducer = MugStatusReducer()
        let start = MugStatus(connectionState: .connected)
        let now = Date(timeIntervalSince1970: 123)

        let event = MugStatusReducer.Event(
            currentTempData: Data([0x10, 0x27]), // 100.00C
            targetTempData: Data([0x2C, 0x1E]), // 77.24C
            batteryData: Data([88, 0]),
            liquidStateData: Data([6]),
            timestamp: now
        )

        let next = reducer.reduce(status: start, with: event)

        XCTAssertEqual(next.currentTempC, 100.0)
        XCTAssertEqual(next.targetTempC, 77.24)
        XCTAssertEqual(next.batteryPercent, 88)
        XCTAssertEqual(next.isCharging, false)
        XCTAssertEqual(next.liquidState, .atTargetHold)
        XCTAssertEqual(next.lastUpdated, now)
    }

    func testReducerRecordsParseWarningsWithoutCrashing() {
        let reducer = MugStatusReducer()
        let start = MugStatus(connectionState: .connected)

        let event = MugStatusReducer.Event(
            currentTempData: Data([0x11]),
            batteryData: Data([200]),
            liquidStateData: Data(),
            timestamp: Date(timeIntervalSince1970: 456)
        )

        let next = reducer.reduce(status: start, with: event)

        XCTAssertNotNil(next.rawDiagnostics["currentTempParseWarning"])
        XCTAssertNotNil(next.rawDiagnostics["batteryParseWarning"])
        XCTAssertNotNil(next.rawDiagnostics["liquidStateParseWarning"])
    }

    func testReducerClearsFieldWarningAfterSuccessfulParseForSameField() {
        let reducer = MugStatusReducer()
        let start = MugStatus(connectionState: .connected)

        let withWarning = reducer.reduce(
            status: start,
            with: MugStatusReducer.Event(currentTempData: Data([0x11]), timestamp: Date(timeIntervalSince1970: 10))
        )

        XCTAssertNotNil(withWarning.rawDiagnostics["currentTempParseWarning"])

        let recovered = reducer.reduce(
            status: withWarning,
            with: MugStatusReducer.Event(currentTempData: Data([0xF4, 0x09]), timestamp: Date(timeIntervalSince1970: 11))
        )

        XCTAssertEqual(recovered.currentTempC, 25.48)
        XCTAssertNil(recovered.rawDiagnostics["currentTempParseWarning"])
    }

}
