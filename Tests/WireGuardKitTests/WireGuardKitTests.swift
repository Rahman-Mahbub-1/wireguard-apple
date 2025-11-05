import XCTest
@testable import WireGuardKit

final class WireGuardKitTests: XCTestCase {
    func testExample() throws {
        // This test will fail to compile if the Go library isn't properly linked
        let adapter = WireGuardAdapter()
        XCTAssertNotNil(adapter)
    }
}