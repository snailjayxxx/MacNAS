import XCTest
@testable import MacNASCore
final class SmokeTests: XCTestCase { func testMinimumOSGate() { XCTAssertEqual(MockCapabilityProbe(osMajor: 14).inspect().first?.state, .unavailable) } }
