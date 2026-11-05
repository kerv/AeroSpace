import AppKit
import Common
import SwiftUI

struct ZoneOverlayItem {
    let id: String
    let rect: Rect
    let isActive: Bool
    let isFloating: Bool
}

/// Use the parsed bindings of the active mode, preserving the notation from the user's TOML.
/// Show window-management commands only; arbitrary shell commands can contain private data.
func zoneOverlayBindingHints(_ bindings: [String: HotkeyBinding]) -> [String] {
    let relevant: Set<String> = [
        "focus", "focus-zone", "focus-monitor", "focus-back-and-forth", "move", "move-node-to-zone",
        "move-floating-to-zone", "move-node-to-monitor", "move-node-to-workspace", "move-workspace-to-monitor",
        "workspace", "workspace-back-and-forth", "layout", "resize", "fullscreen", "macos-native-fullscreen",
        "macos-native-minimize", "split", "join-with", "balance-sizes", "swap", "zone-focus-mode",
        "show-zone-picker", "overview-zones", "show-workspace-menu",
    ]
    return bindings.values.sorted { $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation }.compactMap { binding in
        let commands = binding.commands.flatten()
        let matching = commands.filter { relevant.contains($0.info.kind.rawValue) }
        guard !matching.isEmpty else { return nil }
        let descriptions = matching.map { $0.args.description }.joined(separator: "; ")
        let prefix = commands.count > 1 ? "includes " : ""
        return "\(binding.descriptionWithKeyNotation): \(prefix)\(descriptions)"
    }
}

@MainActor
func zoneOverlayItems(in workspace: Workspace, floatingRect: Rect? = nil) -> [ZoneOverlayItem] {
    let floating = focus.windowOrNil?.isFloating == true
    let activeName = floating ? floatingRect.flatMap { workspace.zoneForWindowRect($0) } : activeZoneName(in: workspace)
    return workspace.activeZoneDefinitions.compactMap { def in
        guard let zone = workspace.zoneContainers[def.id],
              let rect = zone.lastAppliedLayoutPhysicalRect ?? workspace.theoreticalZoneRect(for: def.id),
              rect.width > 0, rect.height > 0 else { return nil }
        return ZoneOverlayItem(id: def.id, rect: rect, isActive: def.id == activeName, isFloating: floating)
    }
}

@MainActor
final class ZoneScreenOverlayController {
    static let shared = ZoneScreenOverlayController()
    private var panels: [String: ZoneScreenOverlayPanel] = [:]
    private(set) var isVisible = false
    private var optionIsHeld = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func startOptionMonitoring() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.contains(.option)
            Task { @MainActor in await ZoneScreenOverlayController.shared.setOptionHeld(held) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.contains(.option)
            Task { @MainActor in await ZoneScreenOverlayController.shared.setOptionHeld(held) }
            return event
        }
    }

    func setOptionHeld(_ held: Bool) async {
        guard optionIsHeld != held else { return }
        optionIsHeld = held
        if held {
            guard TrayMenuModel.shared.isEnabled, !focus.workspace.zoneContainers.isEmpty else { return }
            isVisible = true
            await refresh()
        } else {
            hide()
        }
    }

    func hide() {
        isVisible = false
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func refresh() async {
        guard isVisible else { return }
        let workspace = focus.workspace
        guard !workspace.zoneContainers.isEmpty else { hide(); return }
        let floatingRect: Rect?
        if let window = focus.windowOrNil, window.isFloating {
            floatingRect = try? await window.getAxRect(.nonCancellable)
        } else {
            floatingRect = nil
        }
        guard isVisible, focus.workspace === workspace else { return }
        let items = zoneOverlayItems(in: workspace, floatingRect: floatingRect)
        let modeName = activeMode ?? mainModeId
        let hints = zoneOverlayBindingHints(config.modes[modeName]?.bindings ?? [:])
        let activeIds = Set(items.map(\.id))
        for id in Set(panels.keys).subtracting(activeIds) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        let screenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? mainMonitor.height
        for item in items {
            let frame = NSRect(x: item.rect.minX, y: screenHeight - item.rect.minY - item.rect.height,
                               width: item.rect.width, height: item.rect.height)
            let panel = panels[item.id] ?? ZoneScreenOverlayPanel()
            panels[item.id] = panel
            panel.contentView = NSHostingView(rootView: ZoneScreenOverlayView(item: item, modeName: modeName, hints: hints))
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }
}

private final class ZoneScreenOverlayPanel: NSPanelHud {
    override init() {
        super.init()
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ZoneScreenOverlayView: View {
    let item: ZoneOverlayItem
    let modeName: String
    let hints: [String]

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(item.isActive ? Color.accentColor : Color.white.opacity(0.8), lineWidth: item.isActive ? 5 : 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.id.uppercased() + (item.isFloating && item.isActive ? "  ·  FLOATING" : item.isActive ? "  ·  ACTIVE" : ""))
                    .font(.system(size: 16, weight: .bold))
                Text("Window shortcuts · \(modeName) mode")
                    .font(.system(size: 11, weight: .medium))
                if hints.isEmpty {
                    Text("No window shortcuts configured in this mode")
                        .font(.system(size: 11))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: item.rect.width >= 650 ? 2 : 1), alignment: .leading, spacing: 3) {
                        ForEach(hints, id: \.self) { hint in
                            Text(hint).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                        }
                    }
                }
                Text("Release ⌥ to hide")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
