@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZoneNewWindowPlacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewWindow_fallbackToCenter() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        XCTAssertTrue(window.parent === workspace.zoneContainers["center"], "No MRU window → should land in center zone")
    }

    func testNewWindow_followsMruZone() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let windowA = TestWindow.new(id: 1, parent: left)
        let windowB = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await windowB.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        XCTAssertTrue(windowA.parent === left, "Existing window should stay in left zone")
        XCTAssertTrue(windowB.parent === left, "New window should follow MRU zone (left)")
    }

    func testNewWindow_fallbackToRoot_whenNoZones() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        XCTAssertTrue(window.parent === workspace.rootTilingContainer, "No zones → should fall back to rootTilingContainer")
    }

    /// With a 2-zone layout (no "center"), a new window with no MRU should fall back to
    /// defs[count/2] — the second zone — rather than rootTilingContainer.
    func testNewWindow_fallbackToMiddleZone_twoZoneLayout() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "main",      width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        XCTAssertNil(workspace.zoneContainers["center"], "2-zone layout must not have a center zone")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
        let secondary = workspace.zoneContainers["secondary"]!
        XCTAssertTrue(window.parent === secondary, "No MRU + no center → should land in defs[count/2] = secondary zone")
    }

    func testFloatingWindow_doesNotOccupyZone() {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let center = workspace.zoneContainers["center"]!

        // Window starts in center zone (simulates tiling placement before float rule fires)
        let window = TestWindow.new(id: 1, parent: center)
        XCTAssertTrue(window.parent === center)

        // Float rule fires (on-window-detected runs 'layout floating')
        window.bindAsFloatingWindow(to: workspace)

        // Window is now in the workspace floating container, outside all zones
        XCTAssertTrue(window.parent === workspace.floatingWindowsContainer, "Floating window should be in the workspace floating container")
        XCTAssertFalse(center.children.contains { $0 === window }, "Center zone should no longer contain the window")
        // Zone containers survive even though one is now empty
        XCTAssertNotNil(workspace.zoneContainers["center"], "Empty zone should still exist after window floated away")
    }

    func testFloatingDefaults_areAppliedByRuntimePlacementPipeline() {
        config.floating.appIds = [TestApp.shared.rawAppBundleId.orDie()]

        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        applyRuntimePlacementDefaults(window)

        XCTAssertTrue(window.parent === workspace.floatingWindowsContainer, "[floating] should float matching apps without going through on-window-detected sugar")
    }

    func testAppRouting_routesNewWindowToConfiguredZone() async throws {
        let appId = TestApp.shared.rawAppBundleId.orDie()
        config.zones.appRouting[appId] = "right"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: appId)

        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["right"]!)
    }

    func testAppRouting_winsOverZoneMemory() async throws {
        let appId = TestApp.shared.rawAppBundleId.orDie()
        config.zones.appRouting[appId] = "left"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let profile = workspace.activeZoneProfile.orDie()
        let existing = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"]!)
        ZoneMemory.shared.rememberZone("right", for: existing, profile: profile)
        let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: appId)

        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["left"]!, "Explicit app routing should win over zone memory")
        XCTAssertEqual(decision.source, .appRouting)
    }

    func testAppRouting_missingZoneFallsBackToNormalPlacement() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        config.zones.appRouting[TestApp.shared.rawAppBundleId.orDie()] = "right"

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let main = workspace.zoneContainers["main"]!
        _ = TestWindow.new(id: 1, parent: main)

        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertTrue(newWindow.parent === main, "Routes to missing zones should fall through to normal MRU placement")
    }

    func testAppRouting_noZonesFallsBackToRootPlacement() async throws {
        config.zones.appRouting[TestApp.shared.rawAppBundleId.orDie()] = "right"

        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertTrue(window.parent === workspace.rootTilingContainer, "App routing should be a no-op when zones are inactive")
    }

    func testNewWindow_appendPolicy_appendsToZoneRoot() async throws {
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .append)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        _ = TestWindow.new(id: 1, parent: nested)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertTrue(newWindow.parent === left, "append policy should place the new window at the zone root")
    }

    func testNewWindow_afterFocusedPolicy_usesZoneLocalMruPlacement() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let nested = TilingContainer.newVTiles(parent: left, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        let existing = TestWindow.new(id: 1, parent: nested)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertTrue(newWindow.parent === nested, "after-focused policy should insert relative to the zone-local MRU window")
        XCTAssertEqual(newWindow.ownIndex, existing.ownIndex.orDie() + 1)
    }

    func testNewWindow_appendHiddenPolicy_preservesActiveStackChild() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.25, layout: .stack),
            ZoneDefinition(id: "center", width: 0.5, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.25, layout: .tiles),
        ]
        config.zones.behavior["left"] = ZoneBehavior(newWindow: .appendHidden)

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let left = workspace.zoneContainers["left"]!
        let existing = TestWindow.new(id: 1, parent: left)

        workspace.focusedZone = "left"
        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertTrue(newWindow.parent === left, "append-hidden should still add the window to the target stack zone")
        XCTAssertTrue(left.mostRecentWindowRecursive === existing, "append-hidden should preserve the visible stack child")
    }

    func testNewWindow_staleFocusedZoneHint_isDroppedBeforeMruPlacement() async throws {
        config.zones.zones = [
            ZoneDefinition(id: "left", width: 0.25, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.5, layout: .tiles),
            ZoneDefinition(id: "right", width: 0.25, layout: .tiles),
        ]

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        workspace.focusedZone = "left"

        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide, force: true)

        let main = workspace.zoneContainers["main"]!
        _ = TestWindow.new(id: 1, parent: main)

        let newWindow = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await newWindow.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)

        XCTAssertNil(workspace.focusedZone, "Invalid focused-zone hints should be cleared once observed")
        XCTAssertTrue(newWindow.parent === main, "A stale focused-zone hint should not override the normal MRU placement path")
    }

    func testRememberedZoneFallback_reportsMiddleZoneSource() {
        config.zones.zones = [
            ZoneDefinition(id: "main", width: 0.6, layout: .tiles),
            ZoneDefinition(id: "secondary", width: 0.4, layout: .tiles),
        ]

        let workspace = Workspace.get(byName: name)
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let profile = workspace.activeZoneProfile.orDie()
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["main"]!)
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        let decision = resolveNewTilingWindowPlacement(
            in: workspace,
            appBundleId: TestApp.shared.rawAppBundleId.orDie()
        )

        XCTAssertEqual(decision.source, .middleZoneFallback)
        XCTAssertTrue(decision.bindingData.parent === workspace.zoneContainers["secondary"]!)
    }
}
