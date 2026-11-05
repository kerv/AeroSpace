import AppKit
import Common
import SwiftUI

struct ZoneOverlayItem {
    let id: String
    let rect: Rect
    let isActive: Bool
    let isFloating: Bool
}

/// Summarize common actions from the active mode without exposing shell arguments.
func zoneOverlayBindingHints(_ bindings: [String: HotkeyBinding]) -> [String] {
    let order = ["Focus windows", "Move windows", "Focus zones", "Move to zones", "Layout", "Float / tile", "Resize zones", "Cycle windows"]
    var actions: [String: [String]] = [:]
    for binding in bindings.values {
        for command in binding.commands.flatten() {
            let action: String?
            switch command {
                case let focus as FocusCommand:
                    switch focus.args.target {
                        case .direction: action = "Focus windows"
                        case .dfsRelative: action = "Cycle windows"
                        default: action = nil
                    }
                case is MoveCommand: action = "Move windows"
                case is FocusZoneCommand: action = "Focus zones"
                case is MoveNodeToZoneCommand: action = "Move to zones"
                case let layout as LayoutCommand:
                    action = layout.args.toggleBetween.val.contains(.floating) ? "Float / tile" : "Layout"
                case let resize as ResizeCommand: action = resize.args.zone ? "Resize zones" : nil
                default: action = nil
            }
            if let action { actions[action, default: []].append(binding.descriptionWithKeyNotation) }
        }
    }
    return order.compactMap { action in
        guard let keys = actions[action], !keys.isEmpty else { return nil }
        return "\(action): \(compactOverlayKeys(Array(Set(keys)).sorted()))"
    }
}

private func compactOverlayKeys(_ bindings: [String]) -> String {
    var groups: [String: [String]] = [:]
    for binding in bindings {
        let parts = binding.split(separator: "-").map(String.init)
        guard let key = parts.last else { continue }
        let modifiers = parts.dropLast().map { modifier in
            switch modifier {
                case "alt": "⌥"
                case "ctrl": "⌃"
                case "shift": "⇧"
                case "cmd": "⌘"
                case "hyper": "⌃⌥⇧⌘"
                case "meh": "⌃⌥⇧"
                default: modifier + "-"
            }
        }.joined()
        let displayKey: String = switch key {
            case "left": "←"
            case "right": "→"
            case "up": "↑"
            case "down": "↓"
            case "slash": "/"
            case "minus": "−"
            case "equal": "="
            case "tab": "Tab"
            default: key.uppercased()
        }
        let family: String = switch key {
            case "left", "right", "up", "down": "arrows"
            case let value where value.count == 1 && value.first?.isLetter == true: "letters"
            case let value where value.count == 1 && value.first?.isNumber == true: "numbers"
            default: "other"
        }
        groups[modifiers + "|" + family, default: []].append(displayKey)
    }
    let formatted = groups.keys.sorted().map { group in
        let modifier = String(group.split(separator: "|", omittingEmptySubsequences: false).first ?? "")
        let keys = groups[group] ?? []
        let directions = ["←", "↓", "↑", "→"]
        let ordered = keys.allSatisfy { directions.contains($0) }
            ? directions.filter { keys.contains($0) }
            : keys
        return modifier + ordered.joined(separator: "/")
    }
    return formatted.prefix(2).joined(separator: " · ") + (formatted.count > 2 ? " …" : "")
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
                HStack(spacing: 10) {
                    Text(item.id.uppercased() + (item.isFloating && item.isActive ? "  ·  FLOATING" : item.isActive ? "  ·  ACTIVE" : ""))
                        .font(.system(size: 14, weight: .bold))
                    Text("\(modeName) mode  ·  Release ⌥ to hide")
                        .font(.system(size: 11))
                }
                if hints.isEmpty {
                    Text("No window shortcuts configured in this mode")
                        .font(.system(size: 11))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), alignment: .leading)],
                              alignment: .leading, spacing: 3) {
                        ForEach(hints, id: \.self) { hint in
                            Text(hint).font(.system(size: 11)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: min(920, max(220, item.rect.width - 44)), alignment: .leading)
                }
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
