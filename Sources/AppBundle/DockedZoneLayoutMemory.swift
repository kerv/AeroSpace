import Foundation
import Common

/// Saves a workspace's ultrawide zone geometry and stack state independently for each monitor.
final class DockedZoneLayoutMemory {
    @MainActor static var shared = DockedZoneLayoutMemory()

    struct SavedWindow: Codable, Equatable {
        var id: UInt32
        var appId: String?
        var title: String
        var weight: Double?
    }
    struct SavedZone: Codable, Equatable {
        var id: String
        var width: Double
        var layout: String
        var horizontal: Bool
        var activeWindowId: UInt32?
        var windows: [SavedWindow]
    }
    struct Snapshot: Codable, Equatable {
        var zones: [SavedZone]
    }

    private var data: [String: [String: Snapshot]]
    let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AeroSpace/docked-zone-layouts.json")
        if let bytes = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([String: [String: Snapshot]].self, from: bytes) {
            data = decoded
        } else { data = [:] }
    }

    func snapshot(workspace: String, profile: String) -> Snapshot? { data[workspace]?[profile] }

    func save(_ snapshot: Snapshot, workspace: String, profile: String) {
        guard data[workspace]?[profile] != snapshot else { return }
        data[workspace, default: [:]][profile] = snapshot
        guard let bytes = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: storageURL, options: .atomic)
    }
}

extension Workspace {
    @MainActor func rememberDockedZoneLayout() {
        guard let profile = zoneLayoutProfileKey, !zoneContainers.isEmpty,
              presentationModeSnapshot == nil, rootTilingContainer.orientation == .h,
              rootTilingContainer.layout == .tiles else { return }
        let defs = currentLiveZoneDefinitions()
        guard !defs.isEmpty, defs.allSatisfy({ $0.width.isFinite && $0.width > 0 }) else { return }
        let previous = DockedZoneLayoutMemory.shared.snapshot(workspace: name, profile: profile)
        let currentWindows = rootTilingContainer.allLeafWindowsRecursive
        let zones: [DockedZoneLayoutMemory.SavedZone] = defs.compactMap { def in
            guard let zone = zoneContainers[def.id] else { return nil }
            var windows: [DockedZoneLayoutMemory.SavedWindow] = zone.allLeafWindowsRecursive.map { window in
                let weight = window.parent === zone ? Double(window.getWeight(zone.orientation)) : nil
                return DockedZoneLayoutMemory.SavedWindow(id: window.windowId, appId: window.app.rawAppBundleId,
                    title: window.placementIdentityTitle, weight: weight)
            }
            // Keep slots for temporarily closed or not-yet-detected windows. If a window is
            // still on this workspace in a different zone, its old slot must not be restored.
            if let old = previous?.zones.first(where: { $0.id == def.id }) {
                for (index, saved) in old.windows.enumerated() {
                    let existsHere = windows.contains { $0.id == saved.id ||
                        (!saved.title.isEmpty && $0.appId == saved.appId && $0.title == saved.title) }
                    let movedWithinWorkspace = currentWindows.contains { $0.windowId == saved.id ||
                        (!saved.title.isEmpty && $0.app.rawAppBundleId == saved.appId && $0.placementIdentityTitle == saved.title) }
                    if !existsHere && !movedWithinWorkspace { windows.insert(saved, at: min(index, windows.count)) }
                }
            }
            return DockedZoneLayoutMemory.SavedZone(
                id: def.id, width: def.width, layout: zone.layout.rawValue, horizontal: zone.orientation == .h,
                activeWindowId: zone.layout == .stack ? zone.mostRecentWindowRecursive?.windowId : nil,
                windows: windows
            )
        }
        guard zones.count == defs.count else { return }
        DockedZoneLayoutMemory.shared.save(.init(zones: zones), workspace: name, profile: profile)
    }

    @MainActor func restoreDockedZoneWindows(_ snapshot: DockedZoneLayoutMemory.Snapshot) {
        // Only rearrange windows still on this workspace. Never pull windows back from a workspace
        // to which the user deliberately moved them while undocked.
        var remaining = rootTilingContainer.allLeafWindowsRecursive
        for savedZone in snapshot.zones {
            guard let zone = zoneContainers[savedZone.id] else { continue }
            var restoredById: [UInt32: Window] = [:]
            for (index, saved) in savedZone.windows.enumerated() {
                let exact = remaining.firstIndex { $0.windowId == saved.id && $0.app.rawAppBundleId == saved.appId }
                let matching = remaining.indices.filter { i in
                    remaining[i].app.rawAppBundleId == saved.appId && !saved.title.isEmpty &&
                        remaining[i].placementIdentityTitle == saved.title
                }
                let sameApp = remaining.indices.filter { remaining[$0].app.rawAppBundleId == saved.appId }
                let savedAppCount = snapshot.zones.flatMap(\.windows).filter { $0.appId == saved.appId }.count
                let uniqueApp = saved.appId != nil && sameApp.count == 1 && savedAppCount == 1 ? sameApp.first : nil
                guard let found = exact ?? (matching.count == 1 ? matching.first : nil) ?? uniqueApp else { continue }
                let window = remaining.remove(at: found)
                restoredById[saved.id] = window
                let targetIndex = min(index, zone.children.count)
                var insertionIndex = targetIndex
                if window.parent === zone, let old = window.ownIndex, old < insertionIndex { insertionIndex += 1 }
                let weight = saved.weight.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? WEIGHT_AUTO
                window.bind(to: zone, adaptiveWeight: weight,
                            index: min(insertionIndex, zone.children.count))
            }
            if let activeId = savedZone.activeWindowId,
               let active = restoredById[activeId] ?? zone.allLeafWindowsRecursive.first(where: { $0.windowId == activeId }) {
                active.markAsMostRecentChild()
            }
        }
    }
}

/// Remembers which workspace was visible on an ultrawide before that display disappeared.
final class DockedMonitorWorkspaceMemory {
    @MainActor static var shared = DockedMonitorWorkspaceMemory()
    private var data: [String: String]
    let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AeroSpace/docked-monitor-workspaces.json")
        if let bytes = try? Data(contentsOf: self.storageURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: bytes) {
            data = decoded
        } else { data = [:] }
    }

    func workspace(for profile: String) -> String? { data[profile] }

    func remember(workspace: String, profile: String) {
        guard data[profile] != workspace else { return }
        data[profile] = workspace
        guard let bytes = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: storageURL, options: .atomic)
    }
}
