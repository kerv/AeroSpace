import AppKit
import Common
import HotKey
import TOMLDecoder
import OrderedCollections

struct ReadConfigResult {
    let configUrl: URL
    let parseConfigResult: ParseConfigResult

    @MainActor static func fatal(configUrl: URL, message: String) -> Self {
        ReadConfigResult(
            configUrl: configUrl,
            parseConfigResult: ParseConfigResult(
                config: defaultConfig,
                errors: [.init(.emptyRoot, message, preventConfigReload: true)],
                warnings: [],
            ),
        )
    }
}

@MainActor
func readConfig(forceConfigUrl: URL?) -> ReadConfigResult {
    let configUrl: URL
    if let forceConfigUrl {
        configUrl = forceConfigUrl
    } else {
        switch findCustomConfigUrl() {
            case .file(let url): configUrl = url
            case .noCustomConfigExists: configUrl = defaultConfigUrl
            case .ambiguousConfigError(let candidates):
                let msg = """
                    Ambiguous config error. Several configs found:
                    \(candidates.map(\.path).joined(separator: "\n"))
                    """
                return .fatal(configUrl: defaultConfigUrl, message: msg)
        }
    }
    let configStr: String
    do {
        configStr = try String(contentsOf: configUrl, encoding: .utf8)
    } catch {
        let msg = "Can't read contents of \(configUrl.path.singleQuoted) as a utf8 string: \(error.localizedDescription)"
        return .fatal(configUrl: configUrl, message: msg)
    }
    return ReadConfigResult(configUrl: configUrl, parseConfigResult: parseConfig(configStr))
}

struct ConfigParseDiagnostic: Error, Equatable {
    let backtrace: ConfigBacktrace
    let message: String
    let preventConfigReload: Bool // for severe config errors (like TOML parse error)

    public init(_ backtrace: ConfigBacktrace, _ message: String, preventConfigReload: Bool = false) {
        check(!message.isEmpty)
        self.backtrace = backtrace
        self.message = message
        self.preventConfigReload = preventConfigReload
    }

    func description(_ severity: Severity) -> String {
        let backtraceDesc = backtrace.description
        // todo Make 'split' + flatten normalization prettier
        return switch backtraceDesc.isEmpty {
            case true: "[\(severity.rawValue)] \(message)"
            case false: "[\(severity.rawValue)] \(backtraceDesc): \(message)"
        }
    }

    enum Severity: String {
        case warning = "WARNING"
        case error = "ERROR"
    }
}

typealias ResOrConfigParseDiagnostic<T> = Result<T, ConfigParseDiagnostic>

extension ParserProtocol {
    func transformRawConfig(_ raw: S,
                            _ value: OrderedJson,
                            _ backtrace: ConfigBacktrace,
                            _ c: inout ConfigParserContext) -> S
    {
        if let value = parse(value, backtrace, &c).getOrNil(appendErrorTo: &c.errors) {
            return raw.copy(keyPath, value)
        }
        return raw
    }
}

struct ConfigParserContext {
    var configVersion: ConfigVersion
    var errors: [ConfigParseDiagnostic]
    var warnings: [ConfigParseDiagnostic]
}

protocol ParserProtocol<S>: Sendable {
    associatedtype T
    associatedtype S where S: ConvenienceMutable
    var keyPath: SendableWritableKeyPath<S, T> { get }
    var parse: @Sendable (OrderedJson, ConfigBacktrace, inout ConfigParserContext) -> ResOrConfigParseDiagnostic<T> { get }
}

struct Parser<S: ConvenienceMutable, T>: ParserProtocol {
    let keyPath: SendableWritableKeyPath<S, T>
    let parse: @Sendable (OrderedJson, ConfigBacktrace, inout ConfigParserContext) -> ResOrConfigParseDiagnostic<T>

    init(_ keyPath: SendableWritableKeyPath<S, T>, _ parse: @escaping @Sendable (OrderedJson, ConfigBacktrace, inout ConfigParserContext) -> T) {
        self.keyPath = keyPath
        self.parse = { raw, backtrace, errors -> ResOrConfigParseDiagnostic<T> in .success(parse(raw, backtrace, &errors)) }
    }

    init(_ keyPath: SendableWritableKeyPath<S, T>, _ parse: @escaping @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>) {
        self.keyPath = keyPath
        self.parse = { raw, backtrace, _ -> ResOrConfigParseDiagnostic<T> in parse(raw, backtrace) }
    }
}

private let keyMappingConfigRootKey = "key-mapping"
private let configVersionConfigRootKey = "config-version"
private let modeConfigRootKey = "mode"
private let persistentWorkspacesKey = "persistent-workspaces"

