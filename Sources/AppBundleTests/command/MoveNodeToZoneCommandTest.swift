@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToZoneCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("move-node-to-zone left", MoveNodeToZoneCmdArgs(rawArgs: [], "left"))
        testParseSingleCommandSucc("move-node-to-zone center", MoveNodeToZoneCmdArgs(rawArgs: [], "center"))
        testParseSingleCommandSucc("move-node-to-zone right", MoveNodeToZoneCmdArgs(rawArgs: [], "right"))
        // Any zone name is accepted at parse time; validation against active zones happens at run time.
        testParseSingleCommandSucc("move-node-to-zone foo", MoveNodeToZoneCmdArgs(rawArgs: [], "foo"))
        XCTAssertNotNil(parseCommand("move-node-to-zone").errorOrNil)
    }

    func testMoveToZone_basic() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let center = workspace.zoneContainers["center"]!
        let window = TestWindow.new(id: 1, parent: center)
        _ = window.focusWindow()
        assertEquals(workspace.focusWorkspace(), true)

        try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "left")).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(window.parent === left, "Window should be in left zone")
    }

    func testMovingFloatingWindowIntoZoneClearsFloatingMemory() async throws {
        let previousMemory = FloatingMemory.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FloatingMemory.shared = FloatingMemory(storageURL: url)
        defer { FloatingMemory.shared = previousMemory; try? FileManager.default.removeItem(at: url) }
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 4242, parent: workspace.floatingWindowsContainer)
        FloatingMemory.shared.remember(windowId: window.windowId)
        XCTAssertTrue(window.focusWindow())

        let result = await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "left")).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertTrue(workspace.zoneContaining(window)?.name == "left")
        XCTAssertFalse(FloatingMemory.shared.isRemembered(windowId: window.windowId))
    }

    func testMoveToZone_noZones() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        _ = window.focusWindow()
        assertEquals(workspace.focusWorkspace(), true)

        let io = CmdIoImpl(stdin: .emptyStdin)
        let result = try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "center")).run(.defaultEnv, io)

        XCTAssertEqual(result, .fail, "Should fail when zones not active")
        XCTAssertTrue(io.stderr.joined().contains("zones not active"), "Should report error to stderr")
    }

    func testMoveToZone_respectsInsertionPolicy() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let existing = TestWindow.new(id: 1, parent: nested)
        let moved = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"]!)
        _ = existing.focusWindow()
        _ = moved.focusWindow()

        try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "left")).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(moved.parent === nested, "Manual move should use the destination zone's insertion policy")
        XCTAssertEqual(moved.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testMoveToSameZone_afterFocused_doesNotCrashOnLastChild() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let existing = TestWindow.new(id: 1, parent: nested)
        let moved = TestWindow.new(id: 2, parent: nested)
        _ = existing.focusWindow()
        _ = moved.focusWindow()

        try await MoveNodeToZoneCommand(args: MoveNodeToZoneCmdArgs(rawArgs: [], "left")).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(moved.parent === nested, "Moving into the current zone should keep the window in the same insertion parent")
        XCTAssertEqual(moved.ownIndex, 1, "Reapplying after-focused placement in the same parent should not shift the last child out of range")
    }
}
