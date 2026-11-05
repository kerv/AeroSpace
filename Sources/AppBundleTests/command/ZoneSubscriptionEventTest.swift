@testable import AppBundle
import Common
import XCTest

@MainActor
final class ZoneSubscriptionEventTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func normalizeJson(_ json: String) -> String {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testFocusZoneOnEmptyZoneBroadcastsZoneFocusedEvent() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let center = workspace.zoneContainers["center"].orDie()
        let focusedWindow = TestWindow.new(id: 1, parent: center)
        assertTrue(focusedWindow.focusWindow())
        await Task.yield()

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        let args = parseCmdArgs(["focus-zone", "left"].slice).cmdOrDie as! FocusZoneCmdArgs
        let result = try await FocusZoneCommand(args: args).run(.defaultEnv, .emptyStdin)
        await Task.yield()

        assertEquals(result.exitCode.rawValue, 0)
        let zoneFocusedEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"zone-focused""#) }
        XCTAssertTrue(zoneFocusedEvents.contains(#"{"_event":"zone-focused","workspace":"setUpWorkspacesForTests","zoneName":"left"}"#))
    }

    func testZonePresetBroadcastsZonePresetChangedEvent() async throws {
        config.zonePresets["balanced"] = ZonePreset(name: "balanced", zones: [
            ZoneDefinition(id: "left",   width: 0.25, layout: .tiles),
            ZoneDefinition(id: "center", width: 0.50, layout: .tiles),
            ZoneDefinition(id: "right",  width: 0.25, layout: .tiles),
        ])
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        await Task.yield()

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        let result = try await ZonePresetCommand(args: ZonePresetCmdArgs(rawArgs: ["balanced"]).copy(\.presetName, "balanced")).run(.defaultEnv, .emptyStdin)
        await Task.yield()

        assertEquals(result.exitCode.rawValue, 0)
        let presetEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"zone-preset-changed""#) }
        assertEquals(presetEvents, [#"{"_event":"zone-preset-changed","presetName":"balanced","workspace":"setUpWorkspacesForTests"}"#])
    }

    func testMoveNodeToZoneBroadcastsZoneWindowCountChangedEvents() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        _ = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        let focusedWindow = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"].orDie())
        assertTrue(focusedWindow.focusWindow())
        primeZoneEventBroadcastTracking()

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        let args = MoveNodeToZoneCmdArgs(rawArgs: [], "left")
        let result = try await MoveNodeToZoneCommand(args: args).run(.defaultEnv, .emptyStdin)
        broadcastZoneStateChangesIfNeeded()
        await Task.yield()

        let countEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"zone-window-count-changed""#) }
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(countEvents, [
            #"{"_event":"zone-window-count-changed","windowCount":2,"workspace":"setUpWorkspacesForTests","zoneName":"left"}"#,
            #"{"_event":"zone-window-count-changed","windowCount":0,"workspace":"setUpWorkspacesForTests","zoneName":"center"}"#,
        ])
    }

    func testZoneLayoutDiffBroadcastsZoneLayoutChangedEvent() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        primeZoneEventBroadcastTracking()

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        workspace.zoneContainers["left"]?.layout = .accordion
        broadcastZoneStateChangesIfNeeded()
        await Task.yield()

        let layoutEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"zone-layout-changed""#) }
        assertEquals(layoutEvents, [
            #"{"_event":"zone-layout-changed","layout":"h_accordion","workspace":"setUpWorkspacesForTests","zoneName":"left"}"#,
        ])
    }

    func testRestoreZoneMemoryBroadcastsWindowRoutedEvent() async throws {
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        let window = TestWindow.new(id: 1, parent: workspace.zoneContainers["right"].orDie())
        let profile = MonitorProfile([workspace.workspaceMonitor])
        ZoneMemory.shared.rememberZone("right", for: window, profile: profile)

        workspace.ensureZoneContainers(for: FakeMonitor.standard)

        var captured: [String] = []
        broadcastEventForTesting = { event in
            captured.append(JSONEncoder.aeroSpaceDefault.encodeToString(event).orDie())
        }

        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)
        await Task.yield()

        let routedEvents = captured
            .map(normalizeJson)
            .filter { $0.contains(#""_event":"window-routed""#) }
        assertEquals(routedEvents, [
            #"{"_event":"window-routed","appBundleId":"bobko.AeroSpace.test-app","source":"zoneMemory","windowId":1,"workspace":"setUpWorkspacesForTests","zoneName":"right"}"#,
        ])
    }
}