// For every new config option you add, think:
// 1. Does it make sense to have different value
// 2. Prefer commands and commands flags over toml options if possible
private let configParser: [String: any ParserProtocol<Config>] = [
    configVersionConfigRootKey: Parser(\.configVersion, skipParsing(Config().configVersion)), // Parsed manually

    "after-login-command": Parser(\._afterLoginCommand, parseDeprecatedAfterLoginCommand),
    "after-startup-command": Parser(\.afterStartupCommand, parseShellOfCommandsForConfig),

    "on-focus-changed": Parser(\.onFocusChanged, parseShellOfCommandsForConfig),
    "on-mode-changed": Parser(\.onModeChanged, parseShellOfCommandsForConfig),
    "on-focused-monitor-changed": Parser(\.onFocusedMonitorChanged, parseShellOfCommandsForConfig),
    // "on-focused-workspace-changed": Parser(\.onFocusedWorkspaceChanged, { parseCommandOrCommands($0).toParsedConfig($1) }),

    "enable-normalization-flatten-containers": Parser(\.enableNormalizationFlattenContainers, parseBool),
    "enable-normalization-opposite-orientation-for-nested-containers": Parser(\.enableNormalizationOppositeOrientationForNestedContainers, parseBool),

    "default-root-container-layout": Parser(\.defaultRootContainerLayout, parseLayout),
    "default-root-container-orientation": Parser(\.defaultRootContainerOrientation, parseDefaultContainerOrientation),

    "start-at-login": Parser(\.startAtLogin, parseBool),
    "auto-reload-config": Parser(\.autoReloadConfig, parseBool),
    "automatically-unhide-macos-hidden-apps": Parser(\.automaticallyUnhideMacosHiddenApps, parseBool),
    "accordion-padding": Parser(\.accordion.padding, parseInt),
    "accordion": Parser(\.accordion, parseAccordionConfig),
    "accordion-indicator": Parser(\.accordionIndicator, parseAccordionIndicator),
    "stack-indicator": Parser(\.stackIndicator, parseStackIndicator),
    persistentWorkspacesKey: Parser(\.persistentWorkspaces, parsePersistentWorkspaces),
    "exec-on-workspace-change": Parser(\.execOnWorkspaceChange, parseArrayOfStrings),
    "exec": Parser(\.execConfig, parseExecConfig),

    keyMappingConfigRootKey: Parser(\.keyMapping, skipParsing(Config().keyMapping)), // Parsed manually
    modeConfigRootKey: Parser(\.modes, skipParsing(Config().modes)), // Parsed manually

    "gaps": Parser(\.gaps, parseGaps),
    "focus-follows-mouse": Parser(\.focusFollowsMouse, parseFocusFollowsMouse),
    "zones": Parser(\.zones, parseZonesConfig),
    "zone-presets": Parser(\.zonePresets, parseZonePresetsArray),
    "monitor-profiles": Parser(\.monitorProfiles, parseMonitorProfilesArray),
    "on-monitor-changed": Parser(\.onMonitorChanged, parseOnMonitorChangedArray),
    "hud": Parser(\.hud, parseHUDConfig),
    "borders": Parser(\.borders, parseBorderConfig),
    "floating": Parser(\.floating, parseFloatingConfig),
    "workspace-to-monitor-force-assignment": Parser(\.workspaceToMonitorForceAssignment, parseWorkspaceToMonitorAssignment),
    "on-window-detected": Parser(\.onWindowDetected, parseOnWindowDetectedArray),

    // Deprecated
    "non-empty-workspaces-root-containers-layout-on-startup": Parser(\._nonEmptyWorkspacesRootContainersLayoutOnStartup, parseStartupRootContainerLayout),
    "indent-for-nested-containers-with-the-same-orientation": Parser(\._indentForNestedContainersWithTheSameOrientation, parseIndentForNestedContainersWithTheSameOrientation),
]

extension ParsedCmd {
    func toResult() -> ResOrStr<T> {
        return switch self {
            case .cmd(let a): .success(a)
            case .help(let a): .failure(a)
            case .failure(let a): .failure(a.msg)
        }
    }
}

