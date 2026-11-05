public struct DebugLogMarkerCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .debugLogMarker,
        help: """
            USAGE: debug-log-marker [-h|--help] [--label <text>]

            Write a visible marker to ~/Library/Logs/AeroSpace/debug.log so you can
            identify the moment before a bug occurred. Bind this to a key.
            """,
        flags: [
            "--label": singleValueSubArgParser(\._label, "<text>", Result.success),
        ],
        posArgs: [],
    )
    public typealias ExitCodeType = BinaryExitCode

    public var _label: String? = nil
}
