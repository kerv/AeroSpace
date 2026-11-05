import AppKit
import Common

struct MoveFloatingToZoneCommand: Command {
    let args: MoveFloatingToZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let parent = window.parent else { return .fail }
        let workspace: Workspace
        switch parent.cases {
            case .floatingWindowsContainer(let container):
                guard let ws = container.nodeWorkspace else { return .fail }
                workspace = ws
            case .tilingContainer:
                guard let ws = window.nodeWorkspace else { return .fail }
                workspace = ws
                window.bindAsFloatingWindow(to: workspace)
            default:
                return .fail(io.err("move-floating-to-zone: focused window is not floating or tiling"))
        }
        let zoneName = args.zone.val
        guard let toZone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("move-floating-to-zone: zones not active on this workspace"))
        }
        guard let toZoneRect = toZone.lastAppliedLayoutPhysicalRect ?? workspace.theoreticalZoneRect(for: zoneName) else {
            return .fail(io.err("move-floating-to-zone: zone layout not yet computed"))
        }
        guard let windowRect = try await window.getAxRect(.nonCancellable) else { return .fail }

        // Find the "from zone" by checking which zone contains the window center
        let windowCenter = windowRect.center
        let fromZoneRect: Rect = if let homeZone = workspace.zoneContainers.values.first(where: { $0.lastAppliedLayoutPhysicalRect?.contains(windowCenter) == true }),
                                    let homeRect = homeZone.lastAppliedLayoutPhysicalRect
        {
            homeRect
        } else {
            // Fall back to monitor rect
            workspace.workspaceMonitor.rect
        }

        let offsetX = windowRect.topLeftX - fromZoneRect.topLeftX
        let offsetY = windowRect.topLeftY - fromZoneRect.topLeftY
        let windowSize = windowRect.size
        let rawX = toZoneRect.topLeftX + offsetX
        let rawY = toZoneRect.topLeftY + offsetY
        let newX = rawX.coerce(in: toZoneRect.minX ... max(toZoneRect.minX, toZoneRect.maxX - windowSize.width))
        let newY = rawY.coerce(in: toZoneRect.minY ... max(toZoneRect.minY, toZoneRect.maxY - windowSize.height))

        window.setAxFrame(CGPoint(x: newX, y: newY), nil)
        ZoneMemory.shared.rememberZone(zoneName, for: window, profile: MonitorProfile([workspace.workspaceMonitor]))
        StickyMemory.shared.forget(windowId: window.windowId)
        return .succ
    }
}