func parseDeprecatedAfterLoginCommand(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[any Command]> {
    if let array = raw.asArrayOrNil, array.count == 0 {
        return .success([])
    }
    let msg = "after-login-command is deprecated since AeroSpace 0.19.0. https://github.com/nikitabobko/AeroSpace/issues/1482"
    return .failure(.init(backtrace, msg))
}

func parseShellOfCommandsForConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Shell<any Command> {
    if let rawString = raw.asStringOrNil {
        return parseCommand(rawString, allowExecAndForget: true, allowEval: false).toResult().toParsedConfig(backtrace).getOrNil(appendErrorTo: &c.errors) ?? .empty
    } else if let rawArray = raw.asArrayOrNil {
        var result = [Shell<any Command>]()
        for (index, elem) in rawArray.enumerated() {
            let backtrace = backtrace + .index(index)
            if let elem = elem.asStringOrNil {
                result.append(parseCommand(elem, allowExecAndForget: true, allowEval: false).toResult().toParsedConfig(backtrace).getOrNil(appendErrorTo: &c.errors) ?? .empty)
            } else {
                c.errors.append(.init(backtrace, expectedActualTypeError(expected: .string, actual: elem.tomlType)))
            }
        }
        return .newCompound(result, Shell<any Command>.seq)
    } else {
        c.errors.append(.init(backtrace, expectedActualTypeError(expected: [.string, .array], actual: raw.tomlType)))
        return .empty
    }
}

func tomlAnyToOrderedJsonRecursive(
    any: Any,
    _ backtrace: ConfigBacktrace,
    _ errors: inout [ConfigParseDiagnostic],
) -> OrderedJson? {
    switch any {
        case let dict as [String: Any]:
            var json = OrderedJson.JsonDict()
            for (key, tomlValue) in dict.sortedEntries {
                json[key] = tomlAnyToOrderedJsonRecursive(any: tomlValue, backtrace + .key(key), &errors)
            }
            return .dict(json)
        case let array as [Any]:
            var json = OrderedJson.JsonArray()
            for (index, tomlValue) in array.enumerated() {
                let element = tomlAnyToOrderedJsonRecursive(any: tomlValue, backtrace + .index(index), &errors)
                guard let element else { continue }
                json.append(element)
            }
            return .array(json)
        default:
            if let value = OrderedJson.newScalarOrNil(any) { return value }
            errors.append(.init(backtrace, "Unsupported TOML type: \(type(of: any))"))
            return nil
    }
}

struct ParseConfigResult {
    let config: Config
    let errors: [ConfigParseDiagnostic]
    let warnings: [ConfigParseDiagnostic]

    var allowReloadConfig: Bool { errors.allSatisfy { !$0.preventConfigReload } }
}

@MainActor func parseConfig(_ rawToml: String) -> ParseConfigResult {
    var errors = NonCopyable([ConfigParseDiagnostic]())

    let rawTable: OrderedJson.JsonDict
    do {
        let dict: [String: Any] = try .init(try TOMLTable(source: rawToml))
        let json = tomlAnyToOrderedJsonRecursive(any: dict, .emptyRoot, &errors.value)
        switch json {
            case .dict(let dict): rawTable = dict
            default: // dead code
                let msg = "Config parsing error: the top level type must be a TOML Table. But got: \((json ?? .null).tomlType)"
                errors.value.append(.init(.emptyRoot, msg, preventConfigReload: true))
                rawTable = [:]
        }
    } catch {
        errors.value.append(.init(.emptyRoot, error.description, preventConfigReload: true))
        rawTable = [:]
    }

    let configVersion: ConfigVersion = rawTable[configVersionConfigRootKey]
        .flatMap { parseConfigVersion($0, .rootKey(configVersionConfigRootKey)).getOrNil(appendErrorTo: &errors.value) }
        ?? .min

    var c = ConfigParserContext(configVersion: configVersion, errors: errors.consume(), warnings: [ConfigParseDiagnostic]())

    var config = rawTable.parseTable(Config(), configParser, .emptyRoot, &c)
    config.configVersion = configVersion

    if let mapping = rawTable[keyMappingConfigRootKey].flatMap({ parseKeyMapping($0, .rootKey(keyMappingConfigRootKey), &c) }) {
        config.keyMapping = mapping
    }

    // Parse modeConfigRootKey after keyMappingConfigRootKey
    if let modes = rawTable[modeConfigRootKey].flatMap({ parseModes($0, .rootKey(modeConfigRootKey), &c, config.keyMapping.resolve()) }) {
        config.modes = modes
    }

    if config.configVersion <= ._1 {
        if rawTable.keys.contains(persistentWorkspacesKey) {
            c.errors += [.init(.rootKey(persistentWorkspacesKey), "This config option is only available since 'config-version = 2'")]
        }
        config.persistentWorkspaces = (config.modes.values.lazy
            .flatMap { (mode: Mode) -> [HotkeyBinding] in Array(mode.bindings.values) }
            .flatMap { (binding: HotkeyBinding) -> [String] in
                let commands = binding.commands.flatten()
                return commands.filterIsInstance(of: WorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw } +
                    commands.filterIsInstance(of: MoveNodeToWorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw }
            }
            + (config.workspaceToMonitorForceAssignment).keys)
            .toOrderedSet()
    }

    if config.enableNormalizationFlattenContainers {
        let containsSplitCommand = config.modes.values.lazy.flatMap { $0.bindings.values }
            .flatMap { $0.commands.flatten() }
            .contains { $0 is SplitCommand }
        if containsSplitCommand {
            c.errors += [.init(
                .emptyRoot, // todo Make 'split' + flatten normalization prettier
                """
                The config contains:
                1. usage of 'split' command
                2. enable-normalization-flatten-containers = true
                These two settings don't play nicely together. 'split' command has no effect when enable-normalization-flatten-containers is disabled.

                My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.
                """,
            )]
        }
    }
    if config.configVersion < .max {
        let msg = "The current 'config-version = \(config.configVersion)' is outdated. " +
            "Please consider migrating to 'config-version = \(ConfigVersion.max)'. " +
            "See https://nikitabobko.github.io/AeroSpace/guide#config-version for the migration guide."
        c.warnings.append(.init(.emptyRoot, msg))
    }
    return ParseConfigResult(config: config, errors: c.errors, warnings: c.warnings)
}

func parseIndentForNestedContainersWithTheSameOrientation(_ _: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Void> {
    let msg = "Deprecated. Please drop it from the config. See https://github.com/nikitabobko/AeroSpace/issues/96"
    return .failure(.init(backtrace, msg))
}

func parseConfigVersion(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ConfigVersion> {
    parseInt(raw, backtrace)
        .flatMap { ConfigVersion.init(rawValue: $0).toResult(.init(backtrace, "config-version must be in [\(ConfigVersion.min), \(ConfigVersion.max)] range")) }
}

private let hudConfigParser: [String: any ParserProtocol<HUDConfig>] = [
    "active-on": Parser(\.activeOn, parseHUDActiveOn),
]

private let floatingConfigParser: [String: any ParserProtocol<FloatingConfig>] = [
    "app-ids": Parser(\.appIds, parseArrayOfStrings),
]

func parseFloatingConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FloatingConfig {
    parseTable(raw, FloatingConfig(), floatingConfigParser, backtrace, &c)
}

func parseHUDConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> HUDConfig {
    parseTable(raw, HUDConfig(), hudConfigParser, backtrace, &c)
}

private func parseHUDActiveOn(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<HUDActiveOn> {
    parseString(raw, backtrace).flatMap {
        HUDActiveOn(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse hud.active-on '\($0)'. Expected 'ultrawide', 'always', or 'never'"))
    }
}

private let borderConfigParser: [String: any ParserProtocol<BorderConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width, parseDouble),
    "corner-radius": Parser(\.cornerRadius, parseDouble),
    "active-color": Parser(\.activeColor, parseAeroColor),
    "inactive-color": Parser(\.inactiveColor, parseAeroColor),
    "ignore-app-ids": Parser(\.ignoredApps, parseArrayOfStrings),
]

func parseBorderConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> BorderConfig {
    parseTable(raw, BorderConfig(), borderConfigParser, backtrace, &c)
}

private func parseAeroColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<AeroColor> {
    raw.asIntOrNil
        .map { AeroColor(argb: $0) }
        .toResult(expectedActualTypeDiagnostic(expected: .int, actual: raw.tomlType, backtrace))
}

private let accordionConfigParser: [String: any ParserProtocol<AccordionConfig>] = [
    "mode": Parser(\.mode, parseAccordionMode),
    "padding": Parser(\.padding, parseInt),
    "offset-x": Parser(\.offsetX, parseInt),
    "offset-y": Parser(\.offsetY, parseInt),
]

func parseAccordionConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> AccordionConfig {
    parseTable(raw, AccordionConfig(), accordionConfigParser, backtrace, &c)
}

private func parseAccordionMode(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<AccordionMode> {
    parseString(raw, backtrace).flatMap {
        AccordionMode(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse accordion.mode '\($0)'. Expected 'overlap' or 'cascade'"))
    }
}

// Non-zone fields parsed by the standard table parser.
// "zone", "widths", "layouts" are intentionally skipped here — parseZonesConfig handles them
// manually after parseTable runs, so they must be listed to suppress "Unknown key" errors.
private let zonesConfigNonZoneParser: [String: any ParserProtocol<ZonesConfig>] = [
    "gap": Parser(\.gap, parseInt),
    "focus-mode-collapsed-width": Parser(\.focusModeCollapsedWidth, parseInt),
    "behavior": Parser(\.behavior, parseZoneBehaviorOverrides),
    "app-routing": Parser(\.appRouting, parseZoneAppRouting),
    "overrides": Parser(\.overrides, parseZoneGapOverrides),
    "zone":    Parser(\.zones, skipParsing([ZoneDefinition]())),  // handled manually below
    "widths":  Parser(\.zones, skipParsing([ZoneDefinition]())),  // legacy; handled manually below
    "layouts": Parser(\.zones, skipParsing([ZoneDefinition]())),  // legacy; handled manually below
]

func parseZonesConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> ZonesConfig {
    var result = parseTable(raw, ZonesConfig(), zonesConfigNonZoneParser, backtrace, &c)
    let dict = raw.asDictOrNil ?? [:]

    if let rawZone = dict["zone"] {
        // New format: [[zones.zone]] array of zone definitions.
        if let zones = parseZoneDefinitions(rawZone, backtrace + .key("zone"), &c) {
            result.zones = zones
        }
    } else if dict["widths"] != nil || dict["layouts"] != nil {
        // Legacy format: zones.widths and zones.layouts arrays. Deprecated; use [[zones.zone]].
        if let zones = parseLegacyZoneArrays(dict, backtrace, &c) {
            result.zones = zones
        }
    }
    return result
}

private func parseZoneDefinitions(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [ZoneDefinition]? {
    guard let arr = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return nil
    }
    guard !arr.isEmpty else {
        c.errors.append(.init(backtrace, "zones.zone must have at least 1 entry"))
        return nil
    }
    var defs: [ZoneDefinition] = []
    for (index, elem) in arr.enumerated() {
        let bt = backtrace + .index(index)
        guard let dict = elem.asDictOrNil else {
            c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: elem.tomlType, bt))
            return nil
        }
        guard let rawId = dict["id"], let id = rawId.asStringOrNil, !id.isEmpty else {
            c.errors.append(.init(bt, "zone entry must have a non-empty 'id' string"))
            return nil
        }
        guard let rawWidth = dict["width"] else {
            c.errors.append(.init(bt, "zone entry '\(id)' must have a 'width' field"))
            return nil
        }
        guard case .success(let width) = parseDouble(rawWidth, bt + .key("width")), width > 0 else {
            c.errors.append(.init(bt + .key("width"), "zone '\(id)' width must be a positive number"))
            return nil
        }
        let layout: Layout
        if let rawLayout = dict["layout"] {
            switch parseLayout(rawLayout, bt + .key("layout")) {
                case .success(let l): layout = l
                case .failure(let e): c.errors.append(e); return nil
            }
        } else {
            layout = .tiles
        }
        defs.append(ZoneDefinition(id: id, width: width, layout: layout))
    }
    // Validate widths sum to 1.0.
    let total = defs.reduce(0.0) { $0 + $1.width }
    guard abs(total - 1.0) < 0.01 else {
        c.errors.append(.init(backtrace, "zone widths must sum to 1.0 (got \(total))"))
        return nil
    }
    // Validate unique IDs.
    let ids = defs.map(\.id)
    if Set(ids).count != ids.count {
        c.errors.append(.init(backtrace, "zone IDs must be unique"))
        return nil
    }
    return defs
}

/// Parse legacy `widths = [...]` + `layouts = [...]` arrays and synthesize ZoneDefinitions.
/// IDs default to ["left", "center", "right"] for 3 zones, or "zone1"..."zoneN" otherwise.
private func parseLegacyZoneArrays(
    _ dict: OrderedJson.JsonDict,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext
) -> [ZoneDefinition]? {
    let widths: [Double]
    if let rawWidths = dict["widths"] {
        switch parseZoneWidths(rawWidths, backtrace + .key("widths")) {
            case .success(let w): widths = w
            case .failure(let e): c.errors.append(e); return nil
        }
    } else {
        widths = [1.0/3, 1.0/3, 1.0/3]
    }
    let layouts: [Layout]
    if let rawLayouts = dict["layouts"] {
        switch parseZoneLayouts(rawLayouts, backtrace + .key("layouts"), widths.count) {
            case .success(let l): layouts = l
            case .failure(let e): c.errors.append(e); return nil
        }
    } else {
        layouts = Array(repeating: .tiles, count: widths.count)
    }
    let defaultIds = widths.count == 3 ? ["left", "center", "right"] : (1...widths.count).map { "zone\($0)" }
    return zip(zip(defaultIds, widths), layouts).map { ZoneDefinition(id: $0.0, width: $0.1, layout: $1) }
}

private func parseZoneGapOverrides(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: ZoneGapOverride] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZoneGapOverride] = [:]
    for (zoneName, rawOverride) in rawTable {
        let bt = backtrace + .key(zoneName)
        result[zoneName] = parseTable(rawOverride, ZoneGapOverride(), zoneGapOverrideParser, bt, &c)
    }
    return result
}

private func parseZoneBehaviorOverrides(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: ZoneBehavior] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZoneBehavior] = [:]
    for (zoneName, rawBehavior) in rawTable {
        let bt = backtrace + .key(zoneName)
        result[zoneName] = parseTable(rawBehavior, ZoneBehavior(), zoneBehaviorParser, bt, &c)
    }
    return result
}

