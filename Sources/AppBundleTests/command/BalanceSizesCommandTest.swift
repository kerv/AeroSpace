@testable import AppBundle
import Common
import XCTest

@MainActor
final class BalanceSizesCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testBalanceSizesCommand() async {
        let workspace = Workspace.get(byName: name).apply { wsp in
            wsp.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 1)
                TestWindow.new(id: 2, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 2)
                TestWindow.new(id: 3, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 3)
            }
        }

        await parseCommand("balance-sizes").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(name), .emptyStdin)

        for window in workspace.rootTilingContainer.children {
            assertEquals(window.getWeight(workspace.rootTilingContainer.orientation), 2)
        }
    }

    func testBalanceThenResizePreservesTotalWeight() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 2)
        let second = TestWindow.new(id: 2, parent: root, adaptiveWeight: 4)
        let third = TestWindow.new(id: 3, parent: root, adaptiveWeight: 6)
        _ = first.focusWindow()
        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("resize width 6").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(first.hWeight, 6)
        assertEquals(second.hWeight, 3)
        assertEquals(third.hWeight, 3)
    }
}
