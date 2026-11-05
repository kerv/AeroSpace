import AppKit
import Common

@MainActor var activeZonePresetName: String? = nil

struct ZonePresetCommand: Command {
    let args: ZonePresetCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        if args.reset {
            config.zones = defaultZonesConfig
            activeZonePresetName = nil
        } else if let name = args.presetName {
            guard let preset = config.zonePresets[name] else {
                return .fail(io.err("zone-preset: unknown preset '\(name)'. Available: \(config.zonePresets.keys.sorted().joined(separator: ", "))"))
            }
            config.zones = config.zones.copy(\.zones, preset.zones)
            activeZonePresetName = name
        } else if let name = args.saveName {
            let zones = focus.workspace.currentLiveZoneDefinitions()
            let preset = ZonePreset(name: name, zones: zones)
            config.zonePresets[name] = preset
            io.out("Saved zone preset '\(name)' (\(preset.zones.count) zones)")
            return .succ
        } else if args.export {
            io.out(exportCurrentZones())
            return .succ
        }
        // Exit focus mode on all workspaces before rebuilding — stale savedZoneWeights from
        // before the preset would otherwise overwrite the new preset widths on zone-focus-mode off.
        for workspace in Workspace.all {
            workspace.savedZoneWeights = nil
            workspace.focusModeZone = nil
        }
        // Rebuild zone containers on all workspaces with force=true to pick up new widths/layouts.
        // Include hidden workspaces: ensureZoneContainers is a no-op without force, so hidden ones
        // would otherwise keep stale containers until restart.
        for workspace in Workspace.all {
            workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
        }
        updateTrayText()
        broadcastEvent(.zonePresetChanged(workspace: focus.workspace.name, presetName: activeZonePresetName))
        return .succ
    }
}

/// Serialises the current zone layout as a `[[zone-presets]]` TOML block
/// that can be pasted directly into an AeroSpace config file.
@MainActor
private func exportCurrentZones() -> String {
    let name = activeZonePresetName ?? "my-layout"
    var lines: [String] = []
    lines.append("[[zone-presets]]")
    lines.append("name = \"\(name)\"")
    for zone in focus.workspace.currentLiveZoneDefinitions() {
        lines.append("")
        lines.append("[[zone-presets.zone]]")
        lines.append("id = \"\(zone.id)\"")
        lines.append("width = \(zone.width)")
        lines.append("layout = \"\(zone.layout.rawValue)\"")
    }
    return lines.joined(separator: "\n")
}
