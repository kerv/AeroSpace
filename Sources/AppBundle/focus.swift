import AppKit
import Common

enum EffectiveLeaf {
    case window(Window)
    case emptyWorkspace(Workspace)
}
extension LiveFocus {
    var asLeaf: EffectiveLeaf {
        if let windowOrNil { .window(windowOrNil) } else { .emptyWorkspace(workspace) }
    }
}

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. We keep it here only for 'on-focused-monitor-changed' to work
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        let windowFocus = window?.toLiveFocusOrNil() ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitor
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus.
/// Commands must be cautious about accessing this property directly. There are legitimate cases.
/// But, in general, commands must firstly check --window-id, --workspace, AEROSPACE_WINDOW_ID env and
/// AEROSPACE_WORKSPACE env before accessing the global focus.
@MainActor var focus: LiveFocus { _focus.live }

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    let oldFocus = focus
    var resolvedFocus = newFocus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
        // Move sticky floating windows from the old workspace to the new workspace
        for window in oldFocus.workspace.floatingWindows where StickyMemory.shared.isRemembered(windowId: window.windowId) {
            window.bindAsFloatingWindow(to: newFocus.workspace)
        }
        // If the previously focused window was sticky, carry it as the focus into the new workspace
        if let oldWindow = oldFocus.windowOrNil,
           StickyMemory.shared.isRemembered(windowId: oldWindow.windowId)
        {
            resolvedFocus = LiveFocus(windowOrNil: oldWindow, workspace: newFocus.workspace)
        }
    }

    _focus = resolvedFocus.frozen
    let status = resolvedFocus.workspace.workspaceMonitor.setActiveWorkspace(resolvedFocus.workspace)

    resolvedFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() -> Bool {
        if let focus = toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            // todo We should also exit-native-hidden/unminimize[/exit-native-fullscreen?] window if we want to fix ID-B6E178F2
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() -> LiveFocus? { visualWorkspace.map { LiveFocus(windowOrNil: self, workspace: $0) } }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        // todo unfortunately mostRecentWindowRecursive may recursively reach empty rootTilingContainer
        //      while floating or macos unconventional windows might be presented
        if let wd = mostRecentWindowRecursive ?? anyLeafWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

// Used by workspace-back-and-forth
@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

// Used by focus-back-and-forth
@MainActor private var _prevFocus: FrozenFocus? = nil
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }
@MainActor private var _lastBroadcastZoneFocus: (workspaceName: String, zoneName: String?)? = nil

@MainActor private var onFocusChangedRecursionGuard = false
// Should be called in refreshSession
@MainActor func checkOnFocusChangedCallbacks_nonCancellable() async {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let focus = focus
    let frozenFocus = focus.frozen
    var hasFocusChanged = false
    var hasFocusedWorkspaceChanged = false
    var hasFocusedMonitorChanged = false
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
        hasFocusChanged = true
    }
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        _prevFocusedWorkspaceName = _lastKnownFocus.workspaceName
        hasFocusedWorkspaceChanged = true
    }
    if frozenFocus.monitorId_oneBased != _lastKnownFocus.monitorId_oneBased {
        hasFocusedMonitorChanged = true
    }
    _lastKnownFocus = frozenFocus

    if onFocusChangedRecursionGuard { return }
    onFocusChangedRecursionGuard = true
    defer { onFocusChangedRecursionGuard = false }
    if hasFocusChanged {
        _ = await onFocusChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
    if let _prevFocusedWorkspaceName, hasFocusedWorkspaceChanged {
        onWorkspaceChanged(_prevFocusedWorkspaceName, frozenFocus.workspaceName, focus)
    }
    if hasFocusedMonitorChanged {
        _ = await onFocusedMonitorChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
}

@MainActor func onFocusedMonitorChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
    broadcastEvent(.focusedMonitorChanged(
        workspace: focus.workspace.name,
        monitorId_oneBased: focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
    ))
    return await config.onFocusedMonitorChanged.run(env.withFocus(focus), io)
}

@MainActor func onFocusChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
 // Immediately re-sync borders so active/inactive colors update without waiting for a layout pass.
    Task { await BorderController.shared.sync() }

    let winDesc = focus.windowOrNil.map { "\($0.windowId) \($0.app.rawAppBundleId ?? "?")" } ?? "nil"
    aeroLog("focus → \(winDesc) ws:\(focus.workspace.name)")

    // Update MRU zone history when a window in a zone gains focus (mouse, hotkey, or any path).
    if let window = focus.windowOrNil,
       let zoneContainer = window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer,
       let zoneName = focus.workspace.zoneContainers.first(where: { $0.value === zoneContainer })?.key
    {
        focus.workspace.mruZones.removeAll { $0 == zoneName }
        focus.workspace.mruZones.insert(zoneName, at: 0)
        if focus.workspace.mruZones.count > 10 { focus.workspace.mruZones.removeLast() }
    }

    let focusedZoneName: String? = focus.windowOrNil.flatMap { window in
        zoneName(for: window, in: focus.workspace)
    }
    if let window = focus.windowOrNil,
       let zone = focus.workspace.zoneContaining(window)?.container,
       zone.layout == .stack,
       focus.workspace.zoneLayoutProfileKey == MonitorProfile([focus.workspace.workspaceMonitor]).key {
        focus.workspace.rememberDockedZoneLayout()
    }
    broadcastEvent(.focusChanged(
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
        appName: focus.windowOrNil?.app.name,
        zoneName: focusedZoneName,
    ))
    broadcastZoneFocusedIfNeeded(workspace: focus.workspace, zoneName: focusedZoneName)
    return await config.onFocusChanged.run(env.withFocus(focus), io)
}

@MainActor
func broadcastZoneFocusedIfNeeded(workspace: Workspace, zoneName: String?) {
    let next = (workspace.name, zoneName)
    guard _lastBroadcastZoneFocus?.workspaceName != next.0 || _lastBroadcastZoneFocus?.zoneName != next.1 else { return }
    _lastBroadcastZoneFocus = next
    guard let zoneName else { return }
    broadcastEvent(.zoneFocused(workspace: workspace.name, zoneName: zoneName))
}

@MainActor private func onWorkspaceChanged(_ oldWorkspace: String, _ newWorkspace: String, _ focus: LiveFocus) {
    broadcastEvent(.workspaceChanged(
        workspace: newWorkspace,
        prevWorkspace: oldWorkspace,
    ))
    if let exec = config.execOnWorkspaceChange.first {
        let process = Process()
        process.executableURL = URL(filePath: exec)
        process.arguments = Array(config.execOnWorkspaceChange.dropFirst())
        var environment = config.execConfig.envVariables
        environment[AEROSPACE_FOCUSED_WORKSPACE] = newWorkspace
        environment[AEROSPACE_PREV_WORKSPACE] = oldWorkspace
        switch focus.asLeaf {
            case .emptyWorkspace(let w):
                environment[AEROSPACE_WORKSPACE] = w.name
                environment[AEROSPACE_WINDOW_ID] = nil
            case .window(let w):
                environment[AEROSPACE_WORKSPACE] = nil
                environment[AEROSPACE_WINDOW_ID] = w.windowId.description
        }
        process.environment = environment
        _ = Result { try process.run() }
    }
}
