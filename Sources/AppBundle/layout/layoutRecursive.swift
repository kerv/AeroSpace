import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                // Apply per-zone outer-gap overrides. Each override is absolute (pixels from screen edge),
                // so the delta is (override - global). A value below the global expands the zone toward the edge.
                var layoutPoint = point
                var layoutWidth = width
                var layoutHeight = height
                if container.isZoneContainer,
                   let zoneName = context.workspace.zoneContainers.first(where: { $0.value === container })?.key,
                   let ov = config.zones.overrides[zoneName]
                {
                    let g = context.resolvedGaps.outer
                    let dTop    = CGFloat((ov.top    ?? g.top)    - g.top)
                    let dBottom = CGFloat((ov.bottom ?? g.bottom) - g.bottom)
                    let dLeft   = CGFloat((ov.left   ?? g.left)   - g.left)
                    let dRight  = CGFloat((ov.right  ?? g.right)  - g.right)
                    layoutPoint.x += dLeft
                    layoutPoint.y += dTop
                    layoutWidth  -= dLeft + dRight
                    layoutHeight -= dTop  + dBottom
                }
                // Reserve space for the accordion indicator overlay when it will be shown.
                // The indicator only appears for accordion zones with >1 window, so only inset then.
                // Update lastAppliedLayoutPhysicalRect to the inset rect so AccordionIndicatorManager
                // anchors the overlay panel flush with the zone edge rather than outside it.
                if container.isZoneContainer,
                   container.layout == .accordion,
                   container.children.count > 1,
                   config.accordionIndicator.enabled
                {
                    let indicatorMargin: CGFloat = 4 // must match AccordionIndicator.swift
                    let ind = config.accordionIndicator
                    let inset = CGFloat(ind.iconSize + ind.barPadding * 2) + indicatorMargin
                    switch ind.position {
                        case .left:
                            layoutPoint.x += inset
                            layoutWidth  -= inset
                        case .right:
                            layoutWidth  -= inset
                        case .top:
                            layoutPoint.y += inset
                            layoutHeight -= inset
                        case .bottom:
                            layoutHeight -= inset
                    }
                    lastAppliedLayoutPhysicalRect = Rect(
                        topLeftX: layoutPoint.x, topLeftY: layoutPoint.y,
                        width: layoutWidth, height: layoutHeight,
                    )
                }
                // Reserve space for the stack indicator bar when it will be shown.
                // The bar is anchored inside the zone; content is inset away from the bar edge.
                // Update lastAppliedLayoutPhysicalRect to the inset (content) rect so
                // StackIndicatorManager can compute the bar position relative to content.
                if container.isZoneContainer,
                   container.layout == .stack,
                   !container.children.isEmpty,
                   config.stackIndicator.enabled
                {
                    let ind = config.stackIndicator
                    let barMargin: CGFloat = 4 // must match StackIndicator.swift
                    let barInset = CGFloat(ind.barHeight) + barMargin
                    switch ind.position {
                        case .top:
                            layoutPoint.y += barInset
                            layoutHeight  -= barInset
                        case .bottom:
                            layoutHeight  -= barInset
                        case .left:
                            layoutPoint.x += barInset
                            layoutWidth   -= barInset
                        case .right:
                            layoutWidth   -= barInset
                    }
                    lastAppliedLayoutPhysicalRect = Rect(
                        topLeftX: layoutPoint.x, topLeftY: layoutPoint.y,
                        width: layoutWidth, height: layoutHeight,
                    )
                }
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(layoutPoint, width: layoutWidth, height: layoutHeight, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(layoutPoint, width: layoutWidth, height: layoutHeight, virtual: virtual, context)
                    case .stack:
                        try await container.layoutStack(layoutPoint, width: layoutWidth, height: layoutHeight, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = (child as? TilingContainer)?.isZoneContainer == true
                ? Double(config.zones.gap)
                : context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let n = children.count
        if config.accordion.mode == .cascade && n > 1 {
            let offsetX = CGFloat(config.accordion.offsetX)
            let offsetY = CGFloat(config.accordion.offsetY)
            let totalOffsetX = offsetX * CGFloat(n - 1)
            let totalOffsetY = offsetY * CGFloat(n - 1)
            let windowWidth = max(1, width - totalOffsetX)
            let windowHeight = max(1, height - totalOffsetY)
            for (i, child) in children.enumerated() {
                try await child.layoutRecursive(
                    point + CGPoint(x: CGFloat(i) * offsetX, y: CGFloat(i) * offsetY),
                    width: windowWidth,
                    height: windowHeight,
                    virtual: virtual,
                    context,
                )
            }
        } else {
            guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
            for (index, child) in children.enumerated() {
                let padding = CGFloat(config.accordion.padding)
                let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                    case 0 where n == 1:        (0, 0)
                    case 0:                     (0, padding)
                    case n - 1:                 (padding, 0)
                    case mruIndex - 1:          (0, 2 * padding)
                    case mruIndex + 1:          (2 * padding, 0)
                    default:                    (padding, padding)
                }
                switch orientation {
                    case .h:
                        try await child.layoutRecursive(
                            point + CGPoint(x: lPadding, y: 0),
                            width: width - rPadding - lPadding,
                            height: height,
                            virtual: virtual,
                            context,
                        )
                    case .v:
                        try await child.layoutRecursive(
                            point + CGPoint(x: 0, y: lPadding),
                            width: width,
                            height: height - lPadding - rPadding,
                            virtual: virtual,
                            context,
                        )
                }
            }
        }
    }

    /// Stack layout: all children occupy the same rect (stacked on top of each other).
    /// Only the most-recently-focused child is visible; others are behind it in z-order.
    /// The active child is laid out last so macOS window focus brings it to the front.
    @MainActor
    fileprivate func layoutStack(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let activeChild = mostRecentChild
        for child in children where child !== activeChild {
            try await child.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
        }
        if let activeChild {
            try await activeChild.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
        }
    }
}
