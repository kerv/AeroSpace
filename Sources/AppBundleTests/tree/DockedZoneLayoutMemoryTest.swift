@testable import AppBundle
import Foundation
import XCTest

@MainActor final class DockedZoneLayoutMemoryTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDisconnectAndReconnectRestoresWidthsStackOrderAndFocus() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let center = workspace.zoneContainers["center"]!
        let right = workspace.zoneContainers["right"]!
        left.setWeight(.h, 860)
        center.setWeight(.h, 1720)
        right.setWeight(.h, 860)
        left.changeOrientation(.h)
        let first = TestWindow.new(id: 101, parent: left, adaptiveWeight: 300)
        let second = TestWindow.new(id: 102, parent: left, adaptiveWeight: 560)
        first.placementIdentityTitle = "first"
        second.placementIdentityTitle = "second"
        _ = TestWindow.new(id: 103, parent: center)
        left.layout = .stack
        XCTAssertTrue(second.focusWindow())
        workspace.rememberDockedZoneLayout()

        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let restoredLeft = workspace.zoneContainers["left"]!
        XCTAssertEqual(restoredLeft.getWeight(.h), 860, accuracy: 0.01)
        XCTAssertEqual(workspace.zoneContainers["center"]!.getWeight(.h), 1720, accuracy: 0.01)
        XCTAssertEqual(workspace.zoneContainers["right"]!.getWeight(.h), 860, accuracy: 0.01)
        XCTAssertEqual(restoredLeft.orientation, .h)
        XCTAssertEqual(restoredLeft.layout, .stack)
        XCTAssertEqual(restoredLeft.allLeafWindowsRecursive.map(\.windowId), [101, 102])
        XCTAssertTrue(restoredLeft.mostRecentWindowRecursive === second)
        XCTAssertEqual(first.getWeight(.h), 300, accuracy: 0.01)
        XCTAssertEqual(second.getWeight(.h), 560, accuracy: 0.01)
    }

    func testRestoreDoesNotStealWindowsMovedWhileUndocked() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 201, parent: workspace.zoneContainers["left"]!)
        window.placementIdentityTitle = "window"
        workspace.rememberDockedZoneLayout()
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        let other = Workspace.get(byName: "other")
        window.bind(to: other.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertTrue(window.nodeWorkspace === other)
    }

    func testStoredLayoutsAreScopedByWorkspaceAndMonitor() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockedZoneLayoutMemory(storageURL: url)
        let saved = DockedZoneLayoutMemory.Snapshot(zones: [.init(id: "left", width: 1, layout: "stack", horizontal: false, activeWindowId: nil, windows: [])])
        store.save(saved, workspace: "1", profile: "dock")
        let loaded = DockedZoneLayoutMemory(storageURL: url)
        XCTAssertEqual(loaded.snapshot(workspace: "1", profile: "dock"), saved)
        XCTAssertNil(loaded.snapshot(workspace: "2", profile: "dock"))
        XCTAssertNil(loaded.snapshot(workspace: "1", profile: "laptop"))
    }

    func testLateDiscoveredWindowRestoresItsZoneDespiteChangedTitle() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 7863, parent: workspace.zoneContainers["center"]!)
        window.placementIdentityTitle = "Old browser tab"
        workspace.rememberDockedZoneLayout()
        window.bind(to: workspace.zoneContainers["left"]!, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        window.placementIdentityTitle = "New browser tab"
        XCTAssertTrue(workspace.restoreDockedWindowById(window))
        XCTAssertEqual(workspace.zoneContaining(window)?.name, "center")
    }

    func testLateDiscoveryDoesNotMoveUnknownOrFloatingWindows() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let saved = TestWindow.new(id: 7863, parent: workspace.zoneContainers["center"]!)
        workspace.rememberDockedZoneLayout()
        let unknown = TestWindow.new(id: 9999, parent: workspace.zoneContainers["left"]!)
        XCTAssertFalse(workspace.restoreDockedWindowById(unknown))
        saved.bindAsFloatingWindow(to: workspace)
        XCTAssertFalse(workspace.restoreDockedWindowById(saved))
    }
    func testLayoutAndResizeCommandsPersistWithoutUndocking() async {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let window = TestWindow.new(id: 301, parent: left)
        XCTAssertTrue(window.focusWindow())
        let oldWidth = left.getWeight(.h)
        let layout = await parseCommand("layout stack tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(layout.exitCode.rawValue, 0)
        let resize = await parseCommand("resize --zone width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(resize.exitCode.rawValue, 0)
        let snapshot = DockedZoneLayoutMemory.shared.snapshot(workspace: workspace.name, profile: workspace.zoneLayoutProfileKey!)!
        let savedLeft = snapshot.zones.first { $0.id == "left" }!
        XCTAssertEqual(savedLeft.layout, "stack")
        XCTAssertEqual(savedLeft.width, Double((oldWidth + 100) / 3440), accuracy: 0.00001)
    }

    func testMonitorWorkspacePreferencePersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let memory = DockedMonitorWorkspaceMemory(storageURL: url)
        memory.remember(workspace: "1", profile: "ultrawide")
        XCTAssertEqual(DockedMonitorWorkspaceMemory(storageURL: url).workspace(for: "ultrawide"), "1")
        XCTAssertNil(memory.workspace(for: "laptop"))
    }

    func testCapturingPartialLayoutPreservesClosedWindowSlots() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let first = TestWindow.new(id: 401, parent: left)
        let second = TestWindow.new(id: 402, parent: left)
        first.placementIdentityTitle = "first"
        second.placementIdentityTitle = "second"
        workspace.rememberDockedZoneLayout()
        first.unbindFromParent()
        workspace.rememberDockedZoneLayout()
        let saved = DockedZoneLayoutMemory.shared.snapshot(workspace: workspace.name, profile: workspace.zoneLayoutProfileKey!)!
        XCTAssertEqual(saved.zones.first { $0.id == "left" }!.windows.map(\.id), [401, 402])
    }

    func testMovingWindowToAnotherZoneRemovesItsOldZoneSlot() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 501, parent: workspace.zoneContainers["left"]!)
        window.placementIdentityTitle = "window"
        workspace.rememberDockedZoneLayout()
        window.bind(to: workspace.zoneContainers["right"]!, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        workspace.rememberDockedZoneLayout()
        let saved = DockedZoneLayoutMemory.shared.snapshot(workspace: workspace.name, profile: workspace.zoneLayoutProfileKey!)!
        XCTAssertTrue(saved.zones.first { $0.id == "left" }!.windows.isEmpty)
        XCTAssertEqual(saved.zones.first { $0.id == "right" }!.windows.map(\.id), [501])
    }

    func testActualMonitorReassignmentRestoresWorkspaceAndDockLayout() {
        struct Screen: Monitor {
            let monitorAppKitNsScreenScreensId: Int
            let name: String
            let rect: Rect
            var visibleRect: Rect { rect }
            var width: CGFloat { rect.width }
            var height: CGFloat { rect.height }
            let isMain: Bool
        }
        let laptop = Screen(monitorAppKitNsScreenScreensId: 1, name: "Laptop",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let dock = Screen(monitorAppKitNsScreenScreensId: 2, name: "Ultrawide",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 3440, height: 1440), isMain: false)
        defer {
            testMonitorsOverride = nil
            resetMonitorTrackingForTests()
            setUpWorkspacesForTests()
        }
        resetMonitorTrackingForTests()
        testMonitorsOverride = [laptop, dock]
        config.persistentWorkspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        gcMonitors()
        let workspace = Workspace.get(byName: "1")
        XCTAssertTrue(dock.setActiveWorkspace(workspace))
        workspace.ensureZoneContainers(for: dock)
        let left = workspace.zoneContainers["left"]!
        left.setWeight(.h, 860)
        workspace.zoneContainers["center"]!.setWeight(.h, 1720)
        workspace.zoneContainers["right"]!.setWeight(.h, 860)
        left.layout = .stack
        workspace.rememberDockedZoneLayout()

        testMonitorsOverride = [laptop]
        gcMonitors()
        XCTAssertTrue(laptop.setActiveWorkspace(workspace))
        gcMonitors()
        XCTAssertTrue(workspace.zoneContainers.isEmpty)

        testMonitorsOverride = [laptop, dock]
        gcMonitors()
        XCTAssertTrue(dock.activeWorkspace === workspace)
        XCTAssertFalse(laptop.activeWorkspace === workspace)
        XCTAssertEqual(workspace.zoneContainers["left"]?.layout, .stack)
        XCTAssertEqual(workspace.zoneContainers["center"]!.getWeight(.h), 1720, accuracy: 0.01)
        XCTAssertNotEqual(laptop.activeWorkspace.name, "10")
    }

    func testRestoresStackFocusForReopenedWindowWithNewId() {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let old = TestWindow.new(id: 601, parent: left)
        old.placementIdentityTitle = "Freelens"
        left.layout = .stack
        XCTAssertTrue(old.focusWindow())
        workspace.rememberDockedZoneLayout()
        old.unbindFromParent()
        let reopened = TestWindow.new(id: 602, parent: workspace.zoneContainers["center"]!)
        reopened.placementIdentityTitle = "Freelens"
        let snapshot = DockedZoneLayoutMemory.shared.snapshot(workspace: workspace.name, profile: workspace.zoneLayoutProfileKey!)!
        workspace.restoreDockedZoneWindows(snapshot)
        XCTAssertTrue(reopened.parent === left)
        XCTAssertTrue(left.mostRecentWindowRecursive === reopened)
    }

}
