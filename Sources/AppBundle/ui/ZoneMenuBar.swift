import AppKit
import SwiftUI

/// A display-specific overlay: macOS status items cannot be positioned at the center of one screen.
@MainActor
final class ZoneMenuBarController {
    static let shared = ZoneMenuBarController()
    private var panels: [String: ZoneMenuBarPanel] = [:]
    private var floatingPanel: ZoneMenuBarPanel?
    func refresh() async {
        guard TrayMenuModel.shared.isEnabled,
              let monitor = monitors.first(where: { $0.width / max($0.height, 1) >= 2.3 && $0.activeWorkspace.activeZoneDefinitions.count > 1 }),
              let screen = NSScreen.screens.getOrNil(atIndex: monitor.monitorAppKitNsScreenScreensId - 1)
        else { hide(); return }
        let workspace = monitor.activeWorkspace
        let definitions = workspace.activeZoneDefinitions
        guard workspace.isVisible, monitor.activeWorkspace === workspace else { hide(); return }
        func entries(for windows: [Window]) -> [ZoneMenuBarEntry] {
            windows.map { window in
                let app = (window as? MacWindow)?.macApp.nsApp
                return ZoneMenuBarEntry(id: window.windowId,
                                        icon: app?.icon ?? NSImage(named: NSImage.applicationIconName)!,
                                        title: app?.localizedName ?? "Window",
                                        active: focus.windowOrNil === window)
            }
        }
        let groups: [ZoneMenuBarGroup] = definitions.compactMap { definition in
            guard let zone = workspace.zoneContainers[definition.id],
                  let rect = zone.lastAppliedLayoutVirtualRect ?? workspace.theoreticalZoneRect(for: definition.id),
                  rect.width > 0 else { return nil }
            return ZoneMenuBarGroup(id: definition.id, rect: rect, entries: entries(for: zone.allLeafWindowsRecursive),
                                    active: activeZoneName(in: workspace) == definition.id)
        }
        guard !groups.isEmpty else { hide(); return }
        // The status item thickness can be smaller than the actual menu bar on
        // modern macOS. Use this screen's reserved top inset when available.
        let menuHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY - 2)
        let activeIds = Set(groups.map(\.id))
        for id in Set(panels.keys).subtracting(activeIds) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        var centerFrame: NSRect?
        var leftFrame: NSRect?
        for (index, group) in groups.enumerated() {
            let desiredWidth = max(28, CGFloat(group.entries.count) * 23 + 16)
            let width = min(group.rect.width, min(400, desiredWidth))
            let preferredX: CGFloat
            if index == 0 {
                preferredX = group.rect.maxX - width
            } else if index == groups.count - 1 {
                preferredX = group.rect.minX
            } else {
                preferredX = group.rect.center.x - width / 2
            }
            let x = min(max(preferredX, screen.frame.minX), screen.frame.maxX - width)
            let frame = NSRect(x: x, y: screen.frame.maxY - menuHeight, width: width, height: menuHeight)
            if index == 0 { leftFrame = frame }
            if group.id == "center" || (groups.allSatisfy({ $0.id != "center" }) && index == groups.count / 2) {
                centerFrame = frame
            }
            let panel = panels[group.id] ?? ZoneMenuBarPanel()
            panels[group.id] = panel
            panel.contentView = NSHostingView(rootView: ZoneMenuBarView(group: group))
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
        if !workspace.floatingWindows.isEmpty,
           let centerFrame, let leftFrame, centerFrame.minX - leftFrame.maxX >= 40,
           let reference = groups.first(where: { $0.id == "center" }) ?? groups.getOrNil(atIndex: groups.count / 2) {
            let floatingEntries = entries(for: workspace.floatingWindows)
            let group = ZoneMenuBarGroup(id: "floating", rect: reference.rect, entries: floatingEntries,
                                         active: floatingEntries.contains(where: \.active), isFloating: true)
            let gap = centerFrame.minX - leftFrame.maxX
            let width = min(gap - 8, min(400, max(40, CGFloat(floatingEntries.count) * 23 + 30)))
            let frame = NSRect(x: (leftFrame.maxX + centerFrame.minX - width) / 2, y: centerFrame.minY,
                               width: width, height: menuHeight)
            let panel = floatingPanel ?? ZoneMenuBarPanel()
            floatingPanel = panel
            panel.contentView = NSHostingView(rootView: ZoneMenuBarView(group: group))
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        } else {
            floatingPanel?.orderOut(nil)
            floatingPanel = nil
        }
    }

    private func hide() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
    }
}

private final class ZoneMenuBarPanel: NSPanelHud {
    override init() {
        super.init()
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        canHide = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ZoneMenuBarEntry: Identifiable {
    let id: UInt32
    let icon: NSImage
    let title: String
    let active: Bool
}

private struct ZoneMenuBarGroup: Identifiable {
    let id: String
    let rect: Rect
    let entries: [ZoneMenuBarEntry]
    let active: Bool
    var isFloating = false
}

private struct ZoneMenuBarView: View {
    let group: ZoneMenuBarGroup
    var body: some View {
        HStack(spacing: 3) {
                HStack(spacing: 2) {
                    if group.isFloating {
                        Text("F").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary)
                            .help("Floating windows")
                    }
                    if group.entries.isEmpty {
                        Text("·").foregroundStyle(Color.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            ForEach(group.entries) { entry in
                                Button {
                                    Task { @MainActor in
                                        guard let token: RunSessionGuard = .isServerEnabled else { return }
                                        try await runLightSession(.menuBarButton, token) {
                                            guard let window = Window.get(byId: entry.id) else { return }
                                            let alreadyFocused = focus.windowOrNil === window
                                            guard window.focusWindow() else { return }
                                            // A repeat click should raise the window even if AeroSpace
                                            // already considers it focused. Otherwise the session raises it.
                                            if alreadyFocused { window.nativeFocus() }
                                        }
                                    }
                                } label: {
                                    Image(nsImage: entry.icon).resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 18, height: 18).padding(1)
                                        .background(entry.active ? Color.accentColor.opacity(0.3) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 4))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(entry.active ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            if entry.active {
                                                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                                                    .overlay(Circle().stroke(Color.white, lineWidth: 0.7))
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .help(entry.title)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(group.active ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
