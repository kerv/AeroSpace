@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class ZoneMemoryTests: XCTestCase {
    private var tempURL: URL!
    private var savedShared: ZoneMemory!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-memory-test-\(UUID().uuidString).json")
        savedShared = ZoneMemory.shared
        ZoneMemory.shared = ZoneMemory(storageURL: tempURL)
    }

    override func tearDown() async throws {
        ZoneMemory.shared = savedShared
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - MonitorProfile fingerprint

    func testMonitorProfile_sameLayout_sameKey() {
        let p1 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let p2 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertEqual(p1.key, p2.key)
    }

    func testMonitorProfile_differentResolution_differentKey() {
        let p1 = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let p2 = MonitorProfile([AnyMonitor(width: 2560, height: 1440)])
        XCTAssertNotEqual(p1.key, p2.key)
    }

    func testMonitorProfile_multiMonitor_sortedByOrigin() {
        let left  = AnyMonitor(width: 1920, height: 1080, originX: 0,    originY: 0)
        let right = AnyMonitor(width: 1920, height: 1080, originX: 1920, originY: 0)
        let p1 = MonitorProfile([left, right])
        let p2 = MonitorProfile([right, left]) // reversed input order
        XCTAssertEqual(p1.key, p2.key, "Profile key must be stable regardless of input order")
    }

    // MARK: - ZoneMemory record/lookup

    func testRememberAndRecall() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        ZoneMemory.shared.rememberZone("left", for: window, profile: profile)
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: window, profile: profile), "left")
    }

    func testUnknownWindow_returnsNil() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 99, parent: workspace.zoneContainers["center"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertNil(ZoneMemory.shared.rememberedZone(for: window, profile: profile))
    }

    func testDifferentProfile_noMatch() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        let profileA = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        let profileB = MonitorProfile([AnyMonitor(width: 2560, height: 1440)])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profileA)
        XCTAssertNil(ZoneMemory.shared.rememberedZone(for: window, profile: profileB))
    }

    // MARK: - Persistence

    func testPersistAndReload() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        let reloaded = ZoneMemory(storageURL: tempURL)
        XCTAssertEqual(reloaded.rememberedZone(for: window, profile: profile), "right")
    }

    func testCorruptJson_silentlyResetsToEmpty() {
        try! "not json at all".data(using: .utf8)!.write(to: tempURL)
        let memory = ZoneMemory(storageURL: tempURL)
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"]!)
        let profile = MonitorProfile([AnyMonitor(width: 3440, height: 1440)])
        XCTAssertNil(memory.rememberedZone(for: window, profile: profile))
    }

    func testMissingFile_treatsAsEmpty() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let memory = ZoneMemory(storageURL: missingURL)
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["center"]!)
        XCTAssertNil(memory.rememberedZone(for: window, profile: MonitorProfile([AnyMonitor(width: 3440, height: 1440)])))
    }

    // MARK: - Stale zone IDs

    /// After a layout change, remembered zone IDs that no longer exist in the active layout
    /// must be silently ignored — the window stays in rootTilingContainer rather than crashing
    /// or landing in the wrong zone.
    func testStaleZoneId_silentlyDroppedOnRestore() {
        let workspace = Workspace.get(byName: name)

        // Activate the default 3-zone layout and record "right" for a window.
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        let profile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        // Deactivate (simulates monitor disconnect).
        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        // Switch to a 2-zone layout that has no "right" zone.
        config.zones.zones = [
            ZoneDefinition(id: "main",      width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]

        // Re-activate zones — restoreZoneMemory should move the window to the middle zone (fallback)
        // rather than leaving it as a root tiling child outside the zone model.
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertFalse(workspace.zoneContainers.isEmpty, "2-zone layout should be active")
        XCTAssertNil(workspace.zoneContainers["right"], "Old zone must not exist in new layout")
        // defs = [main(0), secondary(1)]; middle index = 2/2 = 1 → secondary
        let secondaryZone = workspace.zoneContainers["secondary"]!
        XCTAssertTrue(secondaryZone.children.contains { $0 === window },
                      "Window with stale zone ID should be rebound to the middle zone (secondary), not left in rootTilingContainer")
    }

    // MARK: - Restore on zone activation

    /// Simulate a monitor reconnect: zones activate and windows are moved to their remembered zones.
    func testRestoreZoneMemory_windowMovedToRememberedZone() {
        let workspace = Workspace.get(byName: name)

        // Activate zones and put a window in the right zone
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)

        // Record the assignment using the same profile that `activateZones` will use
        // (activateZones calls MonitorProfile(monitors); in tests, monitors = [testMonitor 1920×1080])
        let testProfile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("right", for: window, profile: testProfile)

        // Deactivate zones (simulate monitor disconnect) – window lands in rootTilingContainer
        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        XCTAssertTrue(workspace.zoneContainers.isEmpty)
        XCTAssertTrue(workspace.rootTilingContainer.children.contains { $0 === window })

        // Re-activate zones (simulate reconnect) – restoreZoneMemory should fire
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        XCTAssertFalse(workspace.zoneContainers.isEmpty)
        let rightZone = workspace.zoneContainers["right"]!
        XCTAssertTrue(rightZone.children.contains { $0 === window },
                      "Window should be restored to right zone on reconnect")
    }

    func testRestoreZoneMemory_respectsInsertionPolicy() {
        config.zones.behavior["right"] = ZoneBehavior(newWindow: .afterFocused)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let right = workspace.zoneContainers["right"]!
        let existing = TestWindow.new(id: 1, parent: right)
        let window = TestWindow.new(id: 2, parent: right)

        let testProfile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("right", for: existing, profile: testProfile)
        ZoneMemory.shared.rememberZone("right", for: window, profile: testProfile)

        workspace.ensureZoneContainers(for: FakeMonitor.standard)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let restoredRight = workspace.zoneContainers["right"]!
        XCTAssertTrue(window.parent === restoredRight, "Zone-memory restore should rebind into the destination zone")
        XCTAssertEqual(window.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testPresentationMode_disconnectDoesNotOverwriteZoneMemory() {
        let workspace = Workspace.get(byName: name)
        config.zones.zones = [
            ZoneDefinition(id: "chat", width: 0.2, layout: .tiles),
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "tools", width: 0.2, layout: .tiles),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let toolWindow = TestWindow.new(id: 1, parent: workspace.zoneContainers["tools"]!)
        let testProfile = MonitorProfile(monitors)
        ZoneMemory.shared.rememberZone("tools", for: toolWindow, profile: testProfile)
        XCTAssertTrue(toolWindow.focusWindow())

        _ = enablePresentationMode(
            on: workspace,
            monitor: FakeMonitor(width: 5120, height: 1440),
            CmdIoImpl(stdin: .emptyStdin)
        )

        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        XCTAssertNil(workspace.presentationModeSnapshot)
        XCTAssertEqual(ZoneMemory.shared.rememberedZone(for: toolWindow, profile: testProfile), "tools")

        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertEqual(workspace.zoneContaining(toolWindow)?.name, "tools")
    }
}

// MARK: - AnyMonitor

/// A test monitor with configurable origin, unlike FakeMonitor which is always at (0,0).
private struct AnyMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int = 1
    let name: String = "AnyMonitor"
    let rect: Rect
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain: Bool = false

    init(width: CGFloat, height: CGFloat, originX: CGFloat = 0, originY: CGFloat = 0) {
        rect = Rect(topLeftX: originX, topLeftY: originY, width: width, height: height)
    }
}
