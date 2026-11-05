@testable import AppBundle
import Common
import XCTest

@MainActor
final class PresentationModeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParsePresentationModeCommand() {
        testParseSingleCommandSucc("presentation-mode on", PresentationModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.on)))
        testParseSingleCommandSucc("presentation-mode off", PresentationModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.off)))
        testParseSingleCommandSucc("presentation-mode toggle", PresentationModeCmdArgs(rawArgs: []).copy(\.action, .initialized(.toggle)))
        testParseCommandFail(
            "presentation-mode",
            msg: "ERROR: Argument '(on|off|toggle)' is mandatory",
            exitCode: 2
        )
    }

    func testPresentationModeZoneDefinitions_useCentered16By9MainZone() {
        let defs = presentationModeZoneDefinitions(for: FakeMonitor(width: 5120, height: 1440))
        XCTAssertEqual(defs.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(defs.map(\.layout), [.stack, .tiles, .stack])
        XCTAssertEqual(defs[0].width, 0.25, accuracy: 0.0001)
        XCTAssertEqual(defs[1].width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(defs[2].width, 0.25, accuracy: 0.0001)
    }

    func testPresentationModeOnOff_reconfiguresWorkspaceAndRestoresPreviousZones() {
        let workspace = focus.workspace
        config.zones.zones = [
            ZoneDefinition(id: "chat", width: 0.2, layout: .tiles),
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "tools", width: 0.2, layout: .accordion),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let left = TestWindow.new(id: 1, parent: workspace.zoneContainers["chat"].orDie())
        let main = TestWindow.new(id: 2, parent: workspace.zoneContainers["main"].orDie())
        let right = TestWindow.new(id: 3, parent: workspace.zoneContainers["tools"].orDie())
        XCTAssertTrue(main.focusWindow())
        let io = CmdIoImpl(stdin: .emptyStdin)

        let onResult = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        XCTAssertEqual(onResult.rawValue, 0)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(workspace.zoneContainers["left"]?.layout, .stack)
        XCTAssertEqual(workspace.zoneContainers["center"]?.layout, .tiles)
        XCTAssertEqual(workspace.zoneContainers["right"]?.layout, .stack)
        XCTAssertEqual(workspace.zoneContaining(main)?.name, "center")
        XCTAssertEqual(workspace.zoneContaining(left)?.name, "left")
        XCTAssertEqual(workspace.zoneContaining(right)?.name, "right")
        XCTAssertNotNil(workspace.presentationModeSnapshot)

        let offResult = disablePresentationMode(on: workspace, io)
        XCTAssertEqual(offResult.rawValue, 0)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["chat", "main", "tools"])
        XCTAssertEqual(workspace.zoneContaining(left)?.name, "chat")
        XCTAssertEqual(workspace.zoneContaining(main)?.name, "main")
        XCTAssertEqual(workspace.zoneContaining(right)?.name, "tools")
        XCTAssertNil(workspace.presentationModeSnapshot)
    }

    func testPresentationMode_updatesAndRestoresActivePresetName() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        let io = CmdIoImpl(stdin: .emptyStdin)

        _ = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        XCTAssertEqual(activeZonePresetName, "presentation")

        _ = disablePresentationMode(on: workspace, io)
        XCTAssertEqual(activeZonePresetName, "balanced")
    }

    func testPresentationMode_forceRebuildKeepsPresentationActive() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let io = CmdIoImpl(stdin: .emptyStdin)

        _ = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)

        XCTAssertNotNil(workspace.presentationModeSnapshot)
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(activeZonePresetName, "presentation")
    }

    func testPresentationMode_restorePreservesPerZoneLeafOrder() {
        let workspace = focus.workspace
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.34, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.33, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.33, layout: .tiles),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = workspace.zoneContainers["center"].orDie()
        let first = TestWindow.new(id: 1, parent: center)
        let second = TestWindow.new(id: 2, parent: center)
        let third = TestWindow.new(id: 3, parent: center)
        XCTAssertTrue(second.focusWindow())
        let io = CmdIoImpl(stdin: .emptyStdin)

        _ = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        _ = disablePresentationMode(on: workspace, io)

        let restored = workspace.zoneContainers["center"].orDie().allLeafWindowsRecursive.map(\.windowId)
        XCTAssertEqual(restored, [first.windowId, second.windowId, third.windowId])
    }

    func testPresentationModeDoesNotOverwriteZoneMemory() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let leftWindow = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        let profile = MonitorProfile([FakeMonitor.ultrawide])
        ZoneMemory.shared.rememberZone("left", for: leftWindow, profile: profile)
        let io = CmdIoImpl(stdin: .emptyStdin)

        _ = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: leftWindow, profile: profile), "left")

        _ = disablePresentationMode(on: workspace, io)
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: leftWindow, profile: profile), "left")
    }

    func testPresentationMode_disconnectClearsSnapshotAndRestoresPresetName() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        activeZonePresetName = "balanced"
        let io = CmdIoImpl(stdin: .emptyStdin)

        _ = enablePresentationMode(on: workspace, monitor: FakeMonitor(width: 5120, height: 1440), io)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertNil(workspace.presentationModeSnapshot)
        XCTAssertEqual(activeZonePresetName, "balanced")
    }
}
