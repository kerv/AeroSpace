import Common

struct ShowZonePickerCommand: Command {
    let args: ShowZonePickerCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        guard let snapshot = zonePickerSnapshot(in: workspace) else {
            return .fail(io.err("show-zone-picker: zones not active on this workspace"))
        }
        ZonePickerHUDController.shared.show(snapshot: snapshot, monitor: workspace.workspaceMonitor)
        return .succ
    }
}
