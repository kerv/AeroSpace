import AppKit
import Common

/// Manages transparent overlay panels that draw borders around tiling and floating windows.
@MainActor
final class BorderController {
    static let shared = BorderController()
    private var panels: [UInt32: BorderPanel] = [:]
    private init() {}

    /// Synchronize border panels with the current window layout and focus state.
    /// Call this after every layout pass.
    func sync() async {
        guard config.borders.enabled else {
            removeAll()
            return
        }
        let cfg = config.borders
        let focusedId = focus.windowOrNil?.windowId
        // Cache once per sync pass: height of the primary screen (CG origin at top-left of this
        // screen). Using NSScreen.main would give the focused screen's height, which is wrong for
        // the CG→AppKit Y-flip formula when the focused screen differs from the primary screen.
        let primaryScreenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? mainMonitor.height
        var seen: Set<UInt32> = []

        for workspace in Workspace.all where workspace.isVisible {
            for window in workspace.allLeafWindowsRecursive {
                guard let mac = window as? MacWindow, !mac.isHiddenInCorner else { continue }
                if let bid = mac.macApp.rawAppBundleId, cfg.ignoredApps.contains(bid) { continue }

                // Tiling windows have a rect from the layout pass.
                // Floating windows (parent is Workspace) get their rect via the AX API.
                // Everything else (minimized, hidden, popup, fullscreen) is skipped.
                let rect: Rect
                if let layoutRect = mac.lastAppliedLayoutPhysicalRect {
                    rect = layoutRect
                } else if mac.isFloating {
                    guard let axRect = try? await mac.getAxRect(.nonCancellable) else { continue }
                    rect = axRect
                } else {
                    continue
                }

                let isFocused = window.windowId == focusedId
                let color: AeroColor
                if isFocused {
                    color = cfg.activeColor
                } else {
                    guard !cfg.inactiveColor.isTransparent else { continue }
                    color = cfg.inactiveColor
                }

                seen.insert(window.windowId)
                let nsFrame = axRectToNSFrame(rect, borderWidth: cfg.width, screenH: primaryScreenH)

                if let panel = panels[window.windowId] {
                    panel.update(frame: nsFrame, color: color, width: cfg.width)
                    if isFocused { panel.orderFront(nil) }
                } else {
                    let panel = BorderPanel(frame: nsFrame, color: color, width: cfg.width)
                    panels[window.windowId] = panel
                    panel.orderFront(nil)
                }
            }
        }

        for windowId in Set(panels.keys).subtracting(seen) {
            panels[windowId]?.orderOut(nil)
            panels.removeValue(forKey: windowId)
        }
    }

    func removeBorder(windowId: UInt32) {
        panels[windowId]?.orderOut(nil)
        panels.removeValue(forKey: windowId)
    }

    private func removeAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

/// Convert an AX-coordinate Rect (top-left origin, Y down) to an NSWindow frame
/// (bottom-left origin, Y up), expanded by borderWidth/2 on all sides so a centered
/// stroke of `borderWidth` lines up exactly with the window edge.
private func axRectToNSFrame(_ rect: Rect, borderWidth: Double, screenH: CGFloat) -> CGRect {
    let exp = CGFloat(borderWidth) / 2
    let nsY = screenH - rect.topLeftY - rect.height
    return CGRect(
        x: rect.topLeftX - exp,
        y: nsY - exp,
        width: rect.width + CGFloat(borderWidth),
        height: rect.height + CGFloat(borderWidth),
    )
}

// MARK: - BorderPanel

private final class BorderPanel: NSPanel {
    private let shapeLayer = CAShapeLayer()

    init(frame: CGRect, color: AeroColor, width: Double) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        // Use one above normal rather than .floating so that always-on-top windows
        // like PiP are not obscured by the border overlay.
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        // Match ZoneHUDController: .fullScreenAuxiliary keeps panels visible during
        // full-screen transitions; .stationary caused panels to not show on space changes.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        hasShadow = false

        shapeLayer.fillColor = nil
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        contentView = view
        view.layer?.addSublayer(shapeLayer)

        applyStyle(size: frame.size, color: color, width: width, cornerRadius: config.borders.cornerRadius)
    }

    func update(frame newFrame: CGRect, color: AeroColor, width: Double) {
        if self.frame != newFrame {
            setFrame(newFrame, display: true)
        }
        applyStyle(size: newFrame.size, color: color, width: width, cornerRadius: config.borders.cornerRadius)
    }

    func applyStyle(size: CGSize, color: AeroColor, width: Double, cornerRadius: Double) {
        let lw = CGFloat(width)
        let inset = lw / 2
        let r = max(0, CGFloat(cornerRadius) - inset) // shrink radius so outer edge matches window corner
        shapeLayer.frame = CGRect(origin: .zero, size: size)
        shapeLayer.path = CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: size.width - lw, height: size.height - lw),
            cornerWidth: r,
            cornerHeight: r,
            transform: nil,
        )
        shapeLayer.strokeColor = color.cgColor
        shapeLayer.lineWidth = lw
    }
}
