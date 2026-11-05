import AppKit
import Common
import Foundation

struct WorkspaceSnapshotCommand: Command {
    let args: WorkspaceSnapshotCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        do { return try await runLegacy(env, io) }
        catch { return .fail(io.err(String(describing: error))) }
    }

    @MainActor private func runLegacy(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        let name = args.name.val
        switch args.action.val {
            case .save:
                return saveSnapshot(name: name, io: io)
            case .restore:
                return WorkspaceSnapshot.restoreReturningExitCode(name: name, io: io)
        }
    }

    @MainActor private func saveSnapshot(name: String, io: CmdIo) -> BinaryExitCode {
        var workspacesJson: [[String: Any]] = []
        for workspace in Workspace.all where !workspace.isScratchpad {
            var zonesJson: [String: [[String: String]]] = [:]
            for def in workspace.activeZoneDefinitions {
                let zoneName = def.id
                guard let zone = workspace.zoneContainers[zoneName] else { continue }
                let entries = zone.allLeafWindowsRecursive
                    .compactMap { ($0 as? MacWindow)?.app.rawAppBundleId }
                    .map { ["bundleId": $0] }
                if !entries.isEmpty { zonesJson[zoneName] = entries }
            }
            let floatingEntries = workspace.children
                .compactMap { ($0 as? MacWindow)?.app.rawAppBundleId }
                .map { ["bundleId": $0] }
            var wsJson: [String: Any] = ["name": workspace.name]
            if !zonesJson.isEmpty { wsJson["zones"] = zonesJson }
            if !floatingEntries.isEmpty { wsJson["floating"] = floatingEntries }
            workspacesJson.append(wsJson)
        }
        let snapshot: [String: Any] = [
            "version": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "workspaces": workspacesJson,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else {
            return .fail(io.err("workspace-snapshot: failed to serialize snapshot"))
        }
        let url = WorkspaceSnapshot.snapshotURL(name: name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return .fail(io.err("workspace-snapshot: failed to write \(url.path): \(error)"))
        }
        io.out("Snapshot '\(name)' saved.")
        return .succ
    }
}

/// Shared restore logic used by both WorkspaceSnapshotCommand and on-monitor-connected hooks.
enum WorkspaceSnapshot {
    enum SnapshotError: Error { case notFound }

    static func snapshotURL(name: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AeroSpace/snapshots/\(name).json")
    }

    @MainActor
    static func restore(name: String) throws {
        let url = snapshotURL(name: name)
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.notFound }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspacesArr = root["workspaces"] as? [[String: Any]]
        else { return }

        // Track which windows we've already placed to avoid double-binding.
        var placed: Set<ObjectIdentifier> = []

        for wsJson in workspacesArr {
            guard let wsName = wsJson["name"] as? String else { continue }
            let workspace = Workspace.get(byName: wsName)
            if let zonesJson = wsJson["zones"] as? [String: [[String: String]]] {
                for (zoneName, entries) in zonesJson {
                    guard let zone = workspace.zoneContainers[zoneName] else { continue }
                    for entry in entries {
                        guard let bundleId = entry["bundleId"] else { continue }
                        if let window = findWindow(bundleId: bundleId, placed: &placed) {
                            window.bind(to: zone, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                        }
                    }
                }
            }
            // Restore floating windows: bind directly to the workspace node (makes them floating children).
            if let floatingEntries = wsJson["floating"] as? [[String: String]] {
                for entry in floatingEntries {
                    guard let bundleId = entry["bundleId"] else { continue }
                    if let window = findWindow(bundleId: bundleId, placed: &placed) {
                        window.bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    }
                }
            }
        }
    }

    @MainActor
    static func restoreReturningExitCode(name: String, io: CmdIo) -> BinaryExitCode {
        do {
            try restore(name: name)
            io.out("Snapshot '\(name)' restored.")
            return .succ
        } catch SnapshotError.notFound {
            return .fail(io.err("workspace-snapshot: no snapshot named '\(name)' found at \(snapshotURL(name: name).path)"))
        } catch {
            return .fail(io.err("workspace-snapshot: restore failed: \(error)"))
        }
    }

    @MainActor private static func findWindow(bundleId: String, placed: inout Set<ObjectIdentifier>) -> MacWindow? {
        for window in MacWindow.allWindows {
            guard window.app.rawAppBundleId == bundleId else { continue }
            // Don't steal scratchpad or sticky windows — they manage their own placement.
            if (window.parent as? Workspace)?.isScratchpad == true { continue }
            if StickyMemory.shared.isRemembered(windowId: window.windowId) { continue }
            let id = ObjectIdentifier(window)
            if placed.contains(id) { continue }
            placed.insert(id)
            return window
        }
        return nil
    }
}