private func parseZoneAppRouting(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: String] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: String] = [:]
    for (appId, rawZoneName) in rawTable {
        let bt = backtrace + .key(appId)
        switch parseString(rawZoneName, bt) {
            case .success(let zoneName):
                result[appId] = zoneName
            case .failure(let error):
                c.errors.append(error)
        }
    }
    return result
}

/// Keys under [zones.overrides.<name>]: top/bottom/left/right are outer-gap pixel overrides.
private let zoneGapOverrideParser: [String: any ParserProtocol<ZoneGapOverride>] = [
    "top": Parser(\.top, parseOptionalInt),
    "bottom": Parser(\.bottom, parseOptionalInt),
    "left": Parser(\.left, parseOptionalInt),
    "right": Parser(\.right, parseOptionalInt),
]

private let zoneBehaviorParser: [String: any ParserProtocol<ZoneBehavior>] = [
    "new-window": Parser(\.newWindow, parseZoneNewWindowPolicy),
]

private func parseZoneNewWindowPolicy(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ZoneNewWindowPolicy> {
    parseString(raw, backtrace).flatMap {
        ZoneNewWindowPolicy(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse zones.behavior.new-window '\($0)'. Expected 'append', 'after-focused', or 'append-hidden'"))
    }
}

private func parseOptionalInt(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int?> {
    parseInt(raw, backtrace).map(Optional.init)
}

private func parseZoneWidths(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[Double]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr -> ResOrConfigParseDiagnostic<[Double]> in
            guard !arr.isEmpty else {
                return .failure(.init(backtrace, "zones.widths must not be empty"))
            }
            return arr.enumerated().mapAllOrFailure { (index, elem) in
                parseDouble(elem, backtrace + .index(index))
            }
        }
        .flatMap { widths in
            guard abs(widths.reduce(0, +) - 1.0) < 0.01, widths.allSatisfy({ $0 > 0 }) else {
                return .failure(.init(backtrace, "zones.widths must be positive values summing to 1.0"))
            }
            return .success(widths)
        }
}

private func parseZoneLayouts(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ expectedCount: Int) -> ResOrConfigParseDiagnostic<[Layout]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr -> ResOrConfigParseDiagnostic<[Layout]> in
            guard arr.count == expectedCount else {
                return .failure(.init(backtrace, "zones.layouts must have \(expectedCount) elements to match zones.widths, got \(arr.count)"))
            }
            return arr.enumerated().mapAllOrFailure { (index, elem) in
                parseLayout(elem, backtrace + .index(index))
            }
        }
}

