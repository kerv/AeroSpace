import Foundation

/// Persists the set of window IDs the user has marked sticky across AeroSpace restarts.
///
/// A sticky floating window follows the user across workspace switches.
/// Sticky windows are also tracked in FloatingMemory so the floating state is
/// independently restored on restart before this class promotes them to sticky.
final class StickyMemory {
    @MainActor static var shared = StickyMemory()

    private var stickyWindowIds: Set<UInt32> = []
    let storageURL: URL

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/sticky-windows.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        load()
    }

    func remember(windowId: UInt32) {
        stickyWindowIds.insert(windowId)
        save()
    }

    func forget(windowId: UInt32) {
        stickyWindowIds.remove(windowId)
        save()
    }

    func isRemembered(windowId: UInt32) -> Bool {
        stickyWindowIds.contains(windowId)
    }

    private func load() {
        guard let raw = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([UInt32].self, from: raw)
        else {
            stickyWindowIds = []
            return
        }
        stickyWindowIds = Set(decoded)
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(Array(stickyWindowIds)) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? raw.write(to: storageURL)
    }
}
