@testable import AppBundle
import Foundation
import XCTest

@MainActor final class WindowPlacementMemoryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPersistAndRecallDifferentWorkspaces() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID().uuidString).json")
        let memory = WindowPlacementMemory(storageURL: url)
        let left = WindowPlacementMemory.Placement(workspace: "1", zone: "left", order: 1)
        let right = WindowPlacementMemory.Placement(workspace: "2", zone: "right", order: 0)
        memory.remember(appId: "example.app", title: "Window A", profile: "monitor", placement: left, makeCurrent: true)
        memory.remember(appId: "example.app", title: "Window A", profile: "monitor", placement: right, makeCurrent: true)
        let restored = WindowPlacementMemory(storageURL: url).find(appId: "example.app", title: "Window A", profile: "monitor")
        XCTAssertEqual(restored?.lastWorkspace, "2")
        XCTAssertEqual(restored?.placements["1"], left)
        XCTAssertEqual(restored?.placements["2"], right)
        XCTAssertNil(memory.find(appId: "example.app", title: "Window A", profile: "other-monitor"))
    }

    func testTitleMatchingDoesNotGuessWhenMultipleEntriesExist() {
        let memory = WindowPlacementMemory(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let placement = WindowPlacementMemory.Placement(workspace: "1", zone: "left", order: 1)
        memory.remember(appId: "app", title: "First", profile: "screen", placement: placement, makeCurrent: true)
        XCTAssertNotNil(memory.find(appId: "app", title: "Changed", profile: "screen"))
        memory.remember(appId: "app", title: "Second", profile: "screen", placement: placement, makeCurrent: true)
        XCTAssertNil(memory.find(appId: "app", title: "Changed", profile: "screen"))
        XCTAssertEqual(memory.find(appId: "app", title: "Second", profile: "screen")?.title, "Second")
    }

    func testReturnToWorkspaceRestoresZoneAndClampsTileIndex() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let zone = workspace.zoneContainers["left"]!
        let first = TestWindow.new(id: 1, parent: zone)
        let second = TestWindow.new(id: 2, parent: zone)
        first.placementIdentityTitle = "first"
        second.placementIdentityTitle = "second"
        rememberWindowPlacement(second)
        second.bind(to: workspace.zoneContainers["right"]!, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let binding = rememberedBinding(for: second, in: workspace)!
        second.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        XCTAssertTrue(zone.children[0] === first)
        XCTAssertTrue(zone.children[1] === second)
        first.unbindFromParent()
        second.bind(to: workspace.zoneContainers["right"]!, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let clamped = rememberedBinding(for: second, in: workspace)!
        XCTAssertEqual(clamped.index, 0)
    }
    func testRestoresOrderWhenWindowsReturnOutOfOrder() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let right = workspace.zoneContainers["right"]!
        let first = TestWindow.new(id: 11, parent: left)
        let second = TestWindow.new(id: 12, parent: left)
        let third = TestWindow.new(id: 13, parent: left)
        first.placementIdentityTitle = "first"
        second.placementIdentityTitle = "second"
        third.placementIdentityTitle = "third"
        for window in [first, second, third] { rememberWindowPlacement(window) }
        for window in [first, second, third] { window.bind(to: right, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
        for window in [third, second, first] {
            let binding = rememberedBinding(for: window, in: workspace)!
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        }
        XCTAssertEqual(left.children.compactMap { ($0 as? Window)?.windowId }, [11, 12, 13])
    }

    func testDoesNotRecordIndistinguishableWindows() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let zone = workspace.zoneContainers["left"]!
        let first = TestWindow.new(id: 21, parent: zone)
        let second = TestWindow.new(id: 22, parent: zone)
        first.placementIdentityTitle = "Same title"
        second.placementIdentityTitle = "Same title"
        rememberWindowPlacement(first)
        rememberWindowPlacement(second)
        XCTAssertTrue(WindowPlacementMemory.shared.entries.isEmpty)
    }

}
