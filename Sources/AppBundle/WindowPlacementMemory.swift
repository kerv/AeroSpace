import Foundation

/// Remembers explicit tile arrangements separately from the legacy app-to-zone memory.
/// Titles are used to disambiguate windows of the same app; a unique app entry is a fallback.
final class WindowPlacementMemory {
    @MainActor static var shared = WindowPlacementMemory()

    struct Placement: Codable, Equatable {
        var workspace: String
        var zone: String
        var order: Int
    }
    struct Entry: Codable, Equatable {
        var appId: String
        var title: String
        var profile: String
        var lastWorkspace: String
        var placements: [String: Placement]
    }

    private(set) var entries: [Entry]
    let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AeroSpace/window-placement-memory.json")
        if let bytes = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: bytes) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func find(appId: String, title: String, profile: String) -> Entry? {
        let candidates = entries.filter { $0.appId == appId && $0.profile == profile }
        if !title.isEmpty, let exact = candidates.first(where: { $0.title == title }) { return exact }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func remember(appId: String, title: String, profile: String, placement: Placement, makeCurrent: Bool) {
        guard !appId.isEmpty else { return }
        let existing = entries.firstIndex { $0.appId == appId && $0.title == title && $0.profile == profile }
        let index: Int
        if let existing { index = existing } else {
            entries.append(Entry(appId: appId, title: title, profile: profile, lastWorkspace: placement.workspace, placements: [:]))
            index = entries.count - 1
        }
        entries[index].placements[placement.workspace] = placement
        if makeCurrent { entries[index].lastWorkspace = placement.workspace }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}

@MainActor
func rememberWindowPlacement(_ window: Window, makeCurrent: Bool = true) {
    guard let appId = window.app.rawAppBundleId,
          let workspace = window.nodeWorkspace, !workspace.isScratchpad,
          let (zoneName, zone) = workspace.zoneContaining(window),
          let index = zone.allLeafWindowsRecursive.firstIndex(where: { $0 === window }) else { return }
    // Identical or missing titles cannot distinguish multiple windows of the same app.
    let ambiguous = Workspace.all.flatMap { $0.rootTilingContainer.allLeafWindowsRecursive }.contains { other in
        guard other !== window, other.app.rawAppBundleId == appId else { return false }
        return window.placementIdentityTitle.isEmpty || other.placementIdentityTitle == window.placementIdentityTitle
    }
    guard !ambiguous else { return }
    let placement = WindowPlacementMemory.Placement(workspace: workspace.name, zone: zoneName, order: index)
    WindowPlacementMemory.shared.remember(appId: appId, title: window.placementIdentityTitle,
        profile: MonitorProfile(monitors).key, placement: placement, makeCurrent: makeCurrent)
}

@MainActor
func matchingPlacementEntry(for window: Window, profile: String) -> WindowPlacementMemory.Entry? {
    guard let appId = window.app.rawAppBundleId,
          let entry = WindowPlacementMemory.shared.find(appId: appId, title: window.placementIdentityTitle, profile: profile) else { return nil }
    let peers = Workspace.all.flatMap { $0.rootTilingContainer.allLeafWindowsRecursive }.filter {
        $0 !== window && $0.app.rawAppBundleId == appId
    }
    if peers.contains(where: { $0.placementIdentityTitle == window.placementIdentityTitle }) { return nil }
    if entry.title != window.placementIdentityTitle && !peers.isEmpty { return nil }
    return entry
}

@MainActor
func rememberZoneArrangement(in workspace: Workspace) {
    for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
        rememberWindowPlacement(window)
    }
}

@MainActor
func rememberedBinding(for window: Window, in workspace: Workspace) -> BindingData? {
    guard let entry = matchingPlacementEntry(for: window, profile: MonitorProfile(monitors).key),
          let placement = entry.placements[workspace.name],
          let zone = workspace.zoneContainers[placement.zone] else { return nil }
    let profile = MonitorProfile(monitors).key
    let laterKnownIndex = zone.children.firstIndex { child in
        guard let other = child as? Window, other !== window,
              let otherEntry = matchingPlacementEntry(for: other, profile: profile),
              let otherPlacement = otherEntry.placements[workspace.name], otherPlacement.zone == placement.zone else { return false }
        return otherPlacement.order > placement.order
    }
    var index = laterKnownIndex ?? min(max(0, placement.order), zone.children.count)
    if window.parent === zone, let oldIndex = window.ownIndex, oldIndex < index { index += 1 }
    return BindingData(parent: zone, adaptiveWeight: WEIGHT_AUTO, index: min(index, zone.children.count))
}
