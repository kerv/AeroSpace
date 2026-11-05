public struct MoveFloatingToZoneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveFloatingToZone,
        help: move_floating_to_zone_help_generated,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.zone, parseMoveFloatingToZoneArg, placeholder: "<zone-id>")],
    )

    public var zone: Lateinit<String> = .uninitialized
}

func parseMoveFloatingToZoneCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveFloatingToZoneCmdArgs> {
    parseSpecificCmdArgs(MoveFloatingToZoneCmdArgs(rawArgs: args), args)
}

private func parseMoveFloatingToZoneArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(.success(i.arg), advanceBy: 1)
}
