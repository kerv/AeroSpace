public enum CmdKind: String, CaseIterable, Equatable, Sendable {
    // Sorted

    case balanceSizes = "balance-sizes"
    case close
    case closeAllWindowsButCurrent = "close-all-windows-but-current"
    case config
    case debugLogMarker = "debug-log-marker"
    case debugWindows = "debug-windows"
    case echo
    case enable
    case eval
    case execAndForget = "exec-and-forget"

    case _false = "false"

    case flattenWorkspaceTree = "flatten-workspace-tree"
    case focus
    case focusBackAndForth = "focus-back-and-forth"
    case focusMonitor = "focus-monitor"
    case focusZone = "focus-zone"
    case fullscreen
    case joinWith = "join-with"
    case layout
    case listApps = "list-apps"
    case listExecEnvVars = "list-exec-env-vars"
    case listModes = "list-modes"
    case listMonitors = "list-monitors"
    case listZones = "list-zones"
    case listWindows = "list-windows"
    case listWorkspaces = "list-workspaces"
    case macosNativeFullscreen = "macos-native-fullscreen"
    case macosNativeMinimize = "macos-native-minimize"
    case mode
    case move = "move"
    case moveMouse = "move-mouse"
    case moveNodeToMonitor = "move-node-to-monitor"
    case moveNodeToWorkspace = "move-node-to-workspace"
    case moveFloatingToZone = "move-floating-to-zone"
    case moveNodeToZone = "move-node-to-zone"
    case moveWorkspaceToMonitor = "move-workspace-to-monitor"
    case overviewZones = "overview-zones"
    case presentationMode = "presentation-mode"
    case reloadConfig = "reload-config"
    case resize
    case runCallback = "run-callback"
    case scratchpad
    case sendToScratchpad = "send-to-scratchpad"
    case showZonePicker = "show-zone-picker"
    case showWorkspaceMenu = "show-workspace-menu"
    case split
    case subscribe
    case summonWorkspace = "summon-workspace"
    case swap
    case test
    case testNot = "test-not"
    case triggerBinding = "trigger-binding"

    case _true = "true"

    case volume
    case workspace
    case workspaceBackAndForth = "workspace-back-and-forth"
    case workspaceSnapshot = "workspace-snapshot"
    case zone
    case zoneMemory = "zone-memory"
    case zoneFocusMode = "zone-focus-mode"
    case zonePreset = "zone-preset"
}