private func parseMonitorProfilesArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [MonitorProfileRule] {
    guard let arr = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    return arr.enumerated().compactMap { (index, elem) in
        parseMonitorProfileRule(elem, backtrace + .index(index), &c)
    }
}

private func parseMonitorProfileRule(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> MonitorProfileRule? {
    guard let dict = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return nil
    }
    var myErrors: [ConfigParseDiagnostic] = []
    var rule = MonitorProfileRule()

    if let nameOrderedJson = dict["name"] {
        if let name = nameOrderedJson.asStringOrNil, !name.isEmpty {
            rule.name = name
        } else {
            myErrors.append(expectedActualTypeDiagnostic(expected: .string, actual: nameOrderedJson.tomlType, backtrace + .key("name")))
        }
    } else {
        myErrors.append(.init(backtrace, "'name' is required in [[monitor-profiles]]"))
    }

    if let matchOrderedJson = dict["match"] {
        if let matchDict = matchOrderedJson.asDictOrNil {
            let matchBt = backtrace + .key("match")
            if let ratioOrderedJson = matchDict["min-aspect-ratio"] {
                if let ratio = ratioOrderedJson.asDoubleOrNil, ratio > 0 {
                    rule.matcher.minAspectRatio = ratio
                } else {
                    myErrors.append(expectedActualTypeDiagnostic(expected: .float, actual: ratioOrderedJson.tomlType, matchBt + .key("min-aspect-ratio")))
                }
            }
            if let countOrderedJson = matchDict["monitor-count"] {
                if let count = countOrderedJson.asIntOrNil, count > 0 {
                    rule.matcher.monitorCount = count
                } else {
                    myErrors.append(expectedActualTypeDiagnostic(expected: .int, actual: countOrderedJson.tomlType, matchBt + .key("monitor-count")))
                }
            }
        } else {
            myErrors.append(expectedActualTypeDiagnostic(expected: .table, actual: matchOrderedJson.tomlType, backtrace + .key("match")))
        }
    }

    if let layoutOrderedJson = dict["apply-zone-layout"] {
        if let layout = layoutOrderedJson.asStringOrNil, !layout.isEmpty {
            rule.applyZoneLayout = layout
        } else {
            myErrors.append(expectedActualTypeDiagnostic(expected: .string, actual: layoutOrderedJson.tomlType, backtrace + .key("apply-zone-layout")))
        }
    }

    if let snapshotOrderedJson = dict["restore-workspace-snapshot"] {
        if let snapshot = snapshotOrderedJson.asStringOrNil, !snapshot.isEmpty {
            rule.restoreWorkspaceSnapshot = snapshot
        } else {
            myErrors.append(expectedActualTypeDiagnostic(expected: .string, actual: snapshotOrderedJson.tomlType, backtrace + .key("restore-workspace-snapshot")))
        }
    }

    if !myErrors.isEmpty {
        c.errors += myErrors
        return nil
    }
    return rule
}

