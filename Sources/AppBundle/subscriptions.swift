import Common
import Foundation
import Network

private struct Subscriber {
    let connection: NWConnection
    let events: Set<ServerEventType>
}

private struct ZoneEventSnapshot: Equatable {
    let layout: String
    let windowCount: Int
}

@MainActor private var subscribers: [UniqueToken: Subscriber] = [:]
@MainActor var broadcastEventForTesting: ((ServerEvent) -> Void)? = nil
@MainActor private var lastZoneEventSnapshotsByWorkspace: [String: [String: ZoneEventSnapshot]] = [:]

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let id = UniqueToken()
    subscribers[id] = Subscriber(connection: connection, events: args.events)
    defer { subscribers.removeValue(forKey: id) }
    if args.sendInitial {
        let f = focus
        for eventType in args.events {
            let initialEvents: [ServerEvent]
            switch eventType {
                case .focusChanged:
                    let focusedZoneName: String? = f.windowOrNil.flatMap { window in
                        zoneName(for: window, in: f.workspace)
                    }
                    initialEvents = [.focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name, appName: f.windowOrNil?.app.name, zoneName: focusedZoneName)]
                case .workspaceChanged:
                    initialEvents = [.workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)]
                case .modeChanged:
                    initialEvents = [.modeChanged(mode: activeMode)]
                case .focusedMonitorChanged:
                    initialEvents = [.focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
                    )]
                case .zoneFocused:
                    guard let zoneName = activeZoneName(in: f.workspace) else { continue }
                    initialEvents = [.zoneFocused(workspace: f.workspace.name, zoneName: zoneName)]
                case .zonePresetChanged:
                    initialEvents = [.zonePresetChanged(workspace: f.workspace.name, presetName: activeZonePresetName)]
                case .zoneLayoutChanged:
                    initialEvents = snapshotZones(in: f.workspace).map {
                        .zoneLayoutChanged(workspace: $0.workspace, zoneName: $0.zoneId, layout: $0.layout)
                    }
                case .zoneWindowCountChanged:
                    initialEvents = snapshotZones(in: f.workspace).map {
                        .zoneWindowCountChanged(workspace: $0.workspace, zoneName: $0.zoneId, windowCount: $0.windowCount)
                    }
                case .windowDetected, .windowRouted, .bindingTriggered: continue
                case .monitorChanged:
                    initialEvents = [.monitorChanged(monitorCount: monitors.count)]
            }
            for event in initialEvents {
                if await connection.writeAtomic(event, jsonEncoder).error != nil {
                    return
                }
            }
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

func broadcastEvent(_ event: ServerEvent) {
    Task.startUnstructured { @MainActor in
        broadcastEventForTesting?(event)
        for (id, subscriber) in subscribers {
            guard subscriber.events.contains(event.eventType) else { continue }
            if await subscriber.connection.writeAtomic(event, jsonEncoder).error != nil {
                _ = subscribers.removeValue(forKey: id)
            }
        }
    }
}

@MainActor
func primeZoneEventBroadcastTracking() {
    lastZoneEventSnapshotsByWorkspace = currentZoneEventSnapshotsByWorkspace()
}

@MainActor
func broadcastZoneStateChangesIfNeeded() {
    let current = currentZoneEventSnapshotsByWorkspace()
    defer { lastZoneEventSnapshotsByWorkspace = current }
    if refreshSessionEvent?.isStartup == true { return }

    let workspaceNames = Set(lastZoneEventSnapshotsByWorkspace.keys).union(current.keys).sorted()
    for workspaceName in workspaceNames {
        let oldSnapshots = lastZoneEventSnapshotsByWorkspace[workspaceName] ?? [:]
        let newSnapshots = current[workspaceName] ?? [:]
        let orderedZoneNames = zoneEventSnapshotOrder(forWorkspaceNamed: workspaceName, oldSnapshots: oldSnapshots, newSnapshots: newSnapshots)
        for zoneName in orderedZoneNames {
            let oldSnapshot = oldSnapshots[zoneName]
            guard let newSnapshot = newSnapshots[zoneName] else { continue }
            if oldSnapshot?.layout != newSnapshot.layout {
                broadcastEvent(.zoneLayoutChanged(workspace: workspaceName, zoneName: zoneName, layout: newSnapshot.layout))
            }
            if oldSnapshot?.windowCount != newSnapshot.windowCount {
                broadcastEvent(.zoneWindowCountChanged(workspace: workspaceName, zoneName: zoneName, windowCount: newSnapshot.windowCount))
            }
        }
    }
}

@MainActor
private func currentZoneEventSnapshotsByWorkspace() -> [String: [String: ZoneEventSnapshot]] {
    Dictionary(uniqueKeysWithValues: Workspace.all.map { workspace in
        let snapshots = Dictionary(uniqueKeysWithValues: snapshotZones(in: workspace).map {
            ($0.zoneId, ZoneEventSnapshot(layout: $0.layout, windowCount: $0.windowCount))
        })
        return (workspace.name, snapshots)
    })
}

@MainActor
private func zoneEventSnapshotOrder(
    forWorkspaceNamed workspaceName: String,
    oldSnapshots: [String: ZoneEventSnapshot],
    newSnapshots: [String: ZoneEventSnapshot]
) -> [String] {
    let preferred = Workspace.all
        .first(where: { $0.name == workspaceName })?
        .activeZoneDefinitions
        .map(\.id) ?? []
    let extras = Set(oldSnapshots.keys)
        .union(newSnapshots.keys)
        .subtracting(preferred)
        .sorted()
    return preferred + extras
}
