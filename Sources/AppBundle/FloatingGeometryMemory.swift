import AppKit

/// Window frames are stored relative to a display, so reconnecting a display at a different
/// desktop origin does not move a remembered floating window offscreen.
final class FloatingGeometryMemory {
    @MainActor static var shared = FloatingGeometryMemory()
    struct Entry: Codable, Equatable {
        let appId: String
        let title: String
        let profile: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    private(set) var entries: [Entry]
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AeroSpace/floating-geometry.json")
        entries = (try? Data(contentsOf: self.url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func find(appId: String, title: String, profile: String, hasPeers: Bool) -> Entry? {
        let candidates = entries.filter { $0.appId == appId && $0.profile == profile }
        if !title.isEmpty, let exact = candidates.first(where: { $0.title == title }) { return exact }
        return !hasPeers && candidates.count == 1 ? candidates.first : nil
    }

    func remember(_ entry: Entry) {
        guard !entry.appId.isEmpty, entry.width > 0, entry.height > 0 else { return }
        if let i = entries.firstIndex(where: { $0.appId == entry.appId && $0.title == entry.title && $0.profile == entry.profile }) {
            if entries[i] == entry { return }
            entries[i] = entry
        } else { entries.append(entry) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
func rememberFloatingGeometry(_ window: Window) async {
    guard window.isFloating, !window.isHiddenInCorner, let workspace = window.nodeWorkspace, workspace.isVisible,
          let appId = window.app.rawAppBundleId, let rect = try? await window.getAxRect(.nonCancellable),
          rect.width > 0, rect.height > 0 else { return }
    let peers = workspace.allLeafWindowsRecursive.filter { $0 !== window && $0.app.rawAppBundleId == appId }
    guard !peers.contains(where: { window.placementIdentityTitle.isEmpty || $0.placementIdentityTitle == window.placementIdentityTitle }) else { return }
    let monitor = workspace.workspaceMonitor
    let bounds = monitor.visibleRect
    FloatingGeometryMemory.shared.remember(.init(appId: appId, title: window.placementIdentityTitle,
        profile: MonitorProfile([monitor]).key, x: rect.minX - bounds.minX, y: rect.minY - bounds.minY,
        width: rect.width, height: rect.height))
}

@MainActor
func rememberedFloatingFrame(for window: Window, in workspace: Workspace, zone: Rect) -> CGRect? {
    guard let appId = window.app.rawAppBundleId else { return nil }
    let peers = workspace.allLeafWindowsRecursive.filter { $0 !== window && $0.app.rawAppBundleId == appId }
    guard !peers.contains(where: { window.placementIdentityTitle.isEmpty || $0.placementIdentityTitle == window.placementIdentityTitle }) else { return nil }
    let monitor = workspace.workspaceMonitor
    guard let entry = FloatingGeometryMemory.shared.find(appId: appId, title: window.placementIdentityTitle,
        profile: MonitorProfile([monitor]).key, hasPeers: !peers.isEmpty) else { return nil }
    let frame = CGRect(x: monitor.visibleRect.minX + entry.x, y: monitor.visibleRect.minY + entry.y,
                       width: entry.width, height: entry.height)
    guard frame.width > 0, frame.height > 0, frame.width < zone.width * 0.95, frame.height < zone.height * 0.95,
          frame.minX >= zone.minX, frame.maxX <= zone.maxX, frame.minY >= zone.minY, frame.maxY <= zone.maxY else { return nil }
    return frame
}
