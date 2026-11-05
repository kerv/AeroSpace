import Foundation

/// Persists scratchpad state across AeroSpace restarts.
///
/// Tracks which window IDs live in the scratchpad workspace and remembers the
/// last on-screen position for each, so windows are restored to the same spot
/// when summoned again after a restart.
final class ScratchpadMemory {
    @MainActor static var shared = ScratchpadMemory()

    private var windowIds: Set<UInt32> = []
    private var positions: [UInt32: CGPoint] = [:]
    /// The ID of the window most recently hidden back into the scratchpad via the toggle command.
    /// Used to skip that window on the next summon so the hotkey cycles through all scratchpad windows.
    /// Not persisted — resets on restart.
    var lastHiddenWindowId: UInt32? = nil
    let storageURL: URL

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/scratchpad-windows.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        load()
    }

    func remember(windowId: UInt32) {
        windowIds.insert(windowId)
        save()
    }

    func forget(windowId: UInt32) {
        windowIds.remove(windowId)
        positions.removeValue(forKey: windowId)
        save()
    }

    func isRemembered(windowId: UInt32) -> Bool {
        windowIds.contains(windowId)
    }

    func rememberPosition(_ point: CGPoint, for windowId: UInt32) {
        positions[windowId] = point
        save()
    }

    func rememberedPosition(for windowId: UInt32) -> CGPoint? {
        positions[windowId]
    }

    // MARK: - Persistence

    private struct StoredData: Codable {
        let ids: [UInt32]
        let positions: [String: StoredPoint]
    }

    private struct StoredPoint: Codable {
        let x: Double
        let y: Double
    }

    private func load() {
        guard let raw = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(StoredData.self, from: raw)
        else {
            windowIds = []
            positions = [:]
            return
        }
        windowIds = Set(decoded.ids)
        positions = Dictionary(uniqueKeysWithValues: decoded.positions.compactMap { key, val in
            guard let id = UInt32(key) else { return nil }
            return (id, CGPoint(x: val.x, y: val.y))
        })
    }

    private func save() {
        let storedPositions = Dictionary(uniqueKeysWithValues: positions.map { id, point in
            (String(id), StoredPoint(x: point.x, y: point.y))
        })
        let data = StoredData(ids: Array(windowIds), positions: storedPositions)
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? raw.write(to: storageURL)
    }
}
