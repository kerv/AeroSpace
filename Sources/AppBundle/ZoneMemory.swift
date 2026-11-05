import Foundation

/// A stable fingerprint of the current monitor configuration.
/// Encodes all monitors sorted by origin so the same physical setup always produces the same key,
/// regardless of `CGDirectDisplayID` (which changes across reboots/reconnects).
struct MonitorProfile: Codable, Hashable {
    struct MonitorEntry: Codable, Hashable {
        // periphery:ignore - used via Codable/Hashable synthesis
        let width: CGFloat
        // periphery:ignore - used via Codable/Hashable synthesis
        let height: CGFloat
        // Origin coordinates are intentionally excluded: they shift whenever any monitor is
        // added or repositioned, which would silently wipe zone memories even though the
        // physical monitor hasn't changed. Width/height is unique enough in practice
        // (e.g. 3440×1440 ultrawides) and remains stable across monitor configuration changes.
    }
    let entries: [MonitorEntry]

    init(entries: [MonitorEntry]) {
        self.entries = entries.sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    init(_ monitors: [any Monitor]) {
        entries = monitors
            .map { MonitorEntry(width: $0.rect.width, height: $0.rect.height) }
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    /// A stable string key for use as a dictionary key in persisted JSON.
    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8)
        else { return "unknown" }
        return str
    }
}

/// Persists window-to-zone assignments keyed by monitor profile.
/// Window key is the app's bundle ID (Phase 2 uses bundleID-only; title-based disambiguation deferred).
/// Corrupt or missing JSON silently resets to an empty state.
final class ZoneMemory {
    @MainActor static var shared = ZoneMemory()

    struct Entry: Equatable {
        let profileKey: String
        let appId: String
        let zoneName: String
    }

    // [profileKey: [windowKey: zoneName]]
    private var data: [String: [String: String]] = [:]
    let storageURL: URL

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/zone-memory.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        load()
    }

    /// Returns the window key for a window, or nil if the app has no bundle ID.
    func windowKey(for window: Window) -> String? {
        window.app.rawAppBundleId
    }

    /// Records that `window` belongs to `zoneName` under the given monitor profile.
    func rememberZone(_ zoneName: String, for window: Window, profile: MonitorProfile) {
        guard let key = windowKey(for: window) else { return }
        rememberZone(zoneName, forBundleId: key, profile: profile)
    }

    /// Records that bundle ID belongs to `zoneName` under the given monitor profile.
    func rememberZone(_ zoneName: String, forBundleId bundleId: String, profile: MonitorProfile) {
        let profileKey = profile.key
        if data[profileKey] == nil { data[profileKey] = [:] }
        data[profileKey]![bundleId] = zoneName
        save()
    }

    /// Returns the remembered zone name for `window` under the given profile, or nil.
    func rememberedZone(for window: Window, profile: MonitorProfile) -> String? {
        guard let key = windowKey(for: window) else { return nil }
        return data[profile.key]?[key]
    }

    /// Returns the remembered zone name for the given bundle ID under the given profile, or nil.
    func rememberedZone(forBundleId bundleId: String, profile: MonitorProfile) -> String? {
        data[profile.key]?[bundleId]
    }

    /// Returns all persisted entries sorted for deterministic presentation.
    func entries() -> [Entry] {
        data
            .flatMap { profileKey, appToZone in
                appToZone.map { appId, zoneName in
                    Entry(profileKey: profileKey, appId: appId, zoneName: zoneName)
                }
            }
            .sorted { ($0.profileKey, $0.appId, $0.zoneName) < ($1.profileKey, $1.appId, $1.zoneName) }
    }

    /// Clears all persisted entries and returns the number removed.
    @discardableResult
    func clearAll() -> Int {
        let removed = data.values.reduce(0) { $0 + $1.count }
        data = [:]
        save()
        return removed
    }

    /// Clears all entries for the given bundle ID across monitor profiles and returns the number removed.
    @discardableResult
    func clear(bundleId: String) -> Int {
        var removed = 0
        for profileKey in Array(data.keys) {
            let previous = data[profileKey]?.removeValue(forKey: bundleId)
            if previous != nil { removed += 1 }
            if data[profileKey]?.isEmpty == true {
                data.removeValue(forKey: profileKey)
            }
        }
        if removed > 0 { save() }
        return removed
    }

    private func load() {
        guard let raw = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: raw)
        else {
            data = [:]
            return
        }
        data = decoded
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? raw.write(to: storageURL)
    }
}
