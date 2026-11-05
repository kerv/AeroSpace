import AppKit
import Common
import SwiftUI

struct OverviewZonesSnapshot {
    let workspaceName: String
    let monitorName: String
    let presetName: String?
    let isPresentationMode: Bool
    let focusedWindowIsFloating: Bool
    let presetNames: [String]
    let zones: [OverviewZone]
}

struct OverviewZone: Identifiable {
    let zoneId: String
    let layout: String
    let windowCount: Int
    let isFocused: Bool
    let isHinted: Bool
    let widthFraction: CGFloat
    let summary: String?
    let layoutTargetWindowId: UInt32?

    var id: String { zoneId }
}

@MainActor
func overviewZonesSnapshot(in workspace: Workspace, floatingZoneName: String? = nil) -> OverviewZonesSnapshot? {
    guard !workspace.zoneContainers.isEmpty else { return nil }
    let activeName = focus.windowOrNil?.isFloating == true ? floatingZoneName : activeZoneName(in: workspace)
    let hintedName = workspace.focusedZone
    let totalWeight = workspace.activeZoneDefinitions.reduce(CGFloat(0)) { partial, def in
        partial + (workspace.zoneContainers[def.id]?.getWeight(.h) ?? 0)
    }
    return OverviewZonesSnapshot(
        workspaceName: workspace.name,
        monitorName: workspace.workspaceMonitor.name,
        presetName: activeZonePresetName,
        isPresentationMode: workspace.presentationModeSnapshot != nil,
        focusedWindowIsFloating: focus.windowOrNil?.isFloating == true,
        presetNames: config.zonePresets.keys.sorted(),
        zones: workspace.activeZoneDefinitions.compactMap { def in
            guard let zone = workspace.zoneContainers[def.id] else { return nil }
            let summaryWindow = zone.mostRecentWindowRecursive
            let weight = zone.getWeight(.h)
            return OverviewZone(
                zoneId: def.id,
                layout: zoneLayoutString(zone),
                windowCount: zone.allLeafWindowsRecursive.count,
                isFocused: activeName == def.id,
                isHinted: hintedName == def.id,
                widthFraction: totalWeight > 0 ? weight / totalWeight : 0,
                summary: overviewSummary(for: summaryWindow),
                layoutTargetWindowId: summaryWindow?.windowId
            )
        }
    )
}

@MainActor
private func overviewSummary(for window: Window?) -> String? {
    guard let window else { return nil }
    if let macWindow = window as? MacWindow {
        if !macWindow.cachedTitle.isEmpty {
            return macWindow.cachedTitle
        }
        return macWindow.macApp.nsApp.localizedName
    }
    return "Window \(window.windowId)"
}

@MainActor
func nextLayoutDescription(for current: String) -> String {
    switch current {
        case LayoutCmdArgs.LayoutDescription.h_tiles.rawValue: LayoutCmdArgs.LayoutDescription.h_accordion.rawValue
        case LayoutCmdArgs.LayoutDescription.v_tiles.rawValue: LayoutCmdArgs.LayoutDescription.v_accordion.rawValue
        case LayoutCmdArgs.LayoutDescription.h_accordion.rawValue,
             LayoutCmdArgs.LayoutDescription.v_accordion.rawValue:
            LayoutCmdArgs.LayoutDescription.stack.rawValue
        case LayoutCmdArgs.LayoutDescription.stack.rawValue:
            LayoutCmdArgs.LayoutDescription.tiles.rawValue
        default:
            LayoutCmdArgs.LayoutDescription.tiles.rawValue
    }
}

@MainActor
final class OverviewZonesHUDController {
    static let shared = OverviewZonesHUDController()

    private var panel: OverviewZonesPanel?
    private var hostingView: NSHostingView<OverviewZonesView>?
    private var workspaceName: String?

    private init() {}

    func toggle(snapshot: OverviewZonesSnapshot, monitor: Monitor) {
        if workspaceName == snapshot.workspaceName {
            hide()
            return
        }
        show(snapshot: snapshot, monitor: monitor)
    }

    func show(snapshot: OverviewZonesSnapshot, monitor: Monitor) {
        let panel = panel ?? OverviewZonesPanel()
        self.panel = panel
        workspaceName = snapshot.workspaceName

        let width = min(max(640, monitor.visibleRect.width * 0.72), 1040)
        let height = min(max(320, monitor.visibleRect.height * 0.38), 520)
        let frame = NSRect(
            x: monitor.visibleRect.center.x - width / 2,
            y: screenFlipY(monitor.visibleRect.center.y - height / 2, height: height),
            width: width,
            height: height
        )

        let rootView = OverviewZonesView(
            snapshot: snapshot,
            onFocusZone: focusZone,
            onCycleLayout: cycleLayout,
            onApplyPreset: applyPreset,
            onResetPreset: resetPreset,
            onTogglePresentation: togglePresentation,
            onClose: hide
        )
        let hostingView = hostingView ?? NSHostingView(rootView: rootView)
        hostingView.rootView = rootView
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        self.hostingView = hostingView
        panel.contentView?.subviews.removeAll()
        panel.contentView?.addSubview(hostingView)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        workspaceName = nil
        panel?.orderOut(nil)
    }

