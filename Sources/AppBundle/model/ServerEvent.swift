import Common

public struct ServerEvent: Codable, Sendable {
    private let _event: ServerEventType

    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var windowId: UInt32?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var workspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var prevWorkspace: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var monitorId: Int? // 1-based
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appBundleId: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var appName: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var source: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var mode: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var binding: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var monitorCount: Int?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var zoneName: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var presetName: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var layout: String?
    // periphery:ignore - false positive unused warning. The var properties are serialized to JSON
    private var windowCount: Int?

    public var eventType: ServerEventType { _event }

    public static func focusChanged(windowId: UInt32?, workspace: String, appName: String?, zoneName: String? = nil) -> ServerEvent {
        ServerEvent(_event: .focusChanged, windowId: windowId, workspace: workspace, appName: appName, zoneName: zoneName)
    }

    public static func focusedMonitorChanged(workspace: String, monitorId_oneBased: Int) -> ServerEvent {
        ServerEvent(_event: .focusedMonitorChanged, workspace: workspace, monitorId: monitorId_oneBased)
    }

    public static func workspaceChanged(workspace: String, prevWorkspace: String) -> ServerEvent {
        ServerEvent(_event: .workspaceChanged, workspace: workspace, prevWorkspace: prevWorkspace)
    }

    public static func modeChanged(mode: String?) -> ServerEvent {
        ServerEvent(_event: .modeChanged, mode: mode)
    }

    public static func windowDetected(windowId: UInt32, workspace: String?, appBundleId: String?, appName: String?) -> ServerEvent {
        ServerEvent(_event: .windowDetected, windowId: windowId, workspace: workspace, appBundleId: appBundleId, appName: appName)
    }

    public static func windowRouted(windowId: UInt32, workspace: String?, appBundleId: String?, zoneName: String, source: String) -> ServerEvent {
        ServerEvent(_event: .windowRouted, windowId: windowId, workspace: workspace, appBundleId: appBundleId, source: source, zoneName: zoneName)
    }

    public static func bindingTriggered(mode: String, binding: String) -> ServerEvent {
        ServerEvent(_event: .bindingTriggered, mode: mode, binding: binding)
    }

    public static func monitorChanged(monitorCount: Int) -> ServerEvent {
        ServerEvent(_event: .monitorChanged, monitorCount: monitorCount)
    }

    public static func zoneFocused(workspace: String, zoneName: String) -> ServerEvent {
        ServerEvent(_event: .zoneFocused, workspace: workspace, zoneName: zoneName)
    }

    public static func zonePresetChanged(workspace: String, presetName: String?) -> ServerEvent {
        ServerEvent(_event: .zonePresetChanged, workspace: workspace, presetName: presetName)
    }

    public static func zoneLayoutChanged(workspace: String, zoneName: String, layout: String) -> ServerEvent {
        ServerEvent(_event: .zoneLayoutChanged, workspace: workspace, zoneName: zoneName, layout: layout)
    }

    public static func zoneWindowCountChanged(workspace: String, zoneName: String, windowCount: Int) -> ServerEvent {
        ServerEvent(_event: .zoneWindowCountChanged, workspace: workspace, zoneName: zoneName, windowCount: windowCount)
    }
}
