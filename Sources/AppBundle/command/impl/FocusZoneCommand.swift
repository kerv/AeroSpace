import Common

struct FocusZoneCommand: Command {
    let args: FocusZoneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        guard !workspace.zoneContainers.isEmpty else {
            return .fail(io.err("focus-zone: zones not active on this workspace"))
        }

        let zoneName: String
        if args.scope == .mru {
            // Pick the most-recently-used zone that is not the current zone.
            let currentZone = focus.windowOrNil.flatMap { w in
                workspace.activeZoneDefinitions.first { workspace.zoneContainers[$0.id]?.allLeafWindowsRecursive.contains(where: { $0 === w }) == true }?.id
            }
            zoneName = workspace.mruZones.first(where: { $0 != currentZone })
                ?? workspace.activeZoneDefinitions.first { $0.id != currentZone }?.id
                ?? workspace.activeZoneDefinitions.first?.id
                ?? ""
        } else {
            zoneName = args.zone!
        }

        guard let zone = workspace.zoneContainers[zoneName] else {
            return .fail(io.err("focus-zone: zone '\(zoneName)' not found"))
        }

        // Update MRU history: push zoneName to front, keep unique, cap at 10 entries.
        workspace.mruZones.removeAll { $0 == zoneName }
        workspace.mruZones.insert(zoneName, at: 0)
        if workspace.mruZones.count > 10 { workspace.mruZones.removeLast() }

        // If focus mode is active and targeting a different zone, switch the focused zone.
        if workspace.savedZoneWeights != nil, zoneName != workspace.focusModeZone {
            var focusModeArgs = ZoneFocusModeCmdArgs(rawArgs: [], .on)
            focusModeArgs.zone = zoneName
            _ = ZoneFocusModeCommand(args: focusModeArgs).run(env, io)
        }

        if let mruWindow = zone.mostRecentWindowRecursive {
            workspace.focusedZone = nil
            return .from(bool: mruWindow.focusWindow())
        } else {
            workspace.focusedZone = zoneName
            broadcastZoneFocusedIfNeeded(workspace: workspace, zoneName: zoneName)
            updateTrayText()
            return .succ
        }
    }
}
