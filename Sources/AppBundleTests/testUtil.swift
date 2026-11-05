@testable import AppBundle
import Common
import Foundation
import HotKey
import XCTest

let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

@MainActor
func setUpWorkspacesForTests() {
    FloatingGeometryMemory.shared = FloatingGeometryMemory(url: FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-float-test-\(UUID().uuidString).json"))
    DockedMonitorWorkspaceMemory.shared = DockedMonitorWorkspaceMemory(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-dock-workspace-test-\(UUID().uuidString).json"))
    DockedZoneLayoutMemory.shared = DockedZoneLayoutMemory(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-dock-test-\(UUID().uuidString).json"))
    WindowPlacementMemory.shared = WindowPlacementMemory(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("aerospace-placement-test-\(UUID().uuidString).json"))
    config = defaultConfig
    configUrl = defaultConfigUrl
    config.enableNormalizationFlattenContainers = false // Make layout tests more predictable
    config.enableNormalizationOppositeOrientationForNestedContainers = false // Make layout tests more predictable
    config.defaultRootContainerOrientation = .horizontal // Make default layout predictable

    // Don't create any bindings and workspaces for tests
    config.modes = [mainModeId: Mode(bindings: [:])]
    config.persistentWorkspaces = []

    for workspace in Workspace.all {
        workspace.zoneContainers = [:]
        workspace.activeZoneProfile = nil
        workspace.zoneLayoutProfileKey = nil
        workspace.savedRootOrientation = nil
        workspace.focusedZone = nil
        workspace.mruZones = []
        workspace.savedZoneWeights = nil
        workspace.focusModeZone = nil
        workspace.presentationModeSnapshot = nil
        workspace.activeZoneDefinitions = []
        for child in workspace.children {
            child.unbindFromParent()
        }
    }
    check(Workspace.get(byName: "setUpWorkspacesForTests").focusWorkspace())
    Workspace.garbageCollectUnusedWorkspaces()
    check(focus.workspace.isEffectivelyEmpty)
    check(focus.workspace === Workspace.all.singleOrNil(), Workspace.all.map(\.description).joined(separator: ", "))
    check(mainMonitor.setActiveWorkspace(focus.workspace))

    TestApp.shared.focusedWindow = nil
    TestApp.shared.windows = []
    broadcastEventForTesting = nil
    activeZonePresetName = nil
    zonesDisabledByProfile = false
    primeZoneEventBroadcastTracking()
}

extension ParsedCmd {
    var errorOrNil: String? {
        return switch self {
            case .failure(let e): e.msg
            case .cmd, .help: nil
        }
    }

    var cmdOrDie: T { cmdOrNil ?? dieT("\(self)") }
}

func testParseCommandFail(_ command: String, msg expectedMsg: String, exitCode expectedExitCode: Int32, file: StaticString = #filePath, line: UInt = #line) {
    let parsed = parseCommand(command)
    switch parsed {
        case .cmd(let command): XCTFail("\(command) isn't supposed to be parcelable")
        case .help: die() // todo test help
        case .failure(let failure):
            assertEquals(failure, .init(expectedMsg, expectedExitCode), file: file, line: line)
    }
}

extension WorkspaceCmdArgs {
    init(target: WorkspaceTarget, autoBackAndForth: Bool? = nil, wrapAround: Bool? = nil) {
        self = WorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(target)
        self._autoBackAndForth = autoBackAndForth
        self._wrapAround = wrapAround
    }
}

extension MoveNodeToWorkspaceCmdArgs {
    init(target: WorkspaceTarget, wrapAround: Bool? = nil) {
        self = MoveNodeToWorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(target)
        self._wrapAround = wrapAround
    }

    init(workspace: String) {
        self = MoveNodeToWorkspaceCmdArgs(rawArgs: [])
        self.target = .initialized(.direct(.parse(workspace).getOrDie()))
    }
}

struct FakeMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int = 1
    let name: String = "Fake"
    let rect: Rect
    let visibleRect: Rect
    let width: CGFloat
    let height: CGFloat
    let isMain: Bool = false

    init(width: CGFloat, height: CGFloat) {
        let r = Rect(topLeftX: 0, topLeftY: 0, width: width, height: height)
        self.rect = r
        self.visibleRect = r
        self.width = width
        self.height = height
    }

    static var ultrawide: FakeMonitor { FakeMonitor(width: 3440, height: 1440) }
    static var standard: FakeMonitor { FakeMonitor(width: 1920, height: 1080) }
}

extension HotkeyBinding {
    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: Shell<any Command>) {
        let descriptionWithKeyNotation = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.init(modifiers, keyCode, commands, descriptionWithKeyNotation: descriptionWithKeyNotation)
    }
}

extension FocusCommand {
    static func new(direction: CardinalDirection) -> FocusCommand {
        FocusCommand(args: FocusCmdArgs(rawArgs: [], cardinalOrDfsDirection: .direction(direction)))
    }
}

func parseCommand(_ raw: String) -> ParsedCmd<Shell<any Command>> { parseCommand(raw, allowExecAndForget: true, allowEval: true) }
