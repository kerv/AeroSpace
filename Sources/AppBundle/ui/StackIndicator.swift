import AppKit
import Common
import SwiftUI

/// Manages overlay panels that show the window list for stack-layout zone containers.
@MainActor
final class StackIndicatorManager {
    static let shared = StackIndicatorManager()

    private var panels: [ObjectIdentifier: StackIndicatorPanel] = [:]

    private init() {}

    func refresh() {
        guard config.stackIndicator.enabled else {
            hideAll()
            return
        }

        var activeContainerIds: Set<ObjectIdentifier> = []

        for workspace in Workspace.all where workspace.isVisible {
            collectStackContainers(workspace.rootTilingContainer, into: &activeContainerIds)
        }

        for (id, panel) in panels where !activeContainerIds.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
        }
    }

    private func collectStackContainers(_ node: TreeNode, into ids: inout Set<ObjectIdentifier>) {
        guard let container = node as? TilingContainer else { return }
        if container.isZoneContainer && container.layout == .stack && !container.children.isEmpty {
            let id = ObjectIdentifier(container)
            ids.insert(id)
            updatePanel(for: container, id: id)
        }
        for child in container.children {
            collectStackContainers(child, into: &ids)
        }
    }

    private func updatePanel(for container: TilingContainer, id: ObjectIdentifier) {
        guard let contentRect = container.lastAppliedLayoutPhysicalRect else { return }
        // One tab entry per direct child slot; if the child is a container, represent it
        // by its most-recently-focused window so nested subtrees get a valid entry.
        let windows = container.children.compactMap { $0.mostRecentWindowRecursive }
        guard !windows.isEmpty else { return }

        let activeWindow = container.mostRecentChild?.mostRecentWindowRecursive
        let ind = config.stackIndicator
        let iconSize = CGFloat(ind.iconSize)
        let iconPadding = CGFloat(ind.iconPadding)
        let barPadding = CGFloat(ind.barPadding)
        let barHeight = CGFloat(ind.barHeight)
        let barMargin: CGFloat = 4 // must match layoutRecursive.swift

        let entries: [StackIndicatorEntry] = windows.map { window in
            let icon: NSImage = if let macWindow = window as? MacWindow {
                macWindow.macApp.nsApp.icon ?? NSImage(named: NSImage.applicationIconName)!
            } else {
                NSImage(named: NSImage.applicationIconName)!
            }
            let title: String = if let macWindow = window as? MacWindow {
                macWindow.cachedTitle.isEmpty
                    ? (macWindow.macApp.nsApp.localizedName ?? "")
                    : macWindow.cachedTitle
            } else {
                ""
            }
            return StackIndicatorEntry(
                windowId: window.windowId,
                icon: icon,
                title: title,
                isActive: window === activeWindow,
            )
        }

        // Compute bar frame from content rect + indicator position
        let position = ind.position
        let panelX: CGFloat
        let panelY: CGFloat
        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let isHorizontalBar: Bool

        switch position {
            case .top:
                isHorizontalBar = true
                panelX = contentRect.topLeftX
                panelY = screenFlipY(contentRect.topLeftY - barMargin - barHeight, height: barHeight)
                panelWidth = contentRect.width
                panelHeight = barHeight
            case .bottom:
                isHorizontalBar = true
                panelX = contentRect.topLeftX
                panelY = screenFlipY(contentRect.topLeftY + contentRect.height + barMargin, height: barHeight)
                panelWidth = contentRect.width
                panelHeight = barHeight
            case .left:
                isHorizontalBar = false
                panelX = contentRect.topLeftX - barMargin - barHeight
                panelY = screenFlipY(contentRect.topLeftY, height: contentRect.height)
                panelWidth = barHeight
                panelHeight = contentRect.height
            case .right:
                isHorizontalBar = false
                panelX = contentRect.topLeftX + contentRect.width + barMargin
                panelY = screenFlipY(contentRect.topLeftY, height: contentRect.height)
                panelWidth = barHeight
                panelHeight = contentRect.height
        }

        let model = StackIndicatorModel(
            entries: entries,
            isHorizontalBar: isHorizontalBar,
            iconSize: iconSize,
            iconPadding: iconPadding,
            barPadding: barPadding,
            showTitle: ind.showTitle,
            onEntryClick: { windowId in
                Task { @MainActor in
                    if let window = Window.get(byId: windowId) {
                        _ = window.focusWindow()
                        window.nativeFocus()
                        scheduleCancellableCompleteRefreshSession(.menuBarButton)
                    }
                }
            },
        )

        let panel: StackIndicatorPanel
        if let existing = panels[id] {
            panel = existing
        } else {
            panel = StackIndicatorPanel()
            panels[id] = panel
        }

        let hostingView = NSHostingView(rootView: StackIndicatorView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView?.subviews.removeAll()
        panel.contentView?.addSubview(hostingView)
        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)
        panel.orderFrontRegardless()
    }

    func hideAll() {
        for (_, panel) in panels { panel.close() }
        panels.removeAll()
    }

    /// Convert AeroSpace top-left Y coordinate to macOS bottom-left Y coordinate.
    private func screenFlipY(_ topLeftY: CGFloat, height: CGFloat) -> CGFloat {
        let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? mainMonitor.height
        return screenH - topLeftY - height
    }
}

