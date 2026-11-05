@testable import AppBundle
import XCTest

@MainActor final class ZonePortConfigTest: XCTestCase {
    func testZoneWidthsAndLegacyAccordionPadding() {
        let result = parseConfig("""
        config-version = 2
        accordion-padding = 22
        [zones]
        widths = [0.25, 0.5, 0.25]
        gap = 8
        """)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.config.accordion.padding, 22)
        XCTAssertEqual(result.config.zones.zones.map(\.width), [0.25, 0.5, 0.25])
        XCTAssertEqual(result.config.zones.gap, 8)
    }

    func testInvalidZoneWidthsAreRejected() {
        let result = parseConfig("""
        [zones]
        widths = [0.1, 0.2]
        """)
        XCTAssertFalse(result.errors.isEmpty)
    }
    func testZoneResizeAndOverviewBindingsParse() {
        let result = parseConfig("""
        config-version = 2
        [mode.main.binding]
        alt-space = 'overview-zones'
        alt-ctrl-minus = 'resize --zone width -50'
        alt-ctrl-equal = 'resize --zone width +50'
        """)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
    }

}
