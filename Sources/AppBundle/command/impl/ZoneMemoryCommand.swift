import Common
import Foundation

private struct ZoneMemorySnapshot: Encodable, Equatable {
    let profileKey: String
    let appId: String
    let zoneId: String

    enum CodingKeys: String, CodingKey {
        case profileKey = "profile-key"
        case appId = "app-id"
        case zoneId = "zone-id"
    }
}

struct ZoneMemoryCommand: Command {
    let args: ZoneMemoryCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        switch args.action.val {
            case .list:
                let entries = ZoneMemory.shared.entries().map {
                    ZoneMemorySnapshot(profileKey: $0.profileKey, appId: $0.appId, zoneId: $0.zoneName)
                }
                if args.outputOnlyCount {
                    return .succ(io.out("\(entries.count)"))
                }
                return switch JSONEncoder.aeroSpaceDefault.encodeToString(entries) {
                    case .some(let json): .succ(io.out(json))
                    case .none: .fail(io.err("zone-memory: failed to encode entries"))
                }
            case .clear:
                let removed: Int
                if args.clearAll {
                    removed = ZoneMemory.shared.clearAll()
                } else {
                    removed = ZoneMemory.shared.clear(bundleId: args.appId.orDie())
                }
                return .succ(io.out("\(removed)"))
        }
    }
}
