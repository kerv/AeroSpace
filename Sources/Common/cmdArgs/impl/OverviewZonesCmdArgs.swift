public struct OverviewZonesCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .overviewZones,
        help: "USAGE: overview-zones [-h|--help]",
        flags: [:],
        posArgs: [],
    )
}

func parseOverviewZonesCmdArgs(_ args: StrArrSlice) -> ParsedCmd<OverviewZonesCmdArgs> {
    parseSpecificCmdArgs(OverviewZonesCmdArgs(rawArgs: args), args)
}
