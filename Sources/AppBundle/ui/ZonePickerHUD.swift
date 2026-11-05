import AppKit
import Common
import SwiftUI

private let zonePickerDisplayDurationNs: UInt64 = 1_500_000_000

struct ZonePickerSnapshot {
    let workspaceName: String
    let monitorName: String
    let presetName: String?
    let isPresentationMode: Bool
    let zones: [ZonePickerZone]
}

struct ZonePickerZone: Identifiable {
    let zoneId: String
    let layout: String
    let windowCount: Int
    let isFocused: Bool
    let isHinted: Bool

    var id: String { zoneId }
}

@MainActor
func zonePickerSnapshot(in workspace: Workspace) -> ZonePickerSnapshot? {
    guard !workspace.zoneContainers.isEmpty else { return nil }
    let activeName = activeZoneName(in: workspace)
    let hintedName = workspace.focusedZone
    return ZonePickerSnapshot(
        workspaceName: workspace.name,
        monitorName: workspace.workspaceMonitor.name,
        presetName: activeZonePresetName,
        isPresentationMode: workspace.presentationModeSnapshot != nil,
        zones: workspace.activeZoneDefinitions.compactMap { def in
            guard let zone = workspace.zoneContainers[def.id] else { return nil }
            return ZonePickerZone(
                zoneId: def.id,
                layout: zoneLayoutString(zone),
                windowCount: zone.allLeafWindowsRecursive.count,
                isFocused: activeName == def.id,
                isHinted: hintedName == def.id
            )
        }
    )
}

@MainActor
final class ZonePickerHUDController {
    static let shared = ZonePickerHUDController()

    private var panel: ZonePickerPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(snapshot: ZonePickerSnapshot, monitor: Monitor) {
        dismissTask?.cancel()

        let panel = panel ?? ZonePickerPanel()
        self.panel = panel

        let width = min(max(360, CGFloat(snapshot.zones.count) * 170), max(360, monitor.visibleRect.width - 80))
        let height: CGFloat = 164
        let frame = NSRect(
            x: monitor.visibleRect.center.x - width / 2,
            y: screenFlipY(monitor.visibleRect.center.y - height / 2, height: height),
            width: width,
            height: height
        )
        let hostingView = NSHostingView(rootView: ZonePickerView(snapshot: snapshot, onZoneTap: focusZone))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView?.subviews.removeAll()
        panel.contentView?.addSubview(hostingView)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: zonePickerDisplayDurationNs)
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func focusZone(_ zoneId: String) {
        Task { @MainActor in
            if case .cmd(let command) = parseCommand(["focus-zone", zoneId]) {
                _ = try? await command.run(.defaultEnv, .emptyStdin)
            }
            self.hide()
        }
    }

    private func screenFlipY(_ topLeftY: CGFloat, height: CGFloat) -> CGFloat {
        let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? mainMonitor.height
        return screenH - topLeftY - height
    }
}

private final class ZonePickerPanel: NSPanelHud {
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

private struct ZonePickerView: View {
    let snapshot: ZonePickerSnapshot
    let onZoneTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 10) {
                ForEach(snapshot.zones) { zone in
                    Button(action: { onZoneTap(zone.zoneId) }) {
                        zoneCard(zone)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.workspaceName)
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                Text(snapshot.monitorName)
                Text(snapshot.presetName ?? "default")
                if snapshot.isPresentationMode {
                    Text("presentation")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private func zoneCard(_ zone: ZonePickerZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(zone.zoneId)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if zone.isFocused {
                    Text("active")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                } else if zone.isHinted {
                    Text("next")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(zone.layout)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(zone.windowCount) window" + (zone.windowCount == 1 ? "" : "s"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(zone.isFocused ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(zone.isFocused ? Color.accentColor : Color.white.opacity(0.08), lineWidth: zone.isFocused ? 2 : 1)
        )
    }
}
