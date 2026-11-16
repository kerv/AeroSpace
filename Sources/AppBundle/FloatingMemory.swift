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
        var floatingApps: [String]?
    }
    private var legacyWindowIds: Set<UInt32> = []
    private(set) var identities: [Identity] = []
    private var floatingApps: Set<String> = []
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
            // Older versions stored one choice per window. Promote those choices so
            // newly opened windows from those apps inherit the same floating mode.
            floatingApps = Set(storage.floatingApps ?? storage.identities.map(\.appId))
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
        floatingApps.insert(appId)
        let identity = Identity(appId: appId, title: window.placementIdentityTitle, windowId: window.windowId)
        if let index = identities.firstIndex(where: { $0.windowId == window.windowId && $0.appId == appId }) {
            identities[index] = identity
        } else {
            identities.append(identity)
        }
        save()
    }

    /// Restore existing floated windows and apply an app's preference to newly opened ones.
    @MainActor func restore(_ window: Window, appWindowCount _: Int) -> Bool {
        if legacyWindowIds.contains(window.windowId) {
            remember(window)
            return true
        }
        guard let appId = window.app.rawAppBundleId else { return false }
        let candidates = identities.indices.filter { identities[$0].appId == appId }
        let exactId = candidates.first { identities[$0].windowId == window.windowId }
        if exactId == nil, floatingApps.contains(appId) {
            remember(window)
            return true
        }
        guard let index = exactId else { return false }
        identities[index].windowId = window.windowId
        save()
        return true
    }

    /// Explicitly returning to tiling removes the persistent preference.
    @MainActor func forget(_ window: Window) {
        legacyWindowIds.remove(window.windowId)
        if let appId = window.app.rawAppBundleId {
            floatingApps.remove(appId)
            identities.removeAll { $0.appId == appId && $0.windowId == window.windowId }
        }
        save()
    }

    /// Losing a window (including temporarily on screen lock) does not erase its preference.
    func forgetLiveId(windowId: UInt32) {
        legacyWindowIds.remove(windowId)
        identities.removeAll { $0.windowId == windowId }
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
        let storage = Storage(legacyWindowIds: legacyWindowIds.sorted(), identities: identities, floatingApps: floatingApps.sorted())
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }
}
