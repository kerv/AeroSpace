import AppKit
import Common

/// The name of the currently-active monitor-profile rule, or nil if no profile matched.
/// Exposed for observability (logs, future events).
@MainActor var activeMonitorProfileName: String? = nil

/// When true, zone containers are suppressed on all workspaces regardless of monitor aspect ratio.
/// Set when a matched [[monitor-profiles]] entry specifies `apply-zone-layout = "disabled"`.
/// Cleared when the active profile changes to one without that directive.
@MainActor var zonesDisabledByProfile: Bool = false

/// Evaluate `[[monitor-profiles]]` rules against the current monitor topology and apply the first
/// matching profile. Idempotent: re-applying the same profile is a no-op for snapshot restoration
/// but does re-apply zone layout (so config-reload correctly rebuilds containers).
///
/// Call sites:
/// - `initAppBundle` — startup, after zone containers are first set up
/// - `reloadConfig`  — after new config is applied and base zones are rebuilt
/// - monitor-change handler in gcMonitors/refreshState — on connect/disconnect/rearrange
@MainActor
func applyMatchingMonitorProfile() {
    let currentMonitors = monitors

    let matched = config.monitorProfiles.first { profile in
        let m = profile.matcher
        if let minRatio = m.minAspectRatio {
            guard currentMonitors.contains(where: {
                $0.visibleRect.width / $0.visibleRect.height >= minRatio
            }) else { return false }
        }
        if let count = m.monitorCount {
            guard currentMonitors.count == count else { return false }
        }
        return true
    }

    let previousProfileName = activeMonitorProfileName
    activeMonitorProfileName = matched?.name

    // --- Apply zone layout directive ---
    if let directive = matched?.applyZoneLayout {
        if directive == "disabled" {
            if !zonesDisabledByProfile {
                zonesDisabledByProfile = true
                for workspace in Workspace.all {
                    workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
                }
            }
        } else if let preset = config.zonePresets[directive] {
            zonesDisabledByProfile = false
            config.zones = config.zones.copy(\.zones, preset.zones)
            activeZonePresetName = directive
            for workspace in Workspace.all {
                workspace.savedZoneWeights = nil
                workspace.focusModeZone = nil
            }
            for workspace in Workspace.all {
                workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
            }
            broadcastEvent(.zonePresetChanged(workspace: focus.workspace.name, presetName: directive))
            updateTrayText()
        } else {
            aeroLog("monitor-profiles: profile '\(matched?.name ?? "?")' references unknown zone-preset '\(directive)' — ignoring")
            // Unknown preset: still clear stale disabled state so zones aren't permanently
            // suppressed when the previous matched profile had apply-zone-layout = "disabled".
            if zonesDisabledByProfile {
                zonesDisabledByProfile = false
                for workspace in Workspace.all {
                    workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
                }
            }
        }
    } else {
        // No directive in this profile (or no match). Clear any stale disabled state so that
        // ultrawide zones re-activate normally if a previous profile had disabled them.
        if zonesDisabledByProfile {
            zonesDisabledByProfile = false
            for workspace in Workspace.all {
                workspace.ensureZoneContainers(for: workspace.workspaceMonitor, force: true)
            }
        }
    }

    // --- Restore workspace snapshot ---
    // Only restore on profile transition, not on every re-evaluation (e.g. config reload).
    if matched?.name != previousProfileName, let snapshotName = matched?.restoreWorkspaceSnapshot {
        try? WorkspaceSnapshot.restore(name: snapshotName)
    }

    if let name = activeMonitorProfileName {
        aeroLog("monitor-profiles: active profile '\(name)'")
    }
}
