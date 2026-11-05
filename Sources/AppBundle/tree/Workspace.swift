import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [CGPoint: String] = [:]
/// Snapshot of monitor entries from the previous rearrangeWorkspacesOnMonitors call.
/// Used to detect monitor topology changes (connect/disconnect/rearrange) for on-monitor-changed rules.
@MainActor private var previousMonitorEntries: [MonitorProfile.MonitorEntry] = []
/// Snapshot of screen origin points from the previous rearrangeWorkspacesOnMonitors call.
/// Used to detect monitor rearrangements (same monitors, different positions).
@MainActor private var previousScreenPoints: Set<CGPoint> = []
@MainActor private var previousScreenProfiles: [CGPoint: MonitorProfile.MonitorEntry] = [:]
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

@MainActor func resetMonitorTrackingForTests() {
    check(isUnitTest)
    previousMonitorEntries = []
    previousScreenPoints = []
    previousScreenProfiles = [:]
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]
    screenPointToPrevVisibleWorkspace = [:]
}

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    getStubWorkspace(forPoint: monitor.rect.topLeftCorner)
}

@MainActor
private func getStubWorkspace(forPoint point: CGPoint) -> Workspace {
    if let prev = screenPointToPrevVisibleWorkspace[point].map({ Workspace.get(byName: $0) }),
       !prev.isScratchpad && !prev.isVisible && prev.workspaceMonitor.rect.topLeftCorner == point && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isScratchpad && !$0.isVisible && $0.workspaceMonitor.rect.topLeftCorner == point })
    {
        return candidate
    }
    // Reuse an empty configured workspace before inventing workspace 10 or higher.
    if let configured = config.persistentWorkspaces.lazy.map({ Workspace.get(byName: $0) })
        .first(where: { !$0.isScratchpad && !$0.isVisible && $0.isEffectivelyEmpty && $0.forceAssignedMonitor == nil }) {
        return configured
    }
    return (1 ... Int.max).lazy
        .map { Workspace.get(byName: String($0)) }
        .first { $0.isEffectivelyEmpty && !$0.isVisible && !config.persistentWorkspaces.contains($0.name) && $0.forceAssignedMonitor == nil }
        .orDie("Can't create empty workspace")
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    /// The reserved name for the hidden scratchpad workspace.
    static let scratchpadName = "__scratchpad__"

    /// The global scratchpad workspace. Created on first access.
    @MainActor static var scratchpad: Workspace { Workspace.get(byName: scratchpadName) }

    /// True for the internal scratchpad workspace, which is never shown on any monitor.
    var isScratchpad: Bool { name == Workspace.scratchpadName }

    let name: String
    nonisolated private let nameLogicalSegments: StringLogicalSegments
    /// `assignedMonitorPoint` must be interpreted only when the workspace is invisible
    fileprivate var assignedMonitorPoint: CGPoint? = nil
    /// Active zone containers keyed by name ("left", "center", "right"). Empty when zones are inactive.
    var zoneContainers: [String: TilingContainer] = [:]
    /// Monitor profile that was active when zones were last activated. Used to save zone memory on deactivation.
    var activeZoneProfile: MonitorProfile? = nil
    var zoneLayoutProfileKey: String? = nil
    /// Root container orientation saved before zone activation, restored when zones are deactivated.
    var savedRootOrientation: Orientation? = nil
    /// One-shot hint: place the next new tiling window in this zone, then clear. Set by focus-zone on an empty zone.
    var focusedZone: String? = nil
    /// MRU zone history for this workspace (most-recent-first). In-memory only; resets on restart.
    var mruZones: [String] = []
    /// Saved zone weights captured when zone-focus-mode was activated. nil when focus mode is off.
    var savedZoneWeights: [String: CGFloat]? = nil
    /// Name of the currently focused zone when zone focus mode is active. nil when focus mode is off.
    var focusModeZone: String? = nil
    /// Non-nil while presentation mode is temporarily overriding this workspace's zone topology.
    var presentationModeSnapshot: PresentationModeSnapshot? = nil
    /// Ordered zone definitions that were active when zones were last activated. Drives deactivation
    /// and geometry helpers so they work for any N-zone layout, not just the hardcoded 3.
    var activeZoneDefinitions: [ZoneDefinition] = []

    @MainActor
    private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    @MainActor static var all: [Workspace] {
        workspaceNameToWorkspace.values.sorted()
    }

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            workspaceNameToWorkspace[name] = workspace
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        workspaceMonitor.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            workspace.isScratchpad || // always keep the scratchpad workspace
                config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorPoint?.monitorApproximation
            ?? mainMonitor
    }
}

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = screenPointToVisibleWorkspace[rect.topLeftCorner] {
            return existing
        }
        // What if monitor configuration changed? (frame.origin is changed)
        rearrangeWorkspacesOnMonitors()
        // Normally, recursion should happen only once more because we must take the value from the cache
        // (Unless, monitor configuration data race happens)
        return self.activeWorkspace
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

