import AppKit
import Common

enum FrozenTreeNode: Sendable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

struct FrozenContainer: Sendable {
    let children: [FrozenTreeNode]
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat
    /// Non-nil if this container is a zone container; stores the zone name (e.g. "left", "center", "right").
    let zoneName: String?

    /// Freeze the rootTilingContainer. Pass `zoneIdentityMap` so that direct zone-container children
    /// are tagged with their zone name and can be correctly restored later.
    @MainActor init(_ container: TilingContainer, zoneIdentityMap: [ObjectIdentifier: String] = [:]) {
        children = container.children.map {
            switch $0.nodeCases {
                case .window(let w): return FrozenTreeNode.window(FrozenWindow(w))
                case .tilingContainer(let c):
                    // Zone containers are direct children of rootTilingContainer; they don't have
                    // zone container descendants, so we don't need to propagate the map deeper.
                    let childZoneName = zoneIdentityMap[ObjectIdentifier(c)]
                    return FrozenTreeNode.container(FrozenContainer(c, zoneName: childZoneName))
                case .workspace, .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = getWeightOrNil(container) ?? 1
        zoneName = nil // The root container itself is never a zone container
    }

    /// Freeze a child container (zone or regular) with an explicit zone name.
    @MainActor private init(_ container: TilingContainer, zoneName: String?) {
        children = container.children.map {
            switch $0.nodeCases {
                case .window(let w): return FrozenTreeNode.window(FrozenWindow(w))
                case .tilingContainer(let c): return FrozenTreeNode.container(FrozenContainer(c, zoneName: nil))
                case .workspace, .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = getWeightOrNil(container) ?? 1
        self.zoneName = zoneName
    }
}

struct FrozenWindow: Sendable {
    let id: UInt32
    let weight: CGFloat

    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = getWeightOrNil(window) ?? 1
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}
