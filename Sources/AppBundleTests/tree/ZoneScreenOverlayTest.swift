@testable import AppBundle
import XCTest

@MainActor final class ZoneScreenOverlayTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOverlayUsesZoneGeometryAndHighlightsFocusedZone() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"]!)
        XCTAssertTrue(window.focusWindow())
        let items = zoneOverlayItems(in: workspace)
        XCTAssertEqual(items.map(\.id), ["left", "center", "right"])
        XCTAssertEqual(items.map(\.isActive), [false, true, false])
        XCTAssertEqual(items.reduce(0) { $0 + $1.rect.width }, workspace.workspaceMonitor.visibleRect.width, accuracy: 0.01)
        XCTAssertFalse(items.contains { $0.isFloating })
    }

    func testOverlayIdentifiesFloatingWindowByPosition() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        XCTAssertTrue(window.focusWindow())
        let rect = Rect(topLeftX: 800, topLeftY: 100, width: 200, height: 200)
        let items = zoneOverlayItems(in: workspace, floatingRect: rect)
        XCTAssertEqual(items.map(\.isActive), [false, true, false])
        XCTAssertTrue(items.allSatisfy { $0.isFloating })
    }

    func testHintsUseConfiguredBindingsAndCommands() {
        let vim = HotkeyBinding(.option, .h, parseCommand("focus left").cmdOrDie, descriptionWithKeyNotation: "alt-h")
        let custom = HotkeyBinding([.command, .shift], .j, parseCommand("move-node-to-zone center").cmdOrDie,
                                   descriptionWithKeyNotation: "cmd-shift-j")
        let shell = HotkeyBinding(.option, .t, parseCommand("layout floating tiling; echo -- secret").cmdOrDie,
                                  descriptionWithKeyNotation: "alt-t")
        let unrelated = HotkeyBinding(.option, .q, parseCommand("echo -- secret").cmdOrDie,
                                      descriptionWithKeyNotation: "alt-q")
        let hints = zoneOverlayBindingHints(["a": vim, "b": custom, "c": shell, "d": unrelated])
        XCTAssertTrue(hints.contains("alt-h: focus left"))
        XCTAssertTrue(hints.contains("cmd-shift-j: move-node-to-zone center"))
        XCTAssertTrue(hints.contains("alt-t: includes layout floating tiling"))
        XCTAssertFalse(hints.joined().contains("secret"))
        XCTAssertFalse(hints.joined().contains("alt-q"))
        XCTAssertFalse(hints.joined().contains("alt-ctrl-1"))
    }
}
