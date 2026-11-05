@testable import AppBundle
import Common
import XCTest

@MainActor
final class FlattenWorkspaceTreeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSimple() async {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
            TestWindow.new(id: 3, parent: $0.floatingWindowsContainer) // floating
        }
        assertEquals(workspace.focusWorkspace(), true)

        await parseCommand("flatten-workspace-tree").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.layoutDescription, .workspace([.h_tiles([.window(1), .window(2)]), .floatingWindowsContainer([.window(3)])]))
    }

    func testFlattenClearsZoneContainers() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        TestWindow.new(id: 1, parent: workspace.zoneContainers["left"]!)
        TestWindow.new(id: 2, parent: workspace.zoneContainers["center"]!)
        assertEquals(workspace.focusWorkspace(), true)

        try await FlattenWorkspaceTreeCommand(args: FlattenWorkspaceTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(workspace.zoneContainers.isEmpty, "zoneContainers must be cleared after flatten")
        // Zone containers must be removed from tree — rootTilingContainer holds only windows
        XCTAssertFalse(workspace.rootTilingContainer.children.contains { $0 is TilingContainer },
                       "No zone TilingContainers should remain in rootTilingContainer")
        // ensureZoneContainers starts fresh — no stale zone refs
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.zoneContainers.count, 3)
        XCTAssertEqual(workspace.rootTilingContainer.children.count(where: { $0 is TilingContainer }), 3)
    }
}
