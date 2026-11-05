import Common
import Foundation

struct ZoneSnapshot: Encodable {
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

struct ListZonesCommand: Command {
    let args: ListZonesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        let snapshots = snapshotZones(in: workspace)
        return switch true {
            case args.outputOnlyCount:
                .succ(io.out("\(snapshots.count)"))
            default:
                switch JSONEncoder.aeroSpaceDefault.encodeToString(snapshots) {
                    case .some(let json): .succ(io.out(json))
                    case .none: .fail(io.err("Can't encode zone snapshots to JSON"))
                }
        }
    }
}

@MainActor
func activeZoneName(in workspace: Workspace) -> String? {
    if focus.workspace === workspace,
       let window = focus.windowOrNil,
       let zoneName = zoneName(for: window, in: workspace)
    {
        zoneName
    } else {
        workspace.focusedZone
    }
}

@MainActor
func zoneName(for window: Window, in workspace: Workspace? = nil) -> String? {
    let workspace = workspace ?? window.nodeWorkspace
    guard let workspace,
          let zoneContainer = window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
    else { return nil }
    return workspace.zoneContainers.first { $0.value === zoneContainer }?.key
}

@MainActor
func snapshotZones(in workspace: Workspace) -> [ZoneSnapshot] {
    let activeZoneName = activeZoneName(in: workspace)
    let monitor = workspace.workspaceMonitor
    return workspace.activeZoneDefinitions.compactMap { def in
        let zoneName = def.id
        guard let zone = workspace.zoneContainers[zoneName] else { return nil }
        return ZoneSnapshot(
            workspace: workspace.name,
            monitorId: monitor.monitorId_oneBased,
            monitorName: monitor.name,
            zoneId: zoneName,
            layout: zoneLayoutString(zone),
            isFocused: activeZoneName == zoneName,
            windowCount: zone.allLeafWindowsRecursive.count,
            weight: Double(zone.getWeight(.h)),
        )
    }
}

func zoneLayoutString(_ container: TilingContainer) -> String {
    switch (container.layout, container.orientation) {
        case (.tiles, .h): LayoutCmdArgs.LayoutDescription.h_tiles.rawValue
        case (.tiles, .v): LayoutCmdArgs.LayoutDescription.v_tiles.rawValue
        case (.accordion, .h): LayoutCmdArgs.LayoutDescription.h_accordion.rawValue
        case (.accordion, .v): LayoutCmdArgs.LayoutDescription.v_accordion.rawValue
        case (.stack, _): LayoutCmdArgs.LayoutDescription.stack.rawValue
    }
}
