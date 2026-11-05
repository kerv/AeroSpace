import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var sponsorshipMessage: String = sponsorshipPrompts.randomElement().orDie()
    @Published var lastReloadConfigContainedWarnings: Bool = false
    @Published var axPermissionStatus: AxPermissionStatus = .waitingWithPrompt
}

enum AxPermissionStatus: Equatable {
    case granted
    case waiting
    case waitingWithPrompt
}

@MainActor func updateTrayText() {
    let sortedMonitors = sortedMonitors
    let focus = focus
    let zoneIndicator: String = {
        let zc = focus.workspace.zoneContainers
        guard !zc.isEmpty else { return "" }
        let activeZoneName: String? = if let window = focus.windowOrNil,
                                         let container = window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
        {
            zc.first { $0.value === container }?.key
        } else {
            focus.workspace.focusedZone
        }
        let parts = focus.workspace.activeZoneDefinitions.compactMap { def -> String? in
            guard zc[def.id] != nil else { return nil }
            return activeZoneName == def.id ? "[\(def.id)]" : def.id
        }
        return " : " + parts.joined(separator: " ")
    }()
    TrayMenuModel.shared.trayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        sortedMonitors
        .map {
            let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let activeWorkspaceName = hasFullscreenWindows ? "[\($0.activeWorkspace.name)]" : $0.activeWorkspace.name
            let prefix = ($0.activeWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "")
            let suffix = $0.activeWorkspace == focus.workspace ? zoneIndicator : ""
            return prefix + activeWorkspaceName + suffix
        }
        .joined(separator: " │ ")
    TrayMenuModel.shared.workspaces = Workspace.all.map {
        let apps = $0.allLeafWindowsRecursive.map { $0.app.name?.takeIf { !$0.isEmpty } }.filterNotNil().toSet()
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case $0.isVisible: dash + $0.workspaceMonitor.name
            default: ""
        }
        let hasFullscreenWindows = $0.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix,
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    let zoneContainers = focus.workspace.zoneContainers
    if !zoneContainers.isEmpty {
        let activeZoneName: String? = if let window = focus.windowOrNil,
                                         let container = window.parents.first(where: { ($0 as? TilingContainer)?.isZoneContainer == true }) as? TilingContainer
        {
            zoneContainers.first { $0.value === container }?.key
        } else {
            // Fall back to the one-shot hint set by focus-zone on an empty zone
            focus.workspace.focusedZone
        }
        for def in focus.workspace.activeZoneDefinitions {
            if zoneContainers[def.id] != nil {
                // Use the full zone ID as both the display label and the identity key so that
                // zones with the same first letter (e.g. main/messages/music) remain distinct.
                items.append(TrayItem(
                    type: .zone,
                    name: def.id,
                    isActive: activeZoneName == def.id,
                    hasFullscreenWindows: false,
                ))
            }
        }
    }
    TrayMenuModel.shared.trayItems = items
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
    case zone
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        switch Int(name) {
            case let number?: if !(0 ... 50).contains(number) { return nil }
            case nil where name.count == 1: if !validLetters.contains(name) { return nil }
            default: return nil
        }
        let lowercasedName = name.lowercased()
        return switch type {
            case .mode: "\(lowercasedName).circle"
            case .workspace where isActive, .zone where isActive: "\(lowercasedName).square.fill"
            case .workspace, .zone: "\(lowercasedName).square"
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
