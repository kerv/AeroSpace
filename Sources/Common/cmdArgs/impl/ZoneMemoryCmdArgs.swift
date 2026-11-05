public struct ZoneMemoryCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .zoneMemory,
        help: """
            USAGE: zone-memory list [--count] [--json]
                   zone-memory clear (--app-id <app-bundle-id>|--all)
            """,
        flags: [
            "--count": trueBoolFlag(\.outputOnlyCount),
            "--json": trueBoolFlag(\.json),
            "--all": trueBoolFlag(\.clearAll),
            "--app-id": singleValueSubArgParser(\.appId, "<app-bundle-id>", Result.success),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.action, parseZoneMemoryAction, placeholder: ZoneMemoryCmdArgs.Action.unionLiteral),
        ],
        conflictingOptions: [
            ["--count", "--json"],
            ["--all", "--app-id"],
        ],
    )

    public var action: Lateinit<Action> = .uninitialized
    public var outputOnlyCount: Bool = false
    public var json: Bool = false
    public var clearAll: Bool = false
    public var appId: String? = nil

    public enum Action: String, CaseIterable, Sendable {
        case list, clear
    }
}

func parseZoneMemoryCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ZoneMemoryCmdArgs> {
    parseSpecificCmdArgs(ZoneMemoryCmdArgs(rawArgs: args), args)
        .flatMap { raw in
            switch raw.action.val {
                case .list:
                    if raw.clearAll || raw.appId != nil {
                        return .failure("zone-memory list doesn't support --all or --app-id")
                    }
                    return .cmd(raw)
                case .clear:
                    if raw.outputOnlyCount || raw.json {
                        return .failure("zone-memory clear doesn't support --count or --json")
                    }
                    let hasSelector = raw.clearAll || raw.appId != nil
                    return hasSelector
                        ? .cmd(raw)
                        : .failure("zone-memory clear requires --app-id <app-bundle-id> or --all")
            }
        }
}

private func parseZoneMemoryAction(i: PosArgParserInput) -> ParsedCliArgs<ZoneMemoryCmdArgs.Action> {
    .init(parseEnum(i.arg, ZoneMemoryCmdArgs.Action.self), advanceBy: 1)
}
