@testable import AppBundle
import Foundation
import XCTest

@MainActor final class FloatingMemoryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFloatingChoiceSurvivesCloseAndAppRestartUntilExplicitlyTiled() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FloatingMemory(storageURL: url)
        let workspace = focus.workspace
        let first = TestWindow.new(id: 301, parent: workspace.floatingWindowsContainer)
        first.placementIdentityTitle = "Initial title"
        store.remember(first)
        store.forgetLiveId(windowId: first.windowId)
        first.unbindFromParent()

        let reopened = TestWindow.new(id: 302, parent: workspace.rootTilingContainer)
        reopened.placementIdentityTitle = "Changed title"
        let reloaded = FloatingMemory(storageURL: url)
        XCTAssertTrue(reloaded.restore(reopened, appWindowCount: 1))
        XCTAssertTrue(reloaded.isRemembered(windowId: reopened.windowId))
        reloaded.forget(reopened)
        XCTAssertFalse(FloatingMemory(storageURL: url).restore(reopened, appWindowCount: 1))
    }

    func testAmbiguousAppWindowsAreNotGuessed() {
        let store = FloatingMemory(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let workspace = focus.workspace
        let first = TestWindow.new(id: 311, parent: workspace.floatingWindowsContainer)
        let second = TestWindow.new(id: 312, parent: workspace.floatingWindowsContainer)
        first.placementIdentityTitle = "First"
        second.placementIdentityTitle = "Second"
        store.remember(first)
        store.remember(second)
        store.forgetLiveId(windowId: first.windowId)
        store.forgetLiveId(windowId: second.windowId)
        let unknown = TestWindow.new(id: 313, parent: workspace.rootTilingContainer)
        unknown.placementIdentityTitle = "Different"
        XCTAssertFalse(store.restore(unknown, appWindowCount: 2))
        unknown.placementIdentityTitle = "First"
        XCTAssertTrue(store.restore(unknown, appWindowCount: 2))
    }

    func testLegacyWindowIdIsUpgradedWithoutLosingPreference() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[321]".utf8).write(to: url)
        let window = TestWindow.new(id: 321, parent: focus.workspace.rootTilingContainer)
        window.placementIdentityTitle = "Existing"
        let memory = FloatingMemory(storageURL: url)
        XCTAssertTrue(memory.restore(window, appWindowCount: 1))
        memory.forgetLiveId(windowId: 321)
        let replacement = TestWindow.new(id: 322, parent: focus.workspace.rootTilingContainer)
        replacement.placementIdentityTitle = "Existing"
        XCTAssertTrue(FloatingMemory(storageURL: url).restore(replacement, appWindowCount: 1))
    }

    func testNativeFullscreenExitKeepsRememberedWindowFloating() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 331, parent: workspace.macOsNativeFullscreenWindowsContainer)
        FloatingMemory.shared.remember(window)
        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: .tilingContainer,
                                                      workspace: workspace, .nonCancellable)
        XCTAssertTrue(window.isFloating)
    }

    func testReopenedWindowFloatsUntilExplicitToggle() async {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 341, parent: workspace.floatingWindowsContainer)
        first.placementIdentityTitle = "A window"
        FloatingMemory.shared.remember(first)
        FloatingMemory.shared.forgetLiveId(windowId: first.windowId)
        first.unbindFromParent()
        let reopened = TestWindow.new(id: 342, parent: workspace.rootTilingContainer)
        reopened.placementIdentityTitle = "A window"
        applyRuntimePlacementDefaults(reopened)
        XCTAssertTrue(reopened.isFloating)
        XCTAssertTrue(reopened.focusWindow())
        let result = await parseCommand("layout floating tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode.rawValue, 0)
        XCTAssertFalse(reopened.isFloating)
        applyRuntimePlacementDefaults(reopened)
        XCTAssertFalse(reopened.isFloating)
    }
}
