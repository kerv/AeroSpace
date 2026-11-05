import Common

struct MoveNodeToZoneCommand: Command {
    let args: MoveNodeToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let workspace = window.nodeWorkspace ?? focus.workspace
        let zoneName = args.zone.val
        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("move-node-to-zone: zones not active on this workspace"))
        }
        let binding = workspace.bindingDataForNewWindow(inZone: zoneName, zone: zone)
        let wasFloating = window.isFloating
        if wasFloating {
            await rememberFloatingGeometry(window)
            window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
        }
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
        if wasFloating { FloatingMemory.shared.forget(windowId: window.windowId) }
        binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        rememberWindowPlacement(window)
        workspace.rememberDockedZoneLayout()
        StickyMemory.shared.forget(windowId: window.windowId)
        if args.noFocus { return .succ }
        return .from(bool: window.focusWindow())
    }
}
