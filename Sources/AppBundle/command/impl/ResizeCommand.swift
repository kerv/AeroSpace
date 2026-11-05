import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        if args.zone {
            guard args.dimension.val == .width else { return .fail(io.err("--zone requires width")) }
            let workspace = target.workspace
            guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
            var zone = workspace.zoneContaining(window)?.container
            if zone == nil, window.isFloating, let rect = try? await window.getAxRect(.nonCancellable),
               let name = workspace.zoneForWindowRect(rect) {
                zone = workspace.zoneContainers[name]
            }
            guard let zone, let parent = zone.parent as? TilingContainer,
                  parent.layout == .tiles, parent.orientation == .h else {
                return .fail(io.err("No zone found for the focused window"))
            }
            return resize(node: zone, parent: parent, orientation: .h, io: io)
        }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        return resize(node: node, parent: parent, orientation: orientation, io: io)
    }

    @MainActor private func resize(node: TreeNode, parent: TilingContainer, orientation: Orientation, io: CmdIo) -> BinaryExitCode {
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        if args.zone && (node.getWeight(orientation) + diff <= 0 ||
            parent.children.contains(where: { $0 !== node && $0.getWeight(parent.orientation) - childDiff <= 0 })) {
            return .fail(io.err("Zone cannot be resized any further"))
        }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        node.nodeWorkspace?.rememberDockedZoneLayout()
        return .succ
    }
}