    private func execute(_ args: [String]) {
        Task { @MainActor in
            if case .cmd(let command) = parseCommand(args) {
                _ = try? await command.run(.defaultEnv, .emptyStdin)
            }
            refresh()
        }
    }

    private func refresh() {
        let workspace = focus.workspace
        guard workspace.name == workspaceName,
              let snapshot = overviewZonesSnapshot(in: workspace)
        else {
            hide()
            return
        }
        show(snapshot: snapshot, monitor: workspace.workspaceMonitor)
    }

    private func focusZone(_ zoneId: String) {
        execute(["focus-zone", zoneId])
    }

    private func cycleLayout(windowId: UInt32?, currentLayout: String) {
        guard let windowId else {
            refresh()
            return
        }
        execute(["layout", "--window-id", "\(windowId)", nextLayoutDescription(for: currentLayout)])
    }

    private func applyPreset(_ presetName: String) {
        execute(["zone-preset", presetName])
    }

    private func resetPreset() {
        execute(["zone-preset", "--reset"])
    }

    private func togglePresentation() {
        execute(["presentation-mode", "toggle"])
    }

    private func screenFlipY(_ topLeftY: CGFloat, height: CGFloat) -> CGFloat {
        let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? mainMonitor.height
        return screenH - topLeftY - height
    }
}

private final class OverviewZonesPanel: NSPanelHud {
    override init() {
        super.init()
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        canHide = false
        styleMask.insert(.nonactivatingPanel)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct OverviewZonesView: View {
    let snapshot: OverviewZonesSnapshot
    let onFocusZone: (String) -> Void
    let onCycleLayout: (UInt32?, String) -> Void
    let onApplyPreset: (String) -> Void
    let onResetPreset: () -> Void
    let onTogglePresentation: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(snapshot.zones) { zone in
                        OverviewZoneCard(
                            zone: zone,
                            width: columnWidth(for: zone, totalWidth: geometry.size.width),
                            onFocus: { onFocusZone(zone.zoneId) },
                            onCycleLayout: { onCycleLayout(zone.layoutTargetWindowId, zone.layout) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text("⌥⌃ 1 / 2 / 3: focus    ·    ⇧⌥⌃ 1 / 2 / 3: move    ·    ⌥⌃ − / =: zone width    ·    ⌥⌃ M: stack")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.workspaceName)
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 8) {
                    Text(snapshot.monitorName)
                    Text(snapshot.presetName ?? "default")
                    Text(snapshot.focusedWindowIsFloating ? "Focused window: floating" : "Focused window: tiled")
                    if snapshot.isPresentationMode {
                        Text("presentation")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu("Preset") {
                Button("Reset", action: onResetPreset)
                if !snapshot.presetNames.isEmpty {
                    Divider()
                }
                ForEach(snapshot.presetNames, id: \.self) { presetName in
                    Button(presetName) { onApplyPreset(presetName) }
                }
            }
            .menuStyle(.borderlessButton)

            Button(snapshot.isPresentationMode ? "Presentation Off" : "Presentation On", action: onTogglePresentation)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Spacer()
        }
    }

    private func columnWidth(for zone: OverviewZone, totalWidth: CGFloat) -> CGFloat {
        let spacing = CGFloat(12)
        let zoneCount = max(snapshot.zones.count, 1)
        let totalSpacing = spacing * CGFloat(max(zoneCount - 1, 0))
        let usableWidth = max(0, totalWidth - totalSpacing)
        return max(140, usableWidth * zone.widthFraction)
    }
}

private struct OverviewZoneCard: View {
    let zone: OverviewZone
    let width: CGFloat
    let onFocus: () -> Void
    let onCycleLayout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(zoneShortcutLabel(zone.zoneId))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if zone.isFocused {
                    badge("active", emphasized: true)
                } else if zone.isHinted {
                    badge("next", emphasized: false)
                }
            }

            Text(zone.layout)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(zone.windowCount) window" + (zone.windowCount == 1 ? "" : "s"))
                .font(.system(size: 12, weight: .regular))

            if let summary = zone.summary {
                Text(summary)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            } else {
                Text("No tiling windows")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Focus", action: onFocus)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cycle Layout", action: onCycleLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(zone.layoutTargetWindowId == nil)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .frame(width: width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(zone.isFocused ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(zone.isFocused ? Color.accentColor : Color.white.opacity(0.08), lineWidth: zone.isFocused ? 2 : 1)
        )
    }

    @ViewBuilder
    private func badge(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(emphasized ? Color.white : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(emphasized ? Color.accentColor : Color.white.opacity(0.08)))
    }
}

private func zoneShortcutLabel(_ name: String) -> String {
    switch name {
        case "left": "1 · left"
        case "center": "2 · center"
        case "right": "3 · right"
        default: name
    }
}
