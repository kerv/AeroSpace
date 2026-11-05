public struct ZoneFocusModeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .zoneFocusMode,
        help: zone_focus_mode_help_generated,
        flags: [
            "--zone": ArgParser(\.zone, upcastArgParserFun(parseZoneFocusModeZoneArg)),
        ],
        posArgs: [newMandatoryPosArgParser(\.action, parseZoneFocusModeAction, placeholder: ZoneFocusModeCmdArgs.Action.unionLiteral)],
    )

    public var zone: ZoneName? = nil
    public var action: Lateinit<Action> = .uninitialized

    public init(rawArgs: [String], _ action: Action) {
        self.commonState = .init(rawArgs.slice)
        self.action = .initialized(action)
    }

    public enum Action: String, CaseIterable, Sendable {
        case on, off, toggle
    }

    public typealias ZoneName = String
}

func parseZoneFocusModeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ZoneFocusModeCmdArgs> {
    parseSpecificCmdArgs(ZoneFocusModeCmdArgs(rawArgs: args), args)
}

private func parseZoneFocusModeAction(i: PosArgParserInput) -> ParsedCliArgs<ZoneFocusModeCmdArgs.Action> {
    .init(parseEnum(i.arg, ZoneFocusModeCmdArgs.Action.self), advanceBy: 1)
}

private func parseZoneFocusModeZoneArg(i: SubArgParserInput) -> ParsedCliArgs<ZoneFocusModeCmdArgs.ZoneName> {
    if let arg = i.nonFlagArgOrNil() {
        return .succ(arg, advanceBy: 1)
    } else {
        return .fail("--zone requires a zone name", advanceBy: 0)
    }
}
