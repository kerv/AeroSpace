public struct ScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpad,
        help: scratchpad_help_generated,
        flags: [:],
        posArgs: [],
    )
}

func parseScratchpadCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ScratchpadCmdArgs> {
    parseSpecificCmdArgs(ScratchpadCmdArgs(rawArgs: args), args)
}
