@testable import AppBundle
import Common
import XCTest

final class ListZonesTest: XCTestCase {
    private struct ZoneRow: Encodable {
        let workspace: String
        let monitorId: Int?
        let monitorName: String
        let zoneId: String
        let layout: String
        let isFocused: Bool
        let windowCount: Int
        let weight: Double

        enum CodingKeys: String, CodingKey {
            case workspace
            case monitorId = "monitor-id"
            case monitorName = "monitor-name"
            case zoneId = "zone-id"
            case layout
            case isFocused = "is-focused"
            case windowCount = "window-count"
            case weight
        }
    }

    func testParseListZonesCommand() {
        testParseSingleCommandSucc("list-zones", ListZonesCmdArgs(rawArgs: []))
        testParseSingleCommandSucc("list-zones --json", ListZonesCmdArgs(rawArgs: []).copy(\.json, true))
        testParseSingleCommandSucc("list-zones --count", ListZonesCmdArgs(rawArgs: []).copy(\.outputOnlyCount, true))
        assertEquals(parseCommand("list-zones --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
    }

    @MainActor
    func testListZonesOutputWithoutZones() async throws {
        setUpWorkspacesForTests()

        let result = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, [JSONEncoder.aeroSpaceDefault.encodeToString([ZoneRow]())!])
        assertEquals(result.stderr, [])
    }

    @MainActor
    func testListZonesOutputWithZones() async throws {
        setUpWorkspacesForTests()
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        let left = workspace.zoneContainers["left"].orDie()
        let center = workspace.zoneContainers["center"].orDie()
        _ = TestWindow.new(id: 1, parent: left)
        let focusedWindow = TestWindow.new(id: 2, parent: center)
        assertTrue(focusedWindow.focusWindow())

        let result = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let expectedJson = JSONEncoder.aeroSpaceDefault.encodeToString([
            ZoneRow(
                workspace: workspace.name,
                monitorId: workspace.workspaceMonitor.monitorId_oneBased,
                monitorName: workspace.workspaceMonitor.name,
                zoneId: "left",
                layout: "h_tiles",
                isFocused: false,
                windowCount: 1,
                weight: Double(left.getWeight(.h)),
            ),
            ZoneRow(
                workspace: workspace.name,
                monitorId: workspace.workspaceMonitor.monitorId_oneBased,
                monitorName: workspace.workspaceMonitor.name,
                zoneId: "center",
                layout: "h_tiles",
                isFocused: true,
                windowCount: 1,
                weight: Double(center.getWeight(.h)),
            ),
            ZoneRow(
                workspace: workspace.name,
                monitorId: workspace.workspaceMonitor.monitorId_oneBased,
                monitorName: workspace.workspaceMonitor.name,
                zoneId: "right",
                layout: "h_tiles",
                isFocused: false,
                windowCount: 0,
                weight: Double(workspace.zoneContainers["right"].orDie().getWeight(.h)),
            ),
        ])!
        assertEquals(result.stdout, [expectedJson])
        assertEquals(result.stderr, [])

        let countResult = try await ListZonesCommand(args: ListZonesCmdArgs(rawArgs: []).copy(\.outputOnlyCount, true)).run(.defaultEnv, .emptyStdin)
        assertEquals(countResult.exitCode.rawValue, 0)
        assertEquals(countResult.stdout, ["3"])
        assertEquals(countResult.stderr, [])
    }
}
