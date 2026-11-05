import AppKit
import Common

struct SendToScratchpadCommand: Command {
    let args: SendToScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let parent = window.parent else { return .fail }
        switch parent.cases {
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err("Can't send minimized, fullscreen, or hidden-app windows to the scratchpad"))
            case .macosPopupWindowsContainer:
                return .fail(io.err("Can't send popup windows to the scratchpad"))
            case .tilingContainer, .workspace, .floatingWindowsContainer:
                break
        }

        // Auto-float tiling windows before sending to scratchpad
        if !window.isFloating {
            window.lastFloatingSize = try await window.getAxSize(.nonCancellable) ?? window.lastFloatingSize
            window.bindAsFloatingWindow(to: target.workspace)
            FloatingMemory.shared.remember(windowId: window.windowId)
        }

        // Save current position so it can be restored when summoned
        if let rect = try await window.getAxRect(.nonCancellable) {
            window.lastFloatingSize = rect.size
            ScratchpadMemory.shared.rememberPosition(rect.topLeftCorner, for: window.windowId)
        }

        window.bindAsFloatingWindow(to: Workspace.scratchpad)
        ScratchpadMemory.shared.remember(windowId: window.windowId)
        // Keep FloatingMemory so the window is restored as floating on restart before
        // ScratchpadMemory moves it back to the scratchpad workspace.
        FloatingMemory.shared.remember(windowId: window.windowId)
        return .succ
    }
}
