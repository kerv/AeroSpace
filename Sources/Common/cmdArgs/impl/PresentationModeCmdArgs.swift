public struct PresentationModeCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .presentationMode,
        help: """
            USAGE: presentation-mode on
                   presentation-mode off
                   presentation-mode toggle
            """,
        flags: [:],
        posArgs: [
            newMandatoryPosArgParser(\.action, parsePresentationModeAction, placeholder: Action.unionLiteral),
        ],
    )

    public var action: Lateinit<Action> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case on, off, toggle
    }
}

func parsePresentationModeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<PresentationModeCmdArgs> {
    parseSpecificCmdArgs(PresentationModeCmdArgs(rawArgs: args), args)
}

private func parsePresentationModeAction(i: PosArgParserInput) -> ParsedCliArgs<PresentationModeCmdArgs.Action> {
    .init(parseEnum(i.arg, PresentationModeCmdArgs.Action.self), advanceBy: 1)
}
