@testable import AppBundle
import Common
import XCTest

final class ZoneCommandTest: XCTestCase {
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

    func testParseZoneCommand() {
        testParseSingleCommandSucc("zone --json", ZoneCmdArgs(rawArgs: []).copy(\.json, true))
        assertEquals(parseCommand("zone").errorOrNil, "--json is required")
    }

    @MainActor
    func testZoneCommandFailsWithoutZones() async throws {
        setUpWorkspacesForTests()

        let result = try await ZoneCommand(args: ZoneCmdArgs(rawArgs: []).copy(\.json, true)).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["zone: zones not active on this workspace"])
    }

    @MainActor
    func testZoneCommandJsonOutput() async throws {
        setUpWorkspacesForTests()
        let workspace = focus.workspace
        workspace.ensureZoneContainers(for: FakeMonitor.ultrawide)

        _ = TestWindow.new(id: 1, parent: workspace.zoneContainers["left"].orDie())
        let focusedWindow = TestWindow.new(id: 2, parent: workspace.zoneContainers["center"].orDie())
        assertTrue(focusedWindow.focusWindow())

        let result = try await ZoneCommand(args: ZoneCmdArgs(rawArgs: []).copy(\.json, true)).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let expectedJson = JSONEncoder.aeroSpaceDefault.encodeToString(
            ZoneRow(
                workspace: workspace.name,
                monitorId: workspace.workspaceMonitor.monitorId_oneBased,
                monitorName: workspace.workspaceMonitor.name,
                zoneId: "center",
                layout: "h_tiles",
                isFocused: true,
                windowCount: 1,
                weight: Double(workspace.zoneContainers["center"].orDie().getWeight(.h)),
            )
        )!
        assertEquals(result.stdout, [expectedJson])
        assertEquals(result.stderr, [])
    }
}
