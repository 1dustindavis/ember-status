import Foundation
import XCTest

final class ReadOnlyGuardrailTests: XCTestCase {
    func testEmberCoreContainsNoCharacteristicWriteAPIUsage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EmberCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        let emberCorePath = repositoryRoot.appendingPathComponent("Sources/EmberCore").path
        let enumerator = FileManager.default.enumerator(atPath: emberCorePath)

        var swiftFiles: [String] = []
        while let file = enumerator?.nextObject() as? String {
            if file.hasSuffix(".swift") {
                swiftFiles.append(file)
            }
        }

        XCTAssertFalse(swiftFiles.isEmpty)

        for relativeFile in swiftFiles {
            let path = URL(fileURLWithPath: emberCorePath).appendingPathComponent(relativeFile).path
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertFalse(contents.contains("writeValue("), "Write API found in \(relativeFile)")
            XCTAssertFalse(contents.contains("setTargetTemp"), "Write-oriented helper found in \(relativeFile)")
        }
    }
}