func initSubcommands() -> [String: any SubCommandParserProtocol] {
    var result: [String: any SubCommandParserProtocol] = [:]
    for kind in CmdKind.allCases {
        switch kind {
            case .balanceSizes:
                result[kind.rawValue] = SubCommandParser(BalanceSizesCmdArgs.init)
            case .close:
                result[kind.rawValue] = SubCommandParser(CloseCmdArgs.init)
            case .closeAllWindowsButCurrent:
                result[kind.rawValue] = SubCommandParser(CloseAllWindowsButCurrentCmdArgs.init)
            case .config:
                result[kind.rawValue] = SubCommandParser(parseConfigCmdArgs)
            case .debugLogMarker:
                result[kind.rawValue] = SubCommandParser(DebugLogMarkerCmdArgs.init)
            case .debugWindows:
                result[kind.rawValue] = SubCommandParser(DebugWindowsCmdArgs.init)
            case .echo:
                result[kind.rawValue] = SubCommandParser(EchoCmdArgs.init)
            case .enable:
                result[kind.rawValue] = SubCommandParser(parseEnableCmdArgs)
            case .eval:
                result[kind.rawValue] = SubCommandParser(EvalCmdArgs.init)
            case .execAndForget:
                break // exec-and-forget is parsed separately
            case ._false:
                result[kind.rawValue] = SubCommandParser(FalseCmdArgs.init)
            case .flattenWorkspaceTree:
                result[kind.rawValue] = SubCommandParser(FlattenWorkspaceTreeCmdArgs.init)
            case .focus:
                result[kind.rawValue] = SubCommandParser(parseFocusCmdArgs)
            case .focusBackAndForth:
                result[kind.rawValue] = SubCommandParser(FocusBackAndForthCmdArgs.init)
            case .focusMonitor:
                result[kind.rawValue] = SubCommandParser(parseFocusMonitorCmdArgs)
            case .focusZone:
                result[kind.rawValue] = SubCommandParser(parseFocusZoneCmdArgs)
            case .fullscreen:
                result[kind.rawValue] = SubCommandParser(parseFullscreenCmdArgs)
            case .joinWith:
                result[kind.rawValue] = SubCommandParser(JoinWithCmdArgs.init)
            case .layout:
                result[kind.rawValue] = SubCommandParser(parseLayoutCmdArgs)
            case .listApps:
                result[kind.rawValue] = SubCommandParser(parseListAppsCmdArgs)
            case .listExecEnvVars:
                result[kind.rawValue] = SubCommandParser(ListExecEnvVarsCmdArgs.init)
            case .listModes:
                result[kind.rawValue] = SubCommandParser(parseListModesCmdArgs)
            case .listMonitors:
                result[kind.rawValue] = SubCommandParser(parseListMonitorsCmdArgs)
            case .listZones:
                result[kind.rawValue] = SubCommandParser(parseListZonesCmdArgs)
            case .listWindows:
                result[kind.rawValue] = SubCommandParser(parseListWindowsCmdArgs)
            case .listWorkspaces:
                result[kind.rawValue] = SubCommandParser(parseListWorkspacesCmdArgs)
            case .macosNativeFullscreen:
                result[kind.rawValue] = SubCommandParser(parseMacosNativeFullscreenCmdArgs)
            case .macosNativeMinimize:
                result[kind.rawValue] = SubCommandParser(MacosNativeMinimizeCmdArgs.init)
            case .mode:
                result[kind.rawValue] = SubCommandParser(ModeCmdArgs.init)
            case .move:
                result[kind.rawValue] = SubCommandParser(parseMoveCmdArgs)
                // deprecated
                result["move-through"] = SubCommandParser(parseMoveCmdArgs)
            case .moveMouse:
                result[kind.rawValue] = SubCommandParser(parseMoveMouseCmdArgs)
            case .moveNodeToMonitor:
                result[kind.rawValue] = SubCommandParser(parseMoveNodeToMonitorCmdArgs)
            case .moveNodeToWorkspace:
                result[kind.rawValue] = SubCommandParser(parseMoveNodeToWorkspaceCmdArgs)
            case .moveFloatingToZone:
                result[kind.rawValue] = SubCommandParser(parseMoveFloatingToZoneCmdArgs)
            case .moveNodeToZone:
                result[kind.rawValue] = SubCommandParser(parseMoveNodeToZoneCmdArgs)
            case .moveWorkspaceToMonitor:
                result[kind.rawValue] = SubCommandParser(parseWorkspaceToMonitorCmdArgs)
                // deprecated
                result["move-workspace-to-display"] = SubCommandParser(MoveWorkspaceToMonitorCmdArgs.init)
            case .overviewZones:
                result[kind.rawValue] = SubCommandParser(parseOverviewZonesCmdArgs)
            case .presentationMode:
                result[kind.rawValue] = SubCommandParser(parsePresentationModeCmdArgs)
            case .reloadConfig:
                result[kind.rawValue] = SubCommandParser(ReloadConfigCmdArgs.init)
            case .resize:
                result[kind.rawValue] = SubCommandParser(parseResizeCmdArgs)
            case .runCallback:
                result[kind.rawValue] = SubCommandParser(parseRunCallbackCmdArgs)
            case .scratchpad:
                result[kind.rawValue] = SubCommandParser(parseScratchpadCmdArgs)
            case .sendToScratchpad:
                result[kind.rawValue] = SubCommandParser(parseSendToScratchpadCmdArgs)
            case .showZonePicker:
                result[kind.rawValue] = SubCommandParser(parseShowZonePickerCmdArgs)
            case .showWorkspaceMenu:
                result[kind.rawValue] = SubCommandParser(parseShowWorkspaceMenuCmdArgs)
            case .split:
                result[kind.rawValue] = SubCommandParser(parseSplitCmdArgs)
            case .subscribe:
                result[kind.rawValue] = SubCommandParser(parseSubscribeCmdArgs)
            case .summonWorkspace:
                result[kind.rawValue] = SubCommandParser(SummonWorkspaceCmdArgs.init)
            case .swap:
                result[kind.rawValue] = SubCommandParser(parseSwapCmdArgs)
            case .test:
                result[kind.rawValue] = SubCommandParser(parseTestCmdArgs)
            case .testNot:
                result[kind.rawValue] = SubCommandParser(parseTestNotCmdArgs)
            case .triggerBinding:
                result[kind.rawValue] = SubCommandParser(parseTriggerBindingCmdArgs)
            case ._true:
                result[kind.rawValue] = SubCommandParser(TrueCmdArgs.init)
            case .volume:
                result[kind.rawValue] = SubCommandParser(VolumeCmdArgs.init)
            case .workspace:
                result[kind.rawValue] = SubCommandParser(parseWorkspaceCmdArgs)
            case .workspaceBackAndForth:
                result[kind.rawValue] = SubCommandParser(WorkspaceBackAndForthCmdArgs.init)
            case .workspaceSnapshot:
                result[kind.rawValue] = SubCommandParser(parseWorkspaceSnapshotCmdArgs)
            case .zone:
                result[kind.rawValue] = SubCommandParser(parseZoneCmdArgs)
            case .zoneMemory:
                result[kind.rawValue] = SubCommandParser(parseZoneMemoryCmdArgs)
            case .zoneFocusMode:
                result[kind.rawValue] = SubCommandParser(parseZoneFocusModeCmdArgs)
            case .zonePreset:
                result[kind.rawValue] = SubCommandParser(parseZonePresetCmdArgs)
        }
    }
    return result
}
