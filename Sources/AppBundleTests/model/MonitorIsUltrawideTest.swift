@testable import AppBundle
import Common
import XCTest

final class MonitorIsUltrawideTest: XCTestCase {
    func testIsUltrawide_ultrawide() {
        // 2560x1080 → ratio 2.37 > 2.1 → true
        XCTAssertTrue(FakeMonitor(width: 2560, height: 1080).isUltrawide)
    }

    func testIsUltrawide_widebutNotUltrawide() {
        // 2560x1440 → ratio 1.78 → false
        XCTAssertFalse(FakeMonitor(width: 2560, height: 1440).isUltrawide)
    }

    func testIsUltrawide_thresholdJustBelow() {
        // width = 2.1 * height - 1 → just below threshold → false
        XCTAssertFalse(FakeMonitor(width: 2.1 * 1080 - 1, height: 1080).isUltrawide)
    }
}
