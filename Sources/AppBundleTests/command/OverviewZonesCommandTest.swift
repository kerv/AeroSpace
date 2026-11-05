@testable import AppBundle
import Common
import XCTest

@MainActor
final class OverviewZonesCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseOverviewZonesCommand() {
        testParseSingleCommandSucc("overview-zones", OverviewZonesCmdArgs(rawArgs: []))
    }

    func testOverviewSnapshot_returnsNilWithoutZones() {
        XCTAssertNil(overviewZonesSnapshot(in: focus.workspace))
    }

    func testOverviewSnapshot_includesPresetPresentationAndWeightFractions() {
        let workspace = focus.workspace
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.2, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.5, layout: .accordion),
            ZoneDefinition(id: "right", width: 0.3, layout: .stack),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        workspace.focusedZone = "right"
        workspace.presentationModeSnapshot = Workspace.PresentationModeSnapshot(
            zoneDefinitions: workspace.currentLiveZoneDefinitions(),
            windowZoneAssignments: [:],
            zoneWindowOrder: [:],
            focusedZone: nil,
            savedZoneWeights: nil,
            focusModeZone: nil,
            previousActiveZonePresetName: "balanced"
        )

        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        let focused = TestWindow.new(id: 1, parent: center)
        _ = TestWindow.new(id: 2, parent: left)
        XCTAssertTrue(focused.focusWindow())

        let snapshot = overviewZonesSnapshot(in: workspace).orDie()
        XCTAssertEqual(snapshot.workspaceName, workspace.name)
        XCTAssertEqual(snapshot.presetName, "balanced")
        XCTAssertTrue(snapshot.isPresentationMode)
        XCTAssertEqual(snapshot.zones.map(\.zoneId), ["left", "center", "right"])
        XCTAssertEqual(snapshot.zones.map(\.windowCount), [1, 1, 0])
        XCTAssertEqual(snapshot.zones.map(\.isFocused), [false, true, false])
        XCTAssertEqual(snapshot.zones.map(\.isHinted), [false, false, true])
        XCTAssertEqual(snapshot.zones.map(\.layout), ["h_tiles", "h_accordion", "stack"])
        XCTAssertEqual(snapshot.zones.map(\.widthFraction).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertNotNil(snapshot.zones[0].summary)
        XCTAssertEqual(snapshot.zones[2].layoutTargetWindowId, nil)
    }

    func testNextOverviewLayoutDescription_cyclesExpectedSequence() {
        XCTAssertEqual(nextLayoutDescription(for: "h_tiles"), "h_accordion")
        XCTAssertEqual(nextLayoutDescription(for: "v_tiles"), "v_accordion")
        XCTAssertEqual(nextLayoutDescription(for: "h_accordion"), "stack")
        XCTAssertEqual(nextLayoutDescription(for: "v_accordion"), "stack")
        XCTAssertEqual(nextLayoutDescription(for: "stack"), "tiles")
    }

    func testOverviewZonesFailsWithoutZones() async throws {
        let result = try await OverviewZonesCommand(args: OverviewZonesCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, BinaryExitCode.fail.rawValue)
        XCTAssertEqual(result.stderr, ["overview-zones: zones not active on this workspace"])
    }
    func testOverviewIdentifiesFloatingWindowAndItsZone() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 10, parent: workspace.floatingWindowsContainer)
        XCTAssertTrue(window.focusWindow())
        let snapshot = overviewZonesSnapshot(in: workspace, floatingZoneName: "right")!
        XCTAssertTrue(snapshot.focusedWindowIsFloating)
        XCTAssertEqual(snapshot.zones.map(\.isFocused), [false, false, true])
        let noMatch = overviewZonesSnapshot(in: workspace)!
        XCTAssertFalse(noMatch.zones.contains(where: \.isFocused))
    }

}
