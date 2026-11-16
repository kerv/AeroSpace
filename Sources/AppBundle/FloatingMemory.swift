import Foundation

/// Records explicit floating choices beyond the lifetime of a macOS window ID.
final class FloatingMemory {
    @MainActor static var shared = FloatingMemory()

    struct Identity: Codable, Equatable {
        var appId: String
        var title: String
        var windowId: UInt32?
    }
    private struct Storage: Codable {
        var legacyWindowIds: [UInt32]
        var identities: [Identity]
    }
    private var legacyWindowIds: Set<UInt32> = []
    private(set) var identities: [Identity] = []
    let storageURL: URL

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AeroSpace/floating-windows.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        guard let data = try? Data(contentsOf: self.storageURL) else { return }
        if let storage = try? JSONDecoder().decode(Storage.self, from: data) {
            legacyWindowIds = Set(storage.legacyWindowIds)
            identities = storage.identities
        } else if let legacy = try? JSONDecoder().decode([UInt32].self, from: data) {
            legacyWindowIds = Set(legacy)
        }
    }

    /// Legacy ID-only entries are still read so existing floating windows can be upgraded.
    func remember(windowId: UInt32) {
        legacyWindowIds.insert(windowId)
        save()
    }

    @MainActor func remember(_ window: Window) {
        guard let appId = window.app.rawAppBundleId, !appId.isEmpty else {
            remember(windowId: window.windowId)
            return
        }
        legacyWindowIds.remove(window.windowId)
        let identity = Identity(appId: appId, title: window.placementIdentityTitle, windowId: window.windowId)
        if let index = identities.firstIndex(where: { $0.windowId == window.windowId && $0.appId == appId }) {
            identities[index] = identity
        } else {
            identities.append(identity)
        }
        save()
    }

    /// Prefer the live ID; after an app relaunch use an unambiguous title or single-window app.
    @MainActor func restore(_ window: Window, appWindowCount: Int) -> Bool {
        if legacyWindowIds.contains(window.windowId) {
            remember(window)
            return true
        }
        guard let appId = window.app.rawAppBundleId else { return false }
        let candidates = identities.indices.filter { identities[$0].appId == appId }
        let exactId = candidates.first { identities[$0].windowId == window.windowId }
        let matchingTitle = candidates.filter { !window.placementIdentityTitle.isEmpty && identities[$0].title == window.placementIdentityTitle }
        let exactTitle = matchingTitle.count == 1 ? matchingTitle.first : nil
        let uniqueApp = appWindowCount == 1 && candidates.count == 1 ? candidates.first : nil
        guard let index = exactId ?? exactTitle ?? uniqueApp else { return false }
        // A record already attached to another live window must never be stolen by a new one.
        if let previousId = identities[index].windowId, previousId != window.windowId,
           Window.get(byId: previousId) != nil { return false }
        identities[index].windowId = window.windowId
        // Keep the stored title stable when an app's dynamic title changed.
        save()
        return true
    }

    /// Explicitly returning to tiling removes the persistent preference.
    @MainActor func forget(_ window: Window) {
        legacyWindowIds.remove(window.windowId)
        if let appId = window.app.rawAppBundleId {
            identities.removeAll { $0.appId == appId && $0.windowId == window.windowId }
        }
        save()
    }

    /// Losing a window (including temporarily on screen lock) does not erase its preference.
    func forgetLiveId(windowId: UInt32) {
        legacyWindowIds.remove(windowId)
        for index in identities.indices where identities[index].windowId == windowId {
            identities[index].windowId = nil
        }
        save()
    }

    // Used by ID-only scratchpad state and legacy tests.
    func forget(windowId: UInt32) {
        legacyWindowIds.remove(windowId)
        identities.removeAll { $0.windowId == windowId }
        save()
    }

    func isRemembered(windowId: UInt32) -> Bool {
        legacyWindowIds.contains(windowId) || identities.contains { $0.windowId == windowId }
    }

    private func save() {
        let storage = Storage(legacyWindowIds: legacyWindowIds.sorted(), identities: identities)
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
