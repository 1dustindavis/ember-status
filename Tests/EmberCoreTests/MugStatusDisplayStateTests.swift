import XCTest
@testable import EmberCore

final class LiquidStateDisplayNameTests: XCTestCase {
    func testDisplayNameForKnownStates() {
        XCTAssertEqual(LiquidState.empty.displayName, "Empty")
        XCTAssertEqual(LiquidState.filling.displayName, "Filling")
        XCTAssertEqual(LiquidState.cooling.displayName, "Cooling")
        XCTAssertEqual(LiquidState.heating.displayName, "Heating")
        XCTAssertEqual(LiquidState.atTargetHold.displayName, "At Target")
    }

    func testDisplayNameForUnknownState() {
        XCTAssertEqual(LiquidState.unknown(200).displayName, "Unknown (200)")
    }
}