private func parseOnMonitorChangedArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [MonitorChangedCallback] {
    guard let arr = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    return arr.enumerated().compactMap { (index, elem) in
        parseOnMonitorChangedCallback(elem, backtrace + .index(index), &c)
    }
}

private func parseOnMonitorChangedCallback(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> MonitorChangedCallback? {
    guard let dict = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return nil
    }
    var myErrors: [ConfigParseDiagnostic] = []
    var callback = MonitorChangedCallback()

    // Parse mandatory 'run' field
    if let runOrderedJson = dict["run"] {
        callback.run = parseShellOfCommandsForConfig(runOrderedJson, backtrace + .key("run"), &c)
    } else {
        myErrors.append(.init(backtrace, "'run' is mandatory in [[on-monitor-changed]]"))
    }

    // Parse optional 'if' matcher
    if let ifOrderedJson = dict["if"], let ifDict = ifOrderedJson.asDictOrNil {
        let ifBt = backtrace + .key("if")
        if let ratioOrderedJson = ifDict["any-monitor-min-aspect-ratio"] {
            if let ratio = ratioOrderedJson.asDoubleOrNil {
                callback.matcher.anyMonitorMinAspectRatio = ratio
            } else {
                myErrors.append(expectedActualTypeDiagnostic(expected: .float, actual: ratioOrderedJson.tomlType, ifBt + .key("any-monitor-min-aspect-ratio")))
            }
        }
    }

    if !myErrors.isEmpty {
        c.errors += myErrors
        return nil
    }
    return callback
}

