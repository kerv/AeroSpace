public struct ShowZonePickerCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .showZonePicker,
        help: "USAGE: show-zone-picker [-h|--help]",
        flags: [:],
        posArgs: [],
    )
}

func parseShowZonePickerCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ShowZonePickerCmdArgs> {
    parseSpecificCmdArgs(ShowZonePickerCmdArgs(rawArgs: args), args)
}
