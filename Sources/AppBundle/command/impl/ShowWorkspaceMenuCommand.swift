import AppKit
import Common

struct ShowWorkspaceMenuCommand: Command {
    let args: ShowWorkspaceMenuCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        // NSMenu.popUp uses AppKit screen coordinates (origin at bottom-left, Y up).
        // AX rects use CG coordinates (origin at top-left of the primary display, Y down).
        // Must use the primary screen (frame.origin == .zero), not NSScreen.main (the focused screen),
        // otherwise the Y offset is wrong when a secondary monitor is focused.
        let mainScreenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? 0
        let popupPoint: CGPoint
        if let window = focus.windowOrNil,
           let rect = try? await window.getAxRect(.nonCancellable)
        {
            popupPoint = CGPoint(x: rect.center.x, y: mainScreenHeight - rect.center.y)
        } else {
            let r = focus.workspace.workspaceMonitor.visibleRect
            popupPoint = CGPoint(x: r.center.x, y: mainScreenHeight - r.center.y)
        }

        let delegate = WorkspaceMenuTarget()
        let menu = NSMenu()

        for ws in TrayMenuModel.shared.workspaces {
            let item = NSMenuItem(
                title: ws.name + ws.suffix,
                action: #selector(WorkspaceMenuTarget.select(_:)),
                keyEquivalent: "",
            )
            item.target = delegate
            item.representedObject = ws.name
            item.state = ws.isFocused ? .on : .off
            item.attributedTitle = NSAttributedString(
                string: ws.name + ws.suffix,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)],
            )
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: popupPoint, in: nil)

        if let name = delegate.selectedName {
            _ = Workspace.get(byName: name).focusWorkspace()
        }
        return .succ
    }
}

@MainActor
private final class WorkspaceMenuTarget: NSObject {
    var selectedName: String?

    @objc func select(_ sender: NSMenuItem) {
        selectedName = sender.representedObject as? String
    }
}
