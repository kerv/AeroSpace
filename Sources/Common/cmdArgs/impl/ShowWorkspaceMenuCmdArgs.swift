public struct ShowWorkspaceMenuCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .showWorkspaceMenu,
        help: "USAGE: show-workspace-menu [-h|--help]",
        flags: [:],
        posArgs: [],
    )
}

func parseShowWorkspaceMenuCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ShowWorkspaceMenuCmdArgs> {
    parseSpecificCmdArgs(ShowWorkspaceMenuCmdArgs(rawArgs: args), args)
}
