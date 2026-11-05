@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class ZoneMemoryCommandTest: XCTestCase {
    private struct ZoneMemoryRow: Encodable {
        let profileKey: String
        let appId: String
        let zoneId: String

        enum CodingKeys: String, CodingKey {
            case profileKey = "profile-key"
            case appId = "app-id"
            case zoneId = "zone-id"
        }
    }

    private var tempURL: URL!
    private var savedShared: ZoneMemory!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zone-memory-command-test-\(UUID().uuidString).json")
        savedShared = ZoneMemory.shared
        ZoneMemory.shared = ZoneMemory(storageURL: tempURL)
    }

    override func tearDown() async throws {
        ZoneMemory.shared = savedShared
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testParseZoneMemoryCommand() {
        testParseSingleCommandSucc("zone-memory list", ZoneMemoryCmdArgs(rawArgs: ["list"].slice).copy(\.action, .initialized(.list)))
        testParseSingleCommandSucc("zone-memory list --json", ZoneMemoryCmdArgs(rawArgs: ["list", "--json"].slice).copy(\.action, .initialized(.list)).copy(\.json, true))
        testParseSingleCommandSucc("zone-memory list --count", ZoneMemoryCmdArgs(rawArgs: ["list", "--count"].slice).copy(\.action, .initialized(.list)).copy(\.outputOnlyCount, true))
        testParseSingleCommandSucc(
            "zone-memory clear --app-id com.example.app",
            ZoneMemoryCmdArgs(rawArgs: ["clear", "--app-id", "com.example.app"].slice)
                .copy(\.action, .initialized(.clear))
                .copy(\.appId, "com.example.app")
        )
        testParseSingleCommandSucc("zone-memory clear --all", ZoneMemoryCmdArgs(rawArgs: ["clear", "--all"].slice).copy(\.action, .initialized(.clear)).copy(\.clearAll, true))

        assertEquals(parseCommand("zone-memory list --all").errorOrNil, "zone-memory list doesn't support --all or --app-id")
        assertEquals(parseCommand("zone-memory clear").errorOrNil, "zone-memory clear requires --app-id <app-bundle-id> or --all")
        assertEquals(parseCommand("zone-memory clear --count").errorOrNil, "zone-memory clear doesn't support --count or --json")
        assertEquals(parseCommand("zone-memory list --count --json").errorOrNil, "ERROR: Conflicting options: --count, --json")
    }

    @MainActor
    func testZoneMemoryListOutputsPersistedEntries() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("right", forBundleId: "com.example.chat", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)

        let result = try await ZoneMemoryCommand(args: ZoneMemoryCmdArgs(rawArgs: ["list"].slice).copy(\.action, .initialized(.list)))
            .run(.defaultEnv, .emptyStdin)

        let expected = JSONEncoder.aeroSpaceDefault.encodeToString([
            ZoneMemoryRow(profileKey: standard.key, appId: "com.example.mail", zoneId: "center"),
            ZoneMemoryRow(profileKey: ultrawide.key, appId: "com.example.chat", zoneId: "right"),
            ZoneMemoryRow(profileKey: ultrawide.key, appId: "com.example.mail", zoneId: "left"),
        ])!
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, [expected])
        assertEquals(result.stderr, [])
    }

    @MainActor
    func testZoneMemoryClearByAppIdRemovesEntriesAcrossProfiles() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)
        ZoneMemory.shared.rememberZone("right", forBundleId: "com.example.chat", profile: ultrawide)

        let args = ZoneMemoryCmdArgs(rawArgs: ["clear", "--app-id", "com.example.mail"].slice)
            .copy(\.action, .initialized(.clear))
            .copy(\.appId, "com.example.mail")
        let result = try await ZoneMemoryCommand(args: args).run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["2"])
        XCTAssertEqual(ZoneMemory.shared.entries(), [
            ZoneMemory.Entry(profileKey: ultrawide.key, appId: "com.example.chat", zoneName: "right"),
        ])
    }

    @MainActor
    func testZoneMemoryClearAllRemovesEverything() async throws {
        let ultrawide = MonitorProfile([FakeMonitor.ultrawide])
        let standard = MonitorProfile([FakeMonitor.standard])
        ZoneMemory.shared.rememberZone("left", forBundleId: "com.example.mail", profile: ultrawide)
        ZoneMemory.shared.rememberZone("center", forBundleId: "com.example.mail", profile: standard)

        let result = try await ZoneMemoryCommand(args: ZoneMemoryCmdArgs(rawArgs: ["clear", "--all"].slice).copy(\.action, .initialized(.clear)).copy(\.clearAll, true))
            .run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["2"])
        XCTAssertEqual(ZoneMemory.shared.entries(), [])
    }
}
