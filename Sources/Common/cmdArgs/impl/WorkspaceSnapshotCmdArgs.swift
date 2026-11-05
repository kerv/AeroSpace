public struct WorkspaceSnapshotCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceSnapshot,
        help: workspace_snapshot_help_generated,
        flags: [:],
        posArgs: [
            newMandatoryPosArgParser(\.action, parseSnapshotAction, placeholder: WorkspaceSnapshotCmdArgs.Action.unionLiteral),
            newMandatoryPosArgParser(\.name, parseSnapshotName, placeholder: "<snapshot-name>"),
        ],
    )

    public var action: Lateinit<Action> = .uninitialized
    public var name: Lateinit<String> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case save, restore
    }
}

func parseWorkspaceSnapshotCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WorkspaceSnapshotCmdArgs> {
    parseSpecificCmdArgs(WorkspaceSnapshotCmdArgs(rawArgs: args), args)
}

private func parseSnapshotAction(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceSnapshotCmdArgs.Action> {
    .init(parseEnum(i.arg, WorkspaceSnapshotCmdArgs.Action.self), advanceBy: 1)
}

private func parseSnapshotName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    let name = i.arg
    let valid = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    if valid && !name.isEmpty {
        return .succ(name, advanceBy: 1)
    } else {
        return .fail("Snapshot name must match [a-zA-Z0-9_-]+, got '\(name)'", advanceBy: 1)
    }
}
