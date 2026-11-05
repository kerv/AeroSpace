import Common

struct OverviewZonesCommand: Command {
    let args: OverviewZonesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let workspace = focus.workspace
        let floatingZone: String?
        if let window = focus.windowOrNil, window.isFloating,
           let rect = try? await window.getAxRect(.nonCancellable) {
            floatingZone = workspace.zoneForWindowRect(rect)
        } else {
            floatingZone = nil
        }
        guard let snapshot = overviewZonesSnapshot(in: workspace, floatingZoneName: floatingZone) else {
            return .fail(io.err("overview-zones: zones not active on this workspace"))
        }
        OverviewZonesHUDController.shared.toggle(snapshot: snapshot, monitor: workspace.workspaceMonitor)
        return .succ
    }
}
