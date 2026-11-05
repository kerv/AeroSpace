import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    var layout: Layout
    var isZoneContainer: Bool = false

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self.layout = layout
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            for container in parentsWithSelf.filterIsInstance(of: TilingContainer.self) {
                container._orientation = orientation
                if container.isZoneContainer { break }
                orientation = orientation.opposite
            }
        } else {
            _orientation = targetOrientation
        }
    }

    func normalizeOppositeOrientationForNestedContainers() {
        if !isZoneContainer && orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

enum Layout: String {
    case tiles
    case accordion
    case stack
}

extension TilingContainer {
    /// Whether a direction matches this container for navigation purposes.
    /// Stack containers always match up/down (cycling through the stack) and never match
    /// left/right (so those pass through to the parent for zone-level navigation).
    /// When `accordion-indicator.vertical-navigation` is enabled, accordion containers
    /// accept up/down directions regardless of their actual orientation.
    @MainActor
    func matchesDirection(_ direction: CardinalDirection) -> Bool {
        if layout == .stack {
            return direction.orientation == .v // up/down cycle within stack; left/right navigate zones
        }
        if config.accordionIndicator.accordionVerticalNavigation && layout == .accordion && direction.orientation == .v {
            return true
        }
        return orientation == direction.orientation
    }
}

extension CardinalDirection {
    /// Returns the focus offset for navigating within a container.
    /// Stack containers: up = previous (-1), down = next (+1).
    /// When vertical navigation is enabled for accordion, up/down map to previous/next.
    @MainActor
    func containerFocusOffset(_ container: TilingContainer) -> Int {
        if container.layout == .stack && orientation == .v {
            return self == .up ? -1 : 1
        }
        if config.accordionIndicator.accordionVerticalNavigation && container.layout == .accordion && orientation == .v {
            return self == .up ? -1 : 1
        }
        return focusOffset
    }

}

extension String {
    func parseLayout() -> Layout? {
        switch Layout(rawValue: self) {
            case let parsed?: parsed
            case nil where self == "list": .tiles
            case nil: nil
        }
    }
}
