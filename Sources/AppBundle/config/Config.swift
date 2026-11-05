import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl
/// Original zones config from the last config file load. Used by `zone-preset --reset`.
@MainActor var defaultZonesConfig: ZonesConfig = ZonesConfig()

struct Config: ConvenienceMutable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordion: AccordionConfig = AccordionConfig()
    var accordionIndicator: AccordionIndicatorConfig = AccordionIndicatorConfig()
    var stackIndicator: StackIndicatorConfig = StackIndicatorConfig()
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var floating: FloatingConfig = FloatingConfig()
    var zones: ZonesConfig = ZonesConfig()
    var zonePresets: [String: ZonePreset] = [:]
    var monitorProfiles: [MonitorProfileRule] = []
    var onMonitorChanged: [MonitorChangedCallback] = []
    var hud: HUDConfig = HUDConfig()
    var borders: BorderConfig = BorderConfig()

    var onModeChanged: Shell<any Command> = .empty
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

struct FloatingConfig: ConvenienceMutable, Equatable {
    /// App bundle IDs whose windows should float by default.
    var appIds: [String] = []
}

/// A declarative monitor-profile rule: matched against the current monitor set and applied
/// automatically on monitor topology changes, startup, and config reload.
struct MonitorProfileRule: ConvenienceMutable, Equatable {
    var name: String = ""
    var matcher: MonitorProfileRuleMatcher = MonitorProfileRuleMatcher()
    /// Named zone preset to apply when this profile matches, or "disabled" to suppress zones.
    /// nil means "don't change the current zone layout".
    var applyZoneLayout: String? = nil
    /// Workspace snapshot to restore when this profile is newly activated.
    var restoreWorkspaceSnapshot: String? = nil
}

/// Criteria for [[monitor-profiles]] matching. All fields are optional; omitting a field means
/// the rule always matches on that criterion (i.e. it's a wildcard for that dimension).
struct MonitorProfileRuleMatcher: ConvenienceMutable, Equatable {
    /// Match when at least one connected monitor has width/height aspect ratio >= this value.
    var minAspectRatio: Double? = nil
    /// Match when the total number of connected monitors equals this value.
    var monitorCount: Int? = nil
}

/// Rule that fires when the monitor configuration changes (monitor connected or disconnected).
struct MonitorChangedCallback: ConvenienceMutable {
    var matcher: MonitorChangedMatcher = MonitorChangedMatcher()
    var run: Shell<any Command> = .empty
}

/// Matcher for [[on-monitor-changed]] rules. All fields are optional; omitting a field means
/// the rule always matches on that criterion.
struct MonitorChangedMatcher: ConvenienceMutable, Equatable {
    /// If set, the rule only fires when at least one currently-connected monitor has
    /// width/height aspect ratio >= this value.
    var anyMonitorMinAspectRatio: Double? = nil
}

/// A single zone in a zone layout — stable ID, proportional width, and default layout.
struct ZoneDefinition: Equatable {
    var id: String
    var width: Double
    var layout: Layout
}

struct ZoneBehavior: ConvenienceMutable, Equatable {
    var newWindow: ZoneNewWindowPolicy = .afterFocused
}

enum ZoneNewWindowPolicy: String, Equatable {
    case append = "append"
    case afterFocused = "after-focused"
    case appendHidden = "append-hidden"
}

/// A named zone layout preset that can be switched to at runtime via `zone-preset <name>`.
struct ZonePreset: ConvenienceMutable {
    var name: String
    var zones: [ZoneDefinition]
}

struct HUDConfig: ConvenienceMutable {
    var activeOn: HUDActiveOn = .ultrawide
}

struct BorderConfig: ConvenienceMutable {
    var enabled: Bool = false
    var width: Double = 2.0
    /// Corner radius in points. 10.0 matches macOS native window corners (Big Sur+).
    var cornerRadius: Double = 10.0
    /// Active (focused) window border color in 0xAARRGGBB format.
    var activeColor: AeroColor = AeroColor(argb: 0xff5e81ac)
    /// Inactive window border color. Transparent by default (no border for inactive windows).
    var inactiveColor: AeroColor = .transparent
    /// App bundle IDs that should never receive a border (e.g. ["com.apple.AppStore"]).
    var ignoredApps: [String] = []
}

/// An ARGB color stored as four UInt8 components. Sendable and TOML-parseable.
struct AeroColor: ConvenienceMutable, Sendable {
    var alpha: UInt8
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    static let transparent = AeroColor(argb: 0x00000000)

    init(argb: Int) {
        alpha = UInt8((argb >> 24) & 0xFF)
        red   = UInt8((argb >> 16) & 0xFF)
        green = UInt8((argb >> 8)  & 0xFF)
        blue  = UInt8(argb         & 0xFF)
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(red)/255, green: CGFloat(green)/255, blue: CGFloat(blue)/255, alpha: CGFloat(alpha)/255)
    }

    var isTransparent: Bool { alpha == 0 }
}

enum HUDActiveOn: String {
    case ultrawide, always, never
}

struct AccordionConfig: ConvenienceMutable {
    var mode: AccordionMode = .overlap
    var padding: Int = 30
    var offsetX: Int = 24
    var offsetY: Int = 0
}

enum AccordionMode: String {
    case overlap, cascade
}

struct ZonesConfig: ConvenienceMutable {
    /// Ordered zone definitions. Each entry has a stable ID, a proportional width, and a layout.
    /// Widths must sum to 1.0. Defaults to three equal tiles named left/center/right.
    var zones: [ZoneDefinition] = [
        ZoneDefinition(id: "left",   width: 1.0 / 3, layout: .tiles),
        ZoneDefinition(id: "center", width: 1.0 / 3, layout: .tiles),
        ZoneDefinition(id: "right",  width: 1.0 / 3, layout: .tiles),
    ]
    /// Gap in pixels between zone containers. Does not affect gaps within zones.
    var gap: Int = 0
    /// Width in pixels that non-focused zones are collapsed to when zone-focus-mode is active.
    /// Large enough to show notification badges (≥40) without being readable (≤120). Default 80.
    var focusModeCollapsedWidth: Int = 80
    /// Per-zone insertion behavior for newly created tiling windows.
    /// Unspecified zones use the default `.afterFocused` behavior.
    var behavior: [String: ZoneBehavior] = [:]
    /// Declarative app-bundle-id to zone routing defaults.
    /// These apply only when the target zone exists in the active layout.
    var appRouting: [String: String] = [:]
    /// Per-zone outer-gap overrides keyed by zone name. A nil side inherits the global gap unchanged.
    var overrides: [String: ZoneGapOverride] = [:]
}

/// Absolute outer-gap override for a single zone. Each non-nil side is the pixel distance from the
/// screen edge for that zone — it replaces (not adds to) the global outer-gap value for that side.
/// nil means inherit the global outer-gap value.
struct ZoneGapOverride: ConvenienceMutable {
    var top: Int? = nil
    var bottom: Int? = nil
    var left: Int? = nil
    var right: Int? = nil
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}

struct StackIndicatorConfig: ConvenienceMutable, Equatable {
    var enabled: Bool = false
    var iconSize: Int = 20
    var iconPadding: Int = 4
    var barPadding: Int = 4
    var barHeight: Int = 28
    var position: StackIndicatorPosition = .top
    var showTitle: Bool = true
}

enum StackIndicatorPosition: String, Equatable {
    case top, bottom, left, right
}