private func parseZonePresetsArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: ZonePreset] {
    guard let arr = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ZonePreset] = [:]
    for (index, elem) in arr.enumerated() {
        let bt = backtrace + .index(index)
        guard let dict = elem.asDictOrNil else {
            c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: elem.tomlType, bt))
            continue
        }
        guard let nameOrderedJson = dict["name"], let name = nameOrderedJson.asStringOrNil else {
            c.errors.append(.init(bt, "zone-preset must have a 'name' string field"))
            continue
        }
        var preset = ZonePreset(name: name, zones: [])
        if let rawZone = dict["zone"] {
            if let zones = parseZoneDefinitions(rawZone, bt + .key("zone"), &c) {
                preset.zones = zones
            }
        } else if dict["widths"] != nil || dict["layouts"] != nil {
            // Legacy format: widths/layouts arrays in a preset.
            if let zones = parseLegacyZoneArrays(dict, bt, &c) {
                preset.zones = zones
            }
        } else {
            c.errors.append(.init(bt, "zone-preset '\(name)' must have at least one [[zone-presets.zone]] entry"))
            continue
        }
        if !preset.zones.isEmpty {
            result[name] = preset
        }
    }
    return result
}

func parseDouble(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Double> {
    raw.asDoubleOrNil.toResult(expectedActualTypeDiagnostic(expected: .float, actual: raw.tomlType, backtrace))
}

func parseInt(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    raw.asIntOrNil.toResult(expectedActualTypeDiagnostic(expected: .int, actual: raw.tomlType, backtrace))
}

func parseString(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    raw.asStringOrNil.toResult(expectedActualTypeDiagnostic(expected: .string, actual: raw.tomlType, backtrace))
}

func parseSimpleType<T>(_ raw: OrderedJson, ofType: T.Type) -> T? {
    (raw.asIntOrNil as? T) ?? (raw.asStringOrNil as? T) ?? (raw.asBoolOrNil as? T)
}

extension OrderedJson {
    func unwrapTableWithSingleKey(expectedKey: String? = nil, _ backtrace: inout ConfigBacktrace) -> ResOrConfigParseDiagnostic<(key: String, value: OrderedJson)> {
        guard let asDictOrNil else {
            return .failure(expectedActualTypeDiagnostic(expected: .table, actual: tomlType, backtrace))
        }
        let singleKeyError: ConfigParseDiagnostic = .init(
            backtrace,
            expectedKey != nil
                ? "The table is expected to have a single key '\(expectedKey.orDie())'"
                : "The table is expected to have a single key",
        )
        guard let (actualKey, value): (String, OrderedJson) = asDictOrNil.count == 1 ? asDictOrNil.first : nil else {
            return .failure(singleKeyError)
        }
        if expectedKey != nil && expectedKey != actualKey {
            return .failure(singleKeyError)
        }
        backtrace = backtrace + .key(actualKey)
        return .success((actualKey, value))
    }
}

func parseTomlArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<OrderedJson.JsonArray> {
    raw.asArrayOrNil.toResult(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
}

func parseTable<T: ConvenienceMutable>(
    _ raw: OrderedJson,
    _ initial: T,
    _ fieldsParser: [String: any ParserProtocol<T>],
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> T {
    switch raw {
        case .dict(let table):
            return table.parseTable(initial, fieldsParser, backtrace, &c)
        default:
            c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
            return initial
    }
}

private func parseStartupRootContainerLayout(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Void> {
    parseString(raw, backtrace)
        .filter(.init(backtrace, "'non-empty-workspaces-root-containers-layout-on-startup' is deprecated. Please drop it from your config")) { raw in raw == "smart" }
        .map { _ in () }
}

private func parseLayout(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Layout> {
    parseString(raw, backtrace)
        .flatMap { $0.parseLayout().toResult(.init(backtrace, "Can't parse layout '\($0)'")) }
}

private func skipParsing<T: Sendable>(_ value: T) -> @Sendable (_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<T> {
    { _, _ in .success(value) }
}

private func parsePersistentWorkspaces(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<OrderedSet<String>> {
    parseArrayOfStrings(raw, backtrace)
        .flatMap { arr in
            let set = arr.toOrderedSet()
            return set.count == arr.count ? .success(set) : .failure(.init(backtrace, "Contains duplicated workspace names"))
        }
}

private func parseArrayOfStrings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr in
            arr.enumerated().mapAllOrFailure { (index, elem) in
                parseString(elem, backtrace + .index(index))
            }
        }
}

private func parseDefaultContainerOrientation(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<DefaultContainerOrientation> {
    parseString(raw, backtrace).flatMap {
        DefaultContainerOrientation(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse default container orientation '\($0)'"))
    }
}

extension ResOrStr where Failure == String {
    func toParsedConfig(_ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Success> {
        mapError { .init(backtrace, $0) }
    }
}

func parseBool(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Bool> {
    raw.asBoolOrNil.toResult(expectedActualTypeDiagnostic(expected: .bool, actual: raw.tomlType, backtrace))
}

struct ConfigBacktrace: CustomStringConvertible, Equatable {
    private var path: [TomlBacktraceItem] = []
    private init(_ path: [TomlBacktraceItem]) {
        check(path.first?.isKey != false, "Tried to construct invalid TOML path: \(path)")
        self.path = path
    }

    static func rootKey(_ key: String) -> Self { .init([.key(key)]) }
    static let emptyRoot: Self = .init([])

    var description: String {
        var result = ""
        for (i, elem) in path.enumerated() {
            switch elem {
                case .key(let rootKey) where i == 0: result += rootKey
                case .key(let key): result += ".\(key)"
                case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }

    var isRootKey: Bool { path.singleOrNil().map(\.isKey) == true }

    static func + (lhs: consuming Self, rhs: TomlBacktraceItem) -> Self {
        lhs.path += [rhs]
        return lhs
    }
}

enum TomlBacktraceItem: Equatable {
    case key(String)
    case index(Int)

    var isKey: Bool {
        switch self {
            case .key: true
            case .index: false
        }
    }
}

extension OrderedJson.JsonDict {
    func parseTable<T: ConvenienceMutable>(
        _ initial: T,
        _ fieldsParser: [String: any ParserProtocol<T>],
        _ backtrace: ConfigBacktrace,
        _ c: inout ConfigParserContext,
    ) -> T {
        var raw = initial

        for (key, value) in self {
            let backtrace: ConfigBacktrace = backtrace + .key(key)
            switch fieldsParser[key] {
                case let parser?: raw = parser.transformRawConfig(raw, value, backtrace, &c)
                case nil: c.errors.append(unknownKeyDiagnostic(backtrace))
            }
        }

        return raw
    }
}

func unknownKeyDiagnostic(_ backtrace: ConfigBacktrace) -> ConfigParseDiagnostic {
    .init(backtrace, backtrace.isRootKey ? "Unknown top-level key" : "Unknown key")
}

func expectedActualTypeDiagnostic(expected: TomlType, actual: TomlType, _ backtrace: ConfigBacktrace) -> ConfigParseDiagnostic {
    .init(backtrace, expectedActualTypeError(expected: expected, actual: actual))
}

func expectedActualTypeDiagnostic(expected: [TomlType], actual: TomlType, _ backtrace: ConfigBacktrace) -> ConfigParseDiagnostic {
    .init(backtrace, expectedActualTypeError(expected: expected, actual: actual))
}
