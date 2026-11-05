import Common

private let presentationModePresetName = "presentation"

struct PresentationModeCommand: Command {
    let args: PresentationModeCmdArgs
    let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = focus.workspace
        let turnOn = switch args.action.val {
            case .on: true
            case .off: false
            case .toggle: workspace.presentationModeSnapshot == nil
        }
        return turnOn ? enablePresentationMode(on: workspace, monitor: workspace.workspaceMonitor, io) : disablePresentationMode(on: workspace, io)
    }
}

@MainActor
func enablePresentationMode(on workspace: Workspace, monitor: Monitor, _ io: CmdIo) -> BinaryExitCode {
    guard !workspace.zoneContainers.isEmpty else {
        return .fail(io.err("presentation-mode: zones not active on this workspace"))
    }
    if workspace.presentationModeSnapshot != nil {
        return .succ
    }

    let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
    let currentZoneNames = workspace.activeZoneDefinitions.map(\.id)
    let focusedWindow = focus.windowOrNil?.takeIf { $0.nodeWorkspace === workspace && !$0.isFloating }
    let mainWindow = focusedWindow ?? workspace.mostRecentWindowRecursive
    let mainZoneIndex = mainWindow
        .flatMap { workspace.zoneContaining($0)?.name }
        .flatMap { zoneName in currentZoneNames.firstIndex(of: zoneName) }
    let savedZoneWindowOrder = Dictionary(uniqueKeysWithValues: currentZoneNames.map { zoneName in
        (zoneName, workspace.zoneContainers[zoneName]?.allLeafWindowsRecursive.map(\.windowId) ?? [])
    })
    let savedAssignments = Dictionary(uniqueKeysWithValues: windows.map { window in
        (window.windowId, workspace.zoneContaining(window)?.name)
    })

    workspace.presentationModeSnapshot = Workspace.PresentationModeSnapshot(
        zoneDefinitions: workspace.currentLiveZoneDefinitions(),
        windowZoneAssignments: savedAssignments,
        zoneWindowOrder: savedZoneWindowOrder,
        focusedZone: workspace.focusedZone,
        savedZoneWeights: workspace.savedZoneWeights,
        focusModeZone: workspace.focusModeZone,
        previousActiveZonePresetName: activeZonePresetName,
    )

    let presentationDefs = presentationModeZoneDefinitions(for: monitor)
    activeZonePresetName = presentationModePresetName
    workspace.savedZoneWeights = nil
    workspace.focusModeZone = nil
    workspace.focusedZone = nil
    workspace.rebuildZoneContainers(
        for: monitor,
        zoneDefinitions: presentationDefs,
        saveZoneAssignments: false,
        shouldRestoreZoneMemory: false,
    )

    var leftCount = 0
    var rightCount = 0
    for window in windows {
        let zoneName: String
        if mainWindow === window {
            zoneName = "center"
        } else if let previousZone = savedAssignments[window.windowId].flatMap({ $0 }),
                  let previousIndex = currentZoneNames.firstIndex(of: previousZone),
                  let mainZoneIndex
        {
            if previousIndex < mainZoneIndex {
                zoneName = "left"
            } else if previousIndex > mainZoneIndex {
                zoneName = "right"
            } else if leftCount <= rightCount {
                zoneName = "left"
            } else {
                zoneName = "right"
            }
        } else if leftCount <= rightCount {
            zoneName = "left"
        } else {
            zoneName = "right"
        }

        if zoneName == "left" { leftCount += 1 }
        if zoneName == "right" { rightCount += 1 }
        let zone = workspace.zoneContainers[zoneName].orDie()
        window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    if let mainWindow {
        _ = mainWindow.focusWindow()
    } else {
        _ = workspace.focusWorkspace()
    }
    updateTrayText()
    broadcastEvent(.zonePresetChanged(workspace: workspace.name, presetName: presentationModePresetName))
    return .succ
}

@MainActor
func disablePresentationMode(on workspace: Workspace, _ io: CmdIo) -> BinaryExitCode {
    guard let snapshot = workspace.presentationModeSnapshot else {
        return .succ
    }

    let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
    let windowsById = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })
    let previouslyFocusedWindowId = focus.windowOrNil?.takeIf { $0.nodeWorkspace === workspace }?.windowId
    workspace.rebuildZoneContainers(
        for: workspace.workspaceMonitor,
        zoneDefinitions: snapshot.zoneDefinitions,
        saveZoneAssignments: false,
        shouldRestoreZoneMemory: false,
    )

    var restoredWindowIds: Set<UInt32> = []
    for zoneName in snapshot.zoneDefinitions.map(\.id) {
        guard let zone = workspace.zoneContainers[zoneName] else { continue }
        for windowId in snapshot.zoneWindowOrder[zoneName] ?? [] {
            guard let window = windowsById[windowId] else { continue }
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            restoredWindowIds.insert(windowId)
        }
    }

    for window in windows where !restoredWindowIds.contains(window.windowId) {
        if let previousZone = snapshot.windowZoneAssignments[window.windowId].flatMap({ $0 }),
           let zone = workspace.zoneContainers[previousZone]
        {
            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        } else {
            let decision = resolveNewTilingWindowPlacement(in: workspace, appBundleId: window.app.rawAppBundleId)
            let binding = decision.bindingData
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
        }
    }

    activeZonePresetName = snapshot.previousActiveZonePresetName
    workspace.focusedZone = snapshot.focusedZone
    workspace.savedZoneWeights = snapshot.savedZoneWeights
    workspace.focusModeZone = snapshot.focusModeZone
    workspace.reapplyZoneFocusModeIfNeeded()
    workspace.presentationModeSnapshot = nil

    if let previouslyFocusedWindowId, let focusedWindow = Window.get(byId: previouslyFocusedWindowId) {
        _ = focusedWindow.focusWindow()
    } else {
        _ = workspace.focusWorkspace()
    }
    updateTrayText()
    broadcastEvent(.zonePresetChanged(workspace: workspace.name, presetName: activeZonePresetName))
    return .succ
}

@MainActor
func presentationModeZoneDefinitions(for monitor: Monitor) -> [ZoneDefinition] {
    let monitorRect = monitor.visibleRect
    let centerWidth = min(monitorRect.width, monitorRect.height * 16.0 / 9.0)
    let sideWidth = max(0, (monitorRect.width - centerWidth) / 2.0)
    let total = max(monitorRect.width, 1)
    return [
        ZoneDefinition(id: "left", width: sideWidth / total, layout: .stack),
        ZoneDefinition(id: "center", width: centerWidth / total, layout: .tiles),
        ZoneDefinition(id: "right", width: sideWidth / total, layout: .stack),
    ]
}
