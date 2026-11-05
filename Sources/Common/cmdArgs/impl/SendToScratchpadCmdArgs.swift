public struct SendToScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .sendToScratchpad,
        help: send_to_scratchpad_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )
}

func parseSendToScratchpadCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SendToScratchpadCmdArgs> {
    parseSpecificCmdArgs(SendToScratchpadCmdArgs(rawArgs: args), args)
}
