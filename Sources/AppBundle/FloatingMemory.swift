import Foundation

/// Persists the set of window IDs the user has manually floated across AeroSpace restarts.
///
/// macOS accessibility window IDs remain stable for the lifetime of a window regardless of which
/// accessibility client is observing, so they survive AeroSpace process restarts as long as the
/// window itself stays open.
final class FloatingMemory {
    @MainActor static var shared = FloatingMemory()

    private var floatingWindowIds: Set<UInt32> = []
    let storageURL: URL

    private static var defaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/floating-windows.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultURL
        load()
    }

    func remember(windowId: UInt32) {
        floatingWindowIds.insert(windowId)
        save()
    }

    func forget(windowId: UInt32) {
        floatingWindowIds.remove(windowId)
        save()
    }

    func isRemembered(windowId: UInt32) -> Bool {
        floatingWindowIds.contains(windowId)
    }

    private func load() {
        guard let raw = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([UInt32].self, from: raw)
        else {
            floatingWindowIds = []
            return
        }
        floatingWindowIds = Set(decoded)
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(Array(floatingWindowIds)) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? raw.write(to: storageURL)
    }
}