@MainActor
func gcMonitors() {
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    var prevCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in previousMonitorEntries { prevCounts[e, default: 0] += 1 }
    var currCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in currentEntries { currCounts[e, default: 0] += 1 }
    // Also check resolution profile, not just count: disconnecting the ultrawide while asleep and
    // waking on the laptop screen keeps count at 1 but switches resolution, and without this check
    // rearrangeWorkspacesOnMonitors() would never run so on-monitor-changed never fires.
    if screenPointToVisibleWorkspace.count != monitors.count || currCounts != prevCounts {
        rearrangeWorkspacesOnMonitors()
    }
    for (point, workspace) in screenPointToVisibleWorkspace {
        workspace.ensureZoneContainers(for: point.monitorApproximation)
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToPrevVisibleWorkspace[prevMonitorPoint] =
                screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPoint)?.name
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[self] {
            screenPointToPrevVisibleWorkspace[self] =
                screenPointToVisibleWorkspace.removeValue(forKey: self)?.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[self] = workspace
        workspace.assignedMonitorPoint = self
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors() {
    // Capture current monitor entries BEFORE reassigning to detect newly-connected monitors.
    let currentEntries = monitors.map { MonitorProfile.MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
    // Use multiset comparison so that a second identical monitor (same resolution) is treated as
    // newly added even though an entry with that resolution already existed in previousMonitorEntries.
    var prevCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in previousMonitorEntries { prevCounts[e, default: 0] += 1 }
    var currCounts: [MonitorProfile.MonitorEntry: Int] = [:]
    for e in currentEntries { currCounts[e, default: 0] += 1 }
    // One entry per surplus instance (e.g. 2 identical monitors where 1 was known → one newly-added entry).
    var newlyAdded: [MonitorProfile.MonitorEntry] = []
    for (entry, currCount) in currCounts {
        let surplus = currCount - (prevCounts[entry] ?? 0)
        if surplus > 0 { newlyAdded.append(contentsOf: Array(repeating: entry, count: surplus)) }
    }

    // Record the workspace on a disappearing ultrawide before changing screen mappings.
    for (point, entry) in previousScreenProfiles where entry.height > 0 && entry.width / entry.height > 2.1 {
        if (prevCounts[entry] ?? 0) > (currCounts[entry] ?? 0),
           let workspace = screenPointToVisibleWorkspace[point] {
            let key = MonitorProfile(entries: [entry]).key
            DockedMonitorWorkspaceMemory.shared.remember(workspace: workspace.name, profile: key)
        }
    }
    let currentScreenProfiles = Dictionary(uniqueKeysWithValues: monitors.map { monitor in
        (monitor.rect.topLeftCorner, MonitorProfile.MonitorEntry(width: monitor.rect.width, height: monitor.rect.height))
    })
    let newScreens = monitors.map(\.rect.topLeftCorner)
    var newScreenToOldScreenMapping: [CGPoint: CGPoint] = [:]
    for (oldScreen, _) in screenPointToVisibleWorkspace {
        guard let newScreen = newScreens.minBy({ ($0 - oldScreen).vectorLength }) else { continue }
        if let prevOldScreen = newScreenToOldScreenMapping[newScreen] {
            if (prevOldScreen - newScreen).vectorLength <= (oldScreen - newScreen).vectorLength {
                // newScreen has already been assigned to a closer oldScreen.
                continue
            }
        }
        newScreenToOldScreenMapping[newScreen] = oldScreen
    }

    let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]

    for newScreen in newScreens {
        if let existingVisibleWorkspace = newScreenToOldScreenMapping[newScreen].flatMap({ oldScreenPointToVisibleWorkspace[$0] }),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            continue
        }
        // A reconnected ultrawide gets back the workspace it showed before disconnection.
        if let entry = currentScreenProfiles[newScreen], newlyAdded.contains(entry),
           entry.height > 0, entry.width / entry.height > 2.1,
           let name = DockedMonitorWorkspaceMemory.shared.workspace(for: MonitorProfile(entries: [entry]).key),
           name != Workspace.scratchpadName,
           newScreen.setActiveWorkspace(Workspace.get(byName: name)) {
            continue
        }
        let stubWorkspace = getStubWorkspace(forPoint: newScreen)
        check(newScreen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(newScreen)")
    }

    // Moving a remembered workspace to the reconnected screen can vacate another screen.
    for point in newScreens where screenPointToVisibleWorkspace[point] == nil {
        let stub = getStubWorkspace(forPoint: point)
        check(point.setActiveWorkspace(stub), "Could not select a workspace for a connected monitor")
    }
    for (point, workspace) in screenPointToVisibleWorkspace {
        workspace.ensureZoneContainers(for: point.monitorApproximation)
    }

    // Update previousMonitorEntries for next call.
    previousMonitorEntries = currentEntries
    previousScreenProfiles = currentScreenProfiles

    // Detect removed monitors (entries in prev that are surplus relative to current).
    // Build the removed list for aspect-ratio matching, not just a boolean.
    var removedEntries: [MonitorProfile.MonitorEntry] = []
    for (entry, prevCount) in prevCounts {
        let surplus = prevCount - (currCounts[entry] ?? 0)
        if surplus > 0 { removedEntries.append(contentsOf: Array(repeating: entry, count: surplus)) }
    }
    let removedAny = !removedEntries.isEmpty

    // Detect monitor rearrangements: same monitor count and resolutions, but different screen origins.
    let positionsChanged = !previousScreenPoints.isEmpty && Set(newScreens) != previousScreenPoints
    previousScreenPoints = Set(newScreens)

    aeroLog("monitors: \(monitors.count) screens, newly-added: \(newlyAdded.count), removed: \(removedAny), rearranged: \(positionsChanged)")
    for (point, ws) in screenPointToVisibleWorkspace {
        aeroLog("  screen \(point) → ws:\(ws.name)")
    }

    // Fire on-monitor-changed rules on any topology change (skip during startup).
    // Deferred via Task so commands run after the current refresh session has fully committed its
    // tree state — avoids bind() calls re-entering an in-progress layout pass.
    if !isStartup && (!newlyAdded.isEmpty || removedAny || positionsChanged) {
        broadcastEvent(.monitorChanged(monitorCount: monitors.count))

        // For add/remove: only filter by the aspect ratios of changed monitors so that connecting
        // an unrelated small monitor does not trigger ultrawide-targeted rules (Bug 28).
        // For pure rearrangement: all current monitors are involved, so use current aspect ratios.
        let changedAspectRatios: [CGFloat]
        if !newlyAdded.isEmpty || removedAny {
            changedAspectRatios = (newlyAdded + removedEntries).map { $0.width / $0.height }
        } else {
            changedAspectRatios = monitors.map { $0.rect.width / $0.rect.height }
        }
        let rulesToFire = config.onMonitorChanged.filter { callback in
            guard let minRatio = callback.matcher.anyMonitorMinAspectRatio else { return true }
            return changedAspectRatios.contains { $0 >= minRatio }
        }
        if !rulesToFire.isEmpty {
            Task { @MainActor in
                for rule in rulesToFire {
                    _ = await rule.run.run(.defaultEnv, .emptyStdin)
                }
            }
        }
        // Apply [[monitor-profiles]] automation. Deferred in the same Task to run after the
        // current layout pass completes and after on-monitor-changed commands have been queued.
        Task { @MainActor in
            applyMatchingMonitorProfile()
        }
    }
}

@MainActor
private func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    switch workspace.forceAssignedMonitor {
        case let forceAssigned? where forceAssigned.rect.topLeftCorner != screen: false
        default: true
    }
}

extension Workspace {
    struct PresentationModeSnapshot {
        let zoneDefinitions: [ZoneDefinition]
        let windowZoneAssignments: [UInt32: String?]
        let zoneWindowOrder: [String: [UInt32]]
        let focusedZone: String?
        let savedZoneWeights: [String: CGFloat]?
        let focusModeZone: String?
        let previousActiveZonePresetName: String?
    }

    @MainActor
    func currentLiveZoneDefinitions() -> [ZoneDefinition] {
        let defs = activeZoneDefinitions
        guard !defs.isEmpty else { return config.zones.zones }
        let saved = savedZoneWeights
        var raw: [(id: String, weight: CGFloat, layout: Layout)] = []
        for def in defs {
            let container = zoneContainers[def.id]
            let weight = saved?[def.id] ?? container?.getWeight(.h) ?? CGFloat(def.width)
            let layout = container?.layout ?? def.layout
            raw.append((def.id, weight, layout))
        }
        let total = raw.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return config.zones.zones }
        return raw.map { ZoneDefinition(id: $0.id, width: Double($0.weight / total), layout: $0.layout) }
    }

    @MainActor
    func reapplyZoneFocusModeIfNeeded() {
        guard let saved = savedZoneWeights, let focusModeZone else { return }
        guard zoneContainers[focusModeZone] != nil else {
            savedZoneWeights = nil
            self.focusModeZone = nil
            return
        }
        let nonFocusedCount = CGFloat(activeZoneDefinitions.count - 1)
        let totalWeight = saved.values.compactMap { $0 }.reduce(0, +)
        guard totalWeight > 0 else { return }
        for def in activeZoneDefinitions {
            guard let container = zoneContainers[def.id] else { continue }
            if def.id == focusModeZone {
                let focusedWeight = max(0, totalWeight - CGFloat(config.zones.focusModeCollapsedWidth) * max(0, nonFocusedCount))
                container.setWeight(.h, focusedWeight)
            } else {
                container.setWeight(.h, CGFloat(config.zones.focusModeCollapsedWidth))
            }
        }
    }

    @MainActor
    func zoneContaining(_ window: Window) -> (name: String, container: TilingContainer)? {
        let zoneContainer = window.parents
            .first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
        guard let zoneContainer else { return nil }
        guard let zoneName = zoneContainers.first(where: { $0.value === zoneContainer })?.key else { return nil }
        return (zoneName, zoneContainer)
    }

    @MainActor
    func newWindowInsertionPolicy(for zoneName: String) -> ZoneNewWindowPolicy {
        config.zones.behavior[zoneName]?.newWindow ?? .afterFocused
    }

    @MainActor
    func bindingDataForNewWindow(inZone zoneName: String, zone: TilingContainer) -> BindingData {
        switch newWindowInsertionPolicy(for: zoneName) {
            case .append:
                return BindingData(parent: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .afterFocused:
                if let zoneWindow = zone.mostRecentWindowRecursive,
                   let parent = zoneWindow.parent as? TilingContainer
                {
                    return BindingData(
                        parent: parent,
                        adaptiveWeight: WEIGHT_AUTO,
                        index: zoneWindow.ownIndex.orDie() + 1,
                    )
                }
                return BindingData(parent: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .appendHidden:
                let preservedMru = zone.layout == .stack ? zone.mostRecentChild : nil
                return BindingData(
                    parent: zone,
                    adaptiveWeight: WEIGHT_AUTO,
                    index: INDEX_BIND_LAST,
                    preferredMostRecentChildAfterBind: preservedMru,
                )
        }
    }

    @MainActor
    func ensureZoneContainers(for monitor: Monitor, force: Bool = false) {
        // zonesDisabledByProfile overrides the ultrawide trigger: a monitor-profile rule with
        // `apply-zone-layout = "disabled"` can suppress zones even on an ultrawide monitor.
        let shouldHaveZones = monitor.isUltrawide && !zonesDisabledByProfile
        if shouldHaveZones && zoneContainers.isEmpty {
            activateZones(monitor: monitor, restoreRememberedLayout: true)
        } else if shouldHaveZones && !zoneContainers.isEmpty && force {
            // Config reload or preset change: tear down and rebuild so updated widths/layouts take effect.
            // deactivateZones auto-saves current assignments; activateZones restores them.
            if presentationModeSnapshot != nil {
                rebuildZoneContainers(
                    for: monitor,
                    zoneDefinitions: activeZoneDefinitions,
                    saveZoneAssignments: false,
                    shouldRestoreZoneMemory: false,
                )
            } else {
                rebuildZoneContainers(for: monitor, zoneDefinitions: config.zones.zones)
            }
        } else if !shouldHaveZones && !zoneContainers.isEmpty {
            if let snapshot = presentationModeSnapshot {
                activeZonePresetName = snapshot.previousActiveZonePresetName
                presentationModeSnapshot = nil
                deactivateZones(saveAssignments: false)
            } else {
                deactivateZones()
            }
        }
    }

    @MainActor
    func rebuildZoneContainers(
        for monitor: Monitor,
        zoneDefinitions: [ZoneDefinition],
        saveZoneAssignments: Bool = true,
        shouldRestoreZoneMemory: Bool = true
    ) {
        if !zoneContainers.isEmpty {
            deactivateZones(saveAssignments: saveZoneAssignments)
        }
        activateZones(
            monitor: monitor,
            zoneDefinitions: zoneDefinitions,
            restoreRememberedLayout: false,
            shouldRestoreZoneMemory: shouldRestoreZoneMemory,
        )
    }

    @MainActor
    private func activateZones(
        monitor: Monitor,
        zoneDefinitions: [ZoneDefinition] = config.zones.zones,
        restoreRememberedLayout: Bool,
        shouldRestoreZoneMemory: Bool = true
    ) {
        let monitorWidth = monitor.visibleRect.width
        aeroLog("activateZones: ws:\(name) monitorWidth=\(monitorWidth)")
        zoneLayoutProfileKey = MonitorProfile([monitor]).key
        let remembered = restoreRememberedLayout ? zoneLayoutProfileKey.flatMap {
            DockedZoneLayoutMemory.shared.snapshot(workspace: name, profile: $0)
        } : nil
        let compatible = remembered.flatMap { snapshot in
            snapshot.zones.map(\.id) == zoneDefinitions.map(\.id) &&
                snapshot.zones.allSatisfy { $0.width.isFinite && $0.width > 0 && Layout(rawValue: $0.layout) != nil }
                ? snapshot : nil
        }
        activeZoneProfile = MonitorProfile([workspaceMonitor])
        activeZoneDefinitions = zoneDefinitions
        savedRootOrientation = rootTilingContainer.orientation
        rootTilingContainer.changeOrientation(.h)
        rootTilingContainer.layout = .tiles
        for def in activeZoneDefinitions {
            let saved = compatible?.zones.first(where: { $0.id == def.id })
            let container = TilingContainer(
                parent: rootTilingContainer,
                adaptiveWeight: monitorWidth * (saved?.width ?? def.width),
                saved.map { $0.horizontal ? .h : .v } ?? .h,
                saved.flatMap { Layout(rawValue: $0.layout) } ?? def.layout,
                index: INDEX_BIND_LAST,
            )
            container.isZoneContainer = true
            zoneContainers[def.id] = container
        }
        if shouldRestoreZoneMemory {
            restoreZoneMemory()
        }
        if let compatible { restoreDockedZoneWindows(compatible) }
    }

    @MainActor
    func restoreZoneMemory() {
        let profile = MonitorProfile([workspaceMonitor])
        let defs = activeZoneDefinitions
        // Fallback destination for windows whose remembered zone ID no longer exists in the active
        // layout. Using the middle zone keeps them inside the zone model rather than leaving them
        // as root tiling children that are invisible to zone-aware surfaces (list-zones, zone counts, etc.)
        let fallbackZone: TilingContainer? = defs.isEmpty ? nil : zoneContainers[defs[defs.count / 2].id]
        let windows = rootTilingContainer.allLeafWindowsRecursive
        for window in windows {
            guard let zoneName = ZoneMemory.shared.rememberedZone(for: window, profile: profile) else { continue }
            if zoneContainers[zoneName] != nil || fallbackZone != nil {
                let targetZoneName = zoneContainers[zoneName] != nil ? zoneName : defs[defs.count / 2].id
                aeroLog("restoreZoneMemory: \(window.app.rawAppBundleId ?? "?") -> \(targetZoneName)")
                let decision = resolveExplicitZonePlacement(zoneName: targetZoneName, source: .zoneMemory).orDie()
                let binding = decision.bindingData
                window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
                binding.preferredMostRecentChildAfterBind?.markAsMostRecentChild()
                recordPlacement(decision, for: window)
                broadcastWindowRouted(decision, for: window)
            }
        }
    }

    @MainActor
    private func deactivateZones(saveAssignments: Bool = true) {
        aeroLog("deactivateZones: called for ws:\(name), zoneContainers=\(zoneContainers.keys.sorted())")
        if zoneLayoutProfileKey == MonitorProfile([workspaceMonitor]).key {
            rememberDockedZoneLayout()
        }
        // Auto-save zone assignments so sleep/wake and reconnect cycles can restore them.
        if saveAssignments, let profile = activeZoneProfile {
            for zoneName in activeZoneDefinitions.map(\.id) {
                guard let zone = zoneContainers[zoneName] else { continue }
                for window in zone.allLeafWindowsRecursive {
                    ZoneMemory.shared.rememberZone(zoneName, for: window, profile: profile)
                }
            }
        }
        activeZoneProfile = nil
        zoneLayoutProfileKey = nil
        let orderedZoneNames = activeZoneDefinitions.map(\.id)
        activeZoneDefinitions = []
        for zoneName in orderedZoneNames {
            guard let zone = zoneContainers[zoneName] else { continue }
            for child in zone.children {
                child.bind(to: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
            zone.unbindFromParent()
        }
        zoneContainers = [:]
        rootTilingContainer.layout = config.defaultRootContainerLayout
        if let saved = savedRootOrientation {
            rootTilingContainer.changeOrientation(saved)
            savedRootOrientation = nil
        }
    }

    /// Returns the theoretical physical rect for the named zone, computed from adaptive weights
    /// and the monitor's visible rect. Used when `lastAppliedLayoutPhysicalRect` is not yet set
    /// (e.g. the workspace has never been visible). Returns nil if zones are not active or the
    /// named zone does not exist.
    /// When zone-focus-mode is active, uses the saved (pre-collapse) weights so the rects
    /// reflect actual zone proportions rather than the 8px collapsed slivers.
    @MainActor
    func theoreticalZoneRect(for zoneName: String) -> Rect? {
        let containers = activeZoneDefinitions.compactMap { def in zoneContainers[def.id].map { (def.id, $0) } }
        guard !containers.isEmpty else { return nil }
        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, c in
            saved?[name] ?? c.getWeight(.h)
        }
        let totalWeight = containers.reduce(0.0) { $0 + effectiveWeight($1.0, $1.1) }
        guard totalWeight > 0 else { return nil }
        var xOffset = monitorRect.minX
        for (name, container) in containers {
            let zoneWidth = monitorRect.width * (effectiveWeight(name, container) / totalWeight)
            if name == zoneName {
                return Rect(topLeftX: xOffset, topLeftY: monitorRect.topLeftY, width: zoneWidth, height: monitorRect.height)
            }
            xOffset += zoneWidth
        }
        return nil
    }

    /// Returns the zone name whose horizontal slice contains >50% of the window's area,
    /// or nil if no zone clears that threshold. On an exact tie, returns the leftmost zone.
    /// When zone-focus-mode is active, uses saved weights so overlap is computed against
    /// real proportions, not collapsed slivers.
    @MainActor
    func zoneForWindowRect(_ windowRect: Rect) -> String? {
        let containers = activeZoneDefinitions.compactMap { def in zoneContainers[def.id].map { (def.id, $0) } }
        guard !containers.isEmpty else { return nil }

        let monitorRect = workspaceMonitor.visibleRect
        let effectiveWeight: (String, TilingContainer) -> CGFloat = { [saved = savedZoneWeights] name, c in
            saved?[name] ?? c.getWeight(.h)
        }
        let totalWeight = containers.reduce(0.0) { $0 + effectiveWeight($1.0, $1.1) }
        guard totalWeight > 0 else { return nil }

        var xOffset: CGFloat = monitorRect.minX
        var bestZone: String? = nil
        var bestOverlapArea: CGFloat = -1

        for (name, container) in containers {
            let zoneWidth: CGFloat = monitorRect.width * (effectiveWeight(name, container) / totalWeight)
            let overlapMinX: CGFloat = max(windowRect.minX, xOffset)
            let overlapMaxX: CGFloat = min(windowRect.maxX, xOffset + zoneWidth)
            if overlapMaxX > overlapMinX {
                let overlapArea: CGFloat = (overlapMaxX - overlapMinX) * windowRect.height
                if overlapArea > bestOverlapArea {
                    bestOverlapArea = overlapArea
                    bestZone = name
                }
                // Ties keep the leftmost (already the case since we iterate left→right)
            }
            xOffset += zoneWidth
        }

        let windowArea: CGFloat = windowRect.width * windowRect.height
        guard windowArea > 0, let bestZone, bestOverlapArea / windowArea > 0.5 else { return nil }
        return bestZone
    }
}