// MARK: - Panel

final class StackIndicatorPanel: NSPanelHud {
    override init() {
        super.init()
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.canHide = false
        self.styleMask.insert(.nonactivatingPanel)
        self.becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Data Model

struct StackIndicatorEntry: Identifiable {
    let windowId: UInt32
    let icon: NSImage
    let title: String
    let isActive: Bool
    var id: UInt32 { windowId }
}

struct StackIndicatorModel {
    let entries: [StackIndicatorEntry]
    let isHorizontalBar: Bool
    let iconSize: CGFloat
    let iconPadding: CGFloat
    let barPadding: CGFloat
    let showTitle: Bool
    let onEntryClick: (UInt32) -> Void
}

// MARK: - SwiftUI View

struct StackIndicatorView: View {
    let model: StackIndicatorModel

    var body: some View {
        Group {
            if model.isHorizontalBar {
                HStack(spacing: 0) {
                    entryViews
                }
            } else {
                VStack(spacing: 0) {
                    entryViews
                }
            }
        }
        .padding(model.barPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var entryViews: some View {
        ForEach(model.entries) { entry in
            StackEntryView(
                entry: entry,
                isHorizontal: model.isHorizontalBar,
                iconSize: model.iconSize,
                iconPadding: model.iconPadding,
                showTitle: model.showTitle,
                onTap: { model.onEntryClick(entry.windowId) },
            )
        }
    }
}

struct StackEntryView: View {
    let entry: StackIndicatorEntry
    let isHorizontal: Bool
    let iconSize: CGFloat
    let iconPadding: CGFloat
    let showTitle: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if isHorizontal {
                HStack(spacing: 4) {
                    iconView
                    if showTitle {
                        Text(entry.title)
                            .font(.system(size: 11, weight: entry.isActive ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(entry.isActive ? Color.primary : Color.secondary)
                    }
                }
                .padding(.horizontal, iconPadding)
                .padding(.vertical, 2)
            } else {
                VStack(spacing: 2) {
                    iconView
                    if showTitle {
                        Text(entry.title)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(entry.isActive ? Color.primary : Color.secondary)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, iconPadding)
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(entry.isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(entry.isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .opacity(entry.isActive ? 1.0 : 0.6)
    }

    private var iconView: some View {
        Image(nsImage: entry.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSize, height: iconSize)
    }
}

// MARK: - Config Parsing

private let stackIndicatorParser: [String: any ParserProtocol<StackIndicatorConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "icon-size": Parser(\.iconSize, parseInt),
    "icon-padding": Parser(\.iconPadding, parseInt),
    "bar-padding": Parser(\.barPadding, parseInt),
    "bar-height": Parser(\.barHeight, parseInt),
    "position": Parser(\.position, parseStackIndicatorPosition),
    "show-title": Parser(\.showTitle, parseBool),
]

func parseStackIndicator(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> StackIndicatorConfig {
    parseTable(raw, StackIndicatorConfig(), stackIndicatorParser, backtrace, &c)
}

private func parseStackIndicatorPosition(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<StackIndicatorPosition> {
    parseString(raw, backtrace).flatMap {
        StackIndicatorPosition(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse stack indicator position '\($0)'. Expected: top, bottom, left, right"))
    }
}
