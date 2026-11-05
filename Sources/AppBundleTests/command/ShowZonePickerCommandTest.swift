@testable import AppBundle
import Common
import XCTest

@MainActor
final class ShowZonePickerCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseShowZonePickerCommand() {
        testParseSingleCommandSucc("show-zone-picker", ShowZonePickerCmdArgs(rawArgs: []))
    }

    func testZonePickerSnapshot_returnsNilWithoutZones() {
        XCTAssertNil(zonePickerSnapshot(in: focus.workspace))
    }

    func testZonePickerSnapshot_includesPresetAndFocusedZoneState() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        _ = TestWindow.new(id: 1, parent: left)
        let focused = TestWindow.new(id: 2, parent: center)
        XCTAssertTrue(focused.focusWindow())

        let snapshot = zonePickerSnapshot(in: workspace).orDie()
        XCTAssertEqual(snapshot.workspaceName, workspace.name)
        XCTAssertEqual(snapshot.monitorName, workspace.workspaceMonitor.name)
        XCTAssertEqual(snapshot.presetName, "balanced")
        XCTAssertFalse(snapshot.isPresentationMode)
        XCTAssertEqual(snapshot.zones.map(\.zoneId), ["left", "center", "right"])
        XCTAssertEqual(snapshot.zones.map(\.windowCount), [1, 1, 0])
        XCTAssertEqual(snapshot.zones.map(\.isFocused), [false, true, false])
    }

    func testZonePickerSnapshot_marksPresentationModeAndHintedZone() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.focusedZone = "right"
        activeZonePresetName = "presentation"
        workspace.presentationModeSnapshot = Workspace.PresentationModeSnapshot(
            zoneDefinitions: workspace.currentLiveZoneDefinitions(),
            windowZoneAssignments: [:],
            zoneWindowOrder: [:],
            focusedZone: nil,
            savedZoneWeights: nil,
            focusModeZone: nil,
            previousActiveZonePresetName: "balanced"
        )

        let snapshot = zonePickerSnapshot(in: workspace).orDie()
        XCTAssertTrue(snapshot.isPresentationMode)
        XCTAssertEqual(snapshot.zones.map(\.isHinted), [false, false, true])
    }

    func testShowZonePickerFailsWithoutZones() async throws {
        let result = try await ShowZonePickerCommand(args: ShowZonePickerCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, BinaryExitCode.fail.rawValue)
        XCTAssertEqual(result.stderr, ["show-zone-picker: zones not active on this workspace"])
    }
}
