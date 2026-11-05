import AppKit
import Common

struct ZoneFocusModeCommand: Command {
    let args: ZoneFocusModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        guard !workspace.zoneContainers.isEmpty else {
            return .fail(io.err("zone-focus-mode: zones not active on this workspace"))
        }

        let isCurrentlyOn = workspace.savedZoneWeights != nil
        let shouldTurnOn = switch args.action.val {
            case .on: true
            case .off: false
            case .toggle: !isCurrentlyOn
        }

        if shouldTurnOn {
            // Determine which zone to focus: --zone flag, current zone, or MRU.
            let targetZone: String
            if let named = args.zone, workspace.zoneContainers[named] != nil {
                targetZone = named
            } else if let current = focus.windowOrNil.flatMap({ w in
                workspace.activeZoneDefinitions.first { workspace.zoneContainers[$0.id]?.allLeafWindowsRecursive.contains(where: { $0 === w }) == true }?.id
            }) {
                targetZone = current
            } else if let mru = workspace.mruZones.first(where: { workspace.zoneContainers[$0] != nil }) {
                targetZone = mru
            } else {
                // Default: middle zone (index count/2), which is "center" for a 3-zone layout.
                let defs = workspace.activeZoneDefinitions
                targetZone = defs[defs.count / 2].id
            }

            // Capture current weights before collapsing — only on first entry so that switching
            // zones while focus mode is already active doesn't snapshot the collapsed 8px slivers.
            if workspace.savedZoneWeights == nil {
                var saved: [String: CGFloat] = [:]
                for def in workspace.activeZoneDefinitions {
                    saved[def.id] = workspace.zoneContainers[def.id]?.getWeight(.h)
                }
                workspace.savedZoneWeights = saved
            }
            workspace.focusModeZone = targetZone

            // Collapse non-focused zones; give focused zone the remaining space.
            // Always compute totalWeight from the original saved weights (not collapsed state).
            let collapsedWeight = CGFloat(config.zones.focusModeCollapsedWidth)
            let nonFocusedCount = CGFloat(workspace.activeZoneDefinitions.count - 1)
            let totalWeight = workspace.savedZoneWeights!.values.compactMap { $0 }.reduce(0, +)
            for def in workspace.activeZoneDefinitions {
                guard let zone = workspace.zoneContainers[def.id] else { continue }
                zone.setWeight(.h, def.id == targetZone
                    ? max(collapsedWeight, totalWeight - nonFocusedCount * collapsedWeight)
                    : collapsedWeight)
            }
        } else {
            // Restore saved weights.
            if let saved = workspace.savedZoneWeights {
                for def in workspace.activeZoneDefinitions {
                    if let zone = workspace.zoneContainers[def.id], let weight = saved[def.id] {
                        zone.setWeight(.h, weight)
                    }
                }
            }
            workspace.savedZoneWeights = nil
            workspace.focusModeZone = nil
        }
        updateTrayText()
        return .succ
    }
}
