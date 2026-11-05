import AppKit
import Common

struct LayoutCommand: Command {
    let args: LayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let node: ConventionalWindowParentCases
        if args.zone {
            let workspace = target.workspace
            var zone = target.windowOrNil.flatMap { workspace.zoneContaining($0)?.container }
            if zone == nil, let window = target.windowOrNil, window.isFloating,
               let rect = try? await window.getAxRect(.nonCancellable), let name = workspace.zoneForWindowRect(rect) {
                zone = workspace.zoneContainers[name]
            }
            if zone == nil, let name = workspace.focusedZone { zone = workspace.zoneContainers[name] }
            guard let zone = zone ?? (workspace.zoneContainers.isEmpty ? workspace.rootTilingContainer : nil) else {
                return .fail(io.err("No zone found for the focused window"))
            }
            node = .tilingContainer(zone)
        } else { switch args.root ? nil : target.windowOrNil {
            case let window?:
                switch window.windowParentCases {
                    case .floatingWindowsContainer(let it):
                        node = .floatingWindowsContainer(it)
                    case .tilingContainer(let it):
                        node = .tilingContainer(it)
                    case .macosFullscreenWindowsContainer,
                         .macosHiddenAppsWindowsContainer,
                         .macosMinimizedWindowsContainer:
                        let msg = "Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. " +
                            "This behavior is subject to change"
                        return .fail(io.err(msg))
                    case .unbound, .macosPopupWindowsContainer:
                        return .fail(io.err(bugPrompt()))
                }
            case nil:
                node = .tilingContainer(target.workspace.rootTilingContainer)
        } }

        let descriptions = args.toggleBetween.val
        let targetDescription: LayoutCmdArgs.LayoutDescription
        if args.cycle, let index = descriptions.firstIndex(where: { node.matchesDescription($0, window: target.windowOrNil) }) {
            targetDescription = descriptions[(index + 1) % descriptions.count]
        } else {
            targetDescription = descriptions.first(where: { !node.matchesDescription($0, window: target.windowOrNil) })
                ?? descriptions.first.orDie()
        }
        if node.matchesDescription(targetDescription, window: target.windowOrNil) {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = "Already in the requested \(targetDescription.rawValue) mode. " +
                        "Tip: use --fail-if-noop to exit with non-zero exit code"
                    return .succ(io.err(msg))
            }
        }
        switch targetDescription {
            case .h_accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: .h, node: node)
            case .v_accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: .v, node: node)
            case .h_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .h, node: node)
            case .v_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .v, node: node)
            case .accordion:
                return changeTilingLayout(io, targetLayout: .accordion, targetOrientation: nil, node: node)
            case .tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: nil, node: node)
            case .stack:
                return changeTilingLayout(io, targetLayout: .stack, targetOrientation: nil, node: node)
            case .horizontal:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .h, node: node)
            case .vertical:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .v, node: node)
            case .tiling:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                switch node {
                    case .tilingContainer:
                        return .succ // Nothing to do
                    case .floatingWindowsContainer(let container):
                        await rememberFloatingGeometry(window)
                        window.lastFloatingSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
                        guard let workspace = container.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
                        FloatingMemory.shared.forget(windowId: window.windowId)
                        StickyMemory.shared.forget(windowId: window.windowId)
                        do {
                            try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
                        } catch {
                            return .fail(io.err(bugPrompt()))
                        }
                        return .succ
                }
            case .floating:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                let workspace = target.workspace
                let zoneRect = workspace.zoneContaining(window)?.container.lastAppliedLayoutPhysicalRect
                    ?? workspace.zoneContaining(window).flatMap { workspace.theoreticalZoneRect(for: $0.name) }
                    ?? workspace.workspaceMonitor.visibleRect
                let frame = rememberedFloatingFrame(for: window, in: workspace, zone: zoneRect)
                    ?? centeredFloatingFrame(in: zoneRect, previousSize: window.lastFloatingSize)
                rememberWindowPlacement(window)
                window.bindAsFloatingWindow(to: workspace)
                FloatingMemory.shared.remember(windowId: window.windowId)
                StickyMemory.shared.forget(windowId: window.windowId)
                window.setAxFrame(frame.origin, frame.size)
                return .succ
            case .sticky:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                let workspace = target.workspace
                window.bindAsFloatingWindow(to: workspace)
                FloatingMemory.shared.remember(windowId: window.windowId)
                StickyMemory.shared.remember(windowId: window.windowId)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
                return .succ
        }
    }
}

func centeredFloatingFrame(in rect: Rect, previousSize: CGSize?) -> CGRect {
    let fallback = CGSize(width: min(rect.width * 0.75, 1100), height: min(rect.height * 0.7, 800))
    // On app startup the initial AX size can be the existing tiled frame rather
    // than a deliberately chosen floating size. Don't restore a zone-filling frame.
    let saved = previousSize.flatMap {
        $0.width > 0 && $0.height > 0 && $0.width < rect.width * 0.95 && $0.height < rect.height * 0.95 ? $0 : nil
    } ?? fallback
    let size = CGSize(width: min(saved.width, rect.width), height: min(saved.height, rect.height))
    return CGRect(x: rect.minX + (rect.width - size.width) / 2,
                  y: rect.minY + (rect.height - size.height) / 2,
                  width: size.width, height: size.height)
}

@MainActor private func changeTilingLayout(
    _ io: CmdIo,
    targetLayout: Layout?,
    targetOrientation: Orientation?,
    node: ConventionalWindowParentCases,
) -> BinaryExitCode {
    switch node {
        case .floatingWindowsContainer:
            return .fail(io.err("The window is non-tiling"))
        case .tilingContainer(let parent):
            let targetOrientation = targetOrientation ?? parent.orientation
            let targetLayout = targetLayout ?? parent.layout
            parent.layout = targetLayout
            parent.changeOrientation(targetOrientation)
            parent.nodeWorkspace?.rememberDockedZoneLayout()
            return .succ
    }
}

extension ConventionalWindowParentCases {
    @MainActor fileprivate func matchesDescription(_ layout: LayoutCmdArgs.LayoutDescription, window: Window?) -> Bool {
        return switch layout {
            case .accordion:   tilingContainerOrNil?.layout == .accordion
            case .stack:       tilingContainerOrNil?.layout == .stack
            case .sticky:      floatingWindowsContainerOrNil != nil && window.map { StickyMemory.shared.isRemembered(windowId: $0.windowId) } == true
            case .tiles:       tilingContainerOrNil?.layout == .tiles
            case .horizontal:  tilingContainerOrNil?.orientation == .h
            case .vertical:    tilingContainerOrNil?.orientation == .v
            case .h_accordion: tilingContainerOrNil.map { $0.layout == .accordion && $0.orientation == .h } == true
            case .v_accordion: tilingContainerOrNil.map { $0.layout == .accordion && $0.orientation == .v } == true
            case .h_tiles:     tilingContainerOrNil.map { $0.layout == .tiles && $0.orientation == .h } == true
            case .v_tiles:     tilingContainerOrNil.map { $0.layout == .tiles && $0.orientation == .v } == true
            case .tiling:      tilingContainerOrNil != nil
            case .floating:    floatingWindowsContainerOrNil != nil && window.map { !StickyMemory.shared.isRemembered(windowId: $0.windowId) } == true
        }
    }
}
