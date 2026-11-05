public struct MoveNodeToZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveNodeToZone,
        help: move_node_to_zone_help_generated,
        flags: [
            "--no-focus": trueBoolFlag(\.noFocus),
        ],
        posArgs: [newMandatoryPosArgParser(\.zone, parseZoneArg, placeholder: "<zone-id>")],
    )

    public var noFocus: Bool = false
    public var zone: Lateinit<String> = .uninitialized

    public init(rawArgs: [String], _ zone: String) {
        self.commonState = .init(rawArgs.slice)
        self.zone = .initialized(zone)
    }
}

func parseMoveNodeToZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveNodeToZoneCmdArgs> {
    parseSpecificCmdArgs(MoveNodeToZoneCmdArgs(rawArgs: args), args)
}

private func parseZoneArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(.success(i.arg), advanceBy: 1)
}
