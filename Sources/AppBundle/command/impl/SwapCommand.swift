import AppKit
import Common

struct SwapCommand: Command {
    let args: SwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else {
            return .fail
        }

        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }

        let targetWindow: Window?
        switch args.target.val {
            case .direction(let direction):
                switch currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    case let (parent, ownIndex)?:
                        targetWindow = parent.children[ownIndex + direction.containerFocusOffset(parent)].findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil where args.wrapAround:
                        targetWindow = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil:
                        return .fail
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return .fail
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    if !args.wrapAround {
                        return .fail
                    }
                    targetIndex = (targetIndex + windows.count) % windows.count
                }
                targetWindow = windows[targetIndex]
        }

        guard let targetWindow else {
            return .fail
        }

        swapWindows(mruDominant: currentWindow, targetWindow)

        if args.swapFocus {
            return .from(bool: targetWindow.focusWindow())
        }
        // Without --swap-focus the focused window stays the same but swapWindows rebinds
        // trigger MRU updates on each bind(). Restore currentWindow as MRU so it stays
        // visible in any stack container it landed in after the swap.
        currentWindow.markAsMostRecentChild()
        return .succ
    }
}
