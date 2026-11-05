@testable import AppBundle
import Common
import XCTest


@MainActor
final class ZoneEnsureContainersTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testEnsureZoneContainers_split() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
        XCTAssertNotNil(workspace.zoneContainers["left"])
        XCTAssertNotNil(workspace.zoneContainers["center"])
        XCTAssertNotNil(workspace.zoneContainers["right"])
        XCTAssertTrue(workspace.zoneContainers["left"]!.isZoneContainer)
        XCTAssertTrue(workspace.zoneContainers["center"]!.isZoneContainer)
        XCTAssertTrue(workspace.zoneContainers["right"]!.isZoneContainer)
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .h)
        XCTAssertEqual(workspace.zoneContainers["left"]!.orientation, .h)
        XCTAssertEqual(workspace.zoneContainers["center"]!.orientation, .h)
        XCTAssertEqual(workspace.zoneContainers["right"]!.orientation, .h)
    }

    func testEnsureZoneContainers_noOp_alreadyHasZones() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let leftBefore = workspace.zoneContainers["left"]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertTrue(workspace.zoneContainers["left"] === leftBefore, "Should be same container ref (no-op)")
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 3)
    }

    func testEnsureZoneContainers_flatten() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let center = workspace.zoneContainers["center"]!
        TestWindow.new(id: 1, parent: left)
        TestWindow.new(id: 2, parent: center)
        TestWindow.new(id: 3, parent: center)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        // All windows re-parented to root; zone containers removed
        let rootChildren = workspace.rootTilingContainer.children
        XCTAssertEqual(rootChildren.count, 3)
        XCTAssertFalse(rootChildren.contains { $0 is TilingContainer })
        // Windows appear in left→center→right order
        XCTAssertEqual((rootChildren[0] as? TestWindow)?.windowId, 1)
        XCTAssertEqual((rootChildren[1] as? TestWindow)?.windowId, 2)
        XCTAssertEqual((rootChildren[2] as? TestWindow)?.windowId, 3)
    }

    func testEnsureZoneContainers_flattenNoOp_noZones() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 1)
    }

    func testEnsureZoneContainers_orientation_forcedHorizontal() {
        config.defaultRootContainerOrientation = .vertical
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.orientation, .h)
    }

    func testEnsureZoneContainers_twoZones() {
        config.zones.zones = [
            ZoneDefinition(id: "main",      width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 2)
        XCTAssertNotNil(workspace.zoneContainers["main"])
        XCTAssertNotNil(workspace.zoneContainers["secondary"])
        XCTAssertNil(workspace.zoneContainers["left"], "3-zone names must not appear in a 2-zone layout")
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["main", "secondary"])
    }

    func testEnsureZoneContainers_fourZones() {
        config.zones.zones = [
            ZoneDefinition(id: "zone1", width: 0.20, layout: .tiles),
            ZoneDefinition(id: "zone2", width: 0.35, layout: .tiles),
            ZoneDefinition(id: "zone3", width: 0.30, layout: .accordion),
            ZoneDefinition(id: "zone4", width: 0.15, layout: .tiles),
        ]
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.rootTilingContainer.children.count, 4)
        for id in ["zone1", "zone2", "zone3", "zone4"] {
            XCTAssertNotNil(workspace.zoneContainers[id], "\(id) should exist")
            XCTAssertTrue(workspace.zoneContainers[id]!.isZoneContainer)
        }
        XCTAssertEqual(workspace.activeZoneDefinitions.map(\.id), ["zone1", "zone2", "zone3", "zone4"])
    }

    func testEnsureZoneContainers_deactivate_clearsActiveZoneDefinitions() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.activeZoneDefinitions.count, 3)
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.activeZoneDefinitions.isEmpty)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
    }
}
