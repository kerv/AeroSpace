import Common

enum WindowTilingPlacementSource: String {
    case appRouting
    case zoneMemory
    case startupRect
    case focusedZoneHint
    case mruZone
    case mruContainer
    case middleZoneFallback
    case rootFallback
}

struct WindowTilingPlacementDecision {
    let source: WindowTilingPlacementSource
    let zoneName: String?
    let bindingData: BindingData
}

@MainActor
func resolveNewTilingWindowPlacement(
    in workspace: Workspace,
    appBundleId: String?,
    startupRect: Rect? = nil
) -> WindowTilingPlacementDecision {
    if let appBundleId,
       let zoneName = config.zones.appRouting[appBundleId],
       let decision = workspace.resolveExplicitZonePlacement(zoneName: zoneName, source: .appRouting)
    {
        aeroLog("window placement: app-routing matched \(appBundleId) -> \(zoneName)")
        return decision
    }
    if let appBundleId,
       let profile = workspace.activeZoneProfile,
       let zoneName = ZoneMemory.shared.rememberedZone(forBundleId: appBundleId, profile: profile),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .zoneMemory)
    {
        aeroLog("window placement: zone-memory matched \(appBundleId) -> \(zoneName)")
        return decision
    }
    if let startupRect, !workspace.zoneContainers.isEmpty,
       let zoneName = workspace.zoneForWindowRect(startupRect),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .startupRect)
    {
        return decision
    }
    if let hintZone = workspace.focusedZone {
        if let decision = workspace.resolveExplicitZonePlacement(zoneName: hintZone, source: .focusedZoneHint) {
            workspace.focusedZone = nil
            return decision
        }
        workspace.focusedZone = nil
    }
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let (zoneName, _) = workspace.zoneContaining(mruWindow),
       let decision = workspace.resolveZonePlacement(preferredZoneName: zoneName, source: .mruZone)
    {
        return decision
    }
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return WindowTilingPlacementDecision(
            source: .mruContainer,
            zoneName: nil,
            bindingData: BindingData(
                parent: tilingParent,
                adaptiveWeight: WEIGHT_AUTO,
                index: mruWindow.ownIndex.orDie() + 1
            )
        )
    }
    if let decision = workspace.resolveZonePlacement(
        preferredZoneName: workspace.activeZoneDefinitions[safe: workspace.activeZoneDefinitions.count / 2]?.id,
        source: .middleZoneFallback
    ) {
        return decision
    }
    return WindowTilingPlacementDecision(
        source: .rootFallback,
        zoneName: nil,
        bindingData: BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    )
}

@MainActor
func applyRuntimePlacementDefaults(_ window: Window) {
    guard let workspace = window.nodeWorkspace else { return }

    if !window.isFloating,
       FloatingMemory.shared.isRemembered(windowId: window.windowId)
    {
        window.bindAsFloatingWindow(to: workspace)
    }

    if !window.isFloating,
       let bundleId = window.app.rawAppBundleId,
       config.floating.appIds.contains(bundleId)
    {
        window.bindAsFloatingWindow(to: workspace)
    }

    if StickyMemory.shared.isRemembered(windowId: window.windowId) {
        window.bindAsFloatingWindow(to: focus.workspace)
    }

    if ScratchpadMemory.shared.isRemembered(windowId: window.windowId),
       window.nodeWorkspace != Workspace.scratchpad
    {
        window.bindAsFloatingWindow(to: Workspace.scratchpad)
    }
}

extension Workspace {
    @MainActor
    func resolveZonePlacement(
        preferredZoneName: String?,
        source: WindowTilingPlacementSource
    ) -> WindowTilingPlacementDecision? {
        if let preferredZoneName,
           let decision = resolveExplicitZonePlacement(zoneName: preferredZoneName, source: source)
        {
            return decision
        }
        guard let middleZoneName = activeZoneDefinitions[safe: activeZoneDefinitions.count / 2]?.id else { return nil }
        return resolveExplicitZonePlacement(zoneName: middleZoneName, source: .middleZoneFallback)
    }

    @MainActor
    func resolveExplicitZonePlacement(
        zoneName: String,
        source: WindowTilingPlacementSource
    ) -> WindowTilingPlacementDecision? {
        guard let zone = zoneContainers[zoneName] else { return nil }
        return WindowTilingPlacementDecision(
            source: source,
            zoneName: zoneName,
            bindingData: bindingDataForNewWindow(inZone: zoneName, zone: zone)
        )
    }
}

@MainActor
func recordPlacement(_ decision: WindowTilingPlacementDecision, for window: Window) {
    window.lastPlacementRecord = WindowPlacementRecord(source: decision.source, zoneName: decision.zoneName)
}

@MainActor
func broadcastWindowRouted(_ decision: WindowTilingPlacementDecision, for window: Window) {
    guard let zoneName = decision.zoneName else { return }
    broadcastEvent(.windowRouted(
        windowId: window.windowId,
        workspace: decision.bindingData.parent.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        zoneName: zoneName,
        source: decision.source.rawValue
    ))
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
