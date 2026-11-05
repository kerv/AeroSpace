import Common
import Foundation

struct ZoneCommand: Command {
    let args: ZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        guard !workspace.zoneContainers.isEmpty else {
            return .fail(io.err("zone: zones not active on this workspace"))
        }
        guard let zoneName = activeZoneName(in: workspace),
              let zone = snapshotZones(in: workspace).first(where: { $0.zoneId == zoneName })
        else {
            return .fail(io.err("zone: no active zone"))
        }
        return switch JSONEncoder.aeroSpaceDefault.encodeToString(zone) {
            case .some(let json): .succ(io.out(json))
            case .none: .fail(io.err("Can't encode zone snapshot to JSON"))
        }
    }
}
