# Ultrawide Zone Layout

## The Problem

Ultrawide monitors (aspect ratio > 2.1) present a fundamental challenge for tiling window managers: the default behavior of splitting the full screen into tiles works well on a 16:9 display but produces absurdly wide windows on a 32:9 or 21:9 panel. A single horizontal split fills each half with a window that is wider than it is useful. A cascade of tiles quickly produces windows that no one would intentionally size that way.

The intuitive solution — divide the screen into three vertical columns ("zones") and treat each column as its own independent tiling region — is not something AeroSpace supported. Workspaces had one root container. There was no concept of named regions within a workspace, no way to steer new windows into a specific column, and no UI feedback about which column was active.

## What We Built

We added a first-class **zone system** that activates automatically on ultrawide monitors and treats the workspace as three independent tiling regions: `left`, `center`, and `right`.

### Zone Containers

Each workspace on an ultrawide monitor gets three persistent tiling containers injected as direct children of the workspace root. These containers:

- Are flagged as zone containers (`isZoneContainer = true`) so the normalizer never flattens or removes them
- Are sized according to configurable proportional widths
- Are automatically created when a workspace lands on an ultrawide monitor and torn down when it leaves
- Survive config reloads

### Configuration

A new `[zones]` table in the TOML config controls zone behavior:

```toml
[zones]
# Gap in pixels between zone containers (separate from inner gaps)
gap = 8

[[zones.zone]]
id = "left"
width = 0.25
layout = "tiles"

[[zones.zone]]
id = "center"
width = 0.50
layout = "tiles"

[[zones.zone]]
id = "right"
width = 0.25
layout = "tiles"
```

Zone widths must sum to 1.0. Zone IDs can be any non-empty string; the default three-zone config uses `left`, `center`, and `right`. Layouts default to `tiles` if omitted.

The old `widths = [...]` and `layouts = [...]` flat arrays are still accepted for backward compatibility but are deprecated — migrate to `[[zones.zone]]` entries.

### New Commands

#### `focus-zone <zone-id>`
#### `focus-zone --scope mru`

Focuses the most-recently-used window in the named zone. If the zone is empty, sets a one-shot **placement hint**: the next new tiling window opened will be routed into that zone. The menu bar indicator updates immediately to reflect the pending zone.

`--scope mru` skips the explicit zone name and instead focuses the most-recently-used *zone* that is not the currently active one. This is useful when you frequently switch between two specific zones and don't want to remember their physical names:

```toml
[mode.main.binding]
alt-tab = 'focus-zone --scope mru'
```

MRU zone state is in-memory only and resets on AeroSpace restart.

#### `move-node-to-zone [--no-focus] <zone-id>`

Moves the focused window into the named zone container and saves that assignment to persistent zone memory (see below). The window is focused after the move.

Pass `--no-focus` to move the window without stealing focus. This is the recommended form when calling `move-node-to-zone` from an `[[on-window-detected]]` callback so that opening a new app does not involuntarily pull focus away from your current window:

```toml
[[on-window-detected]]
check-app-id = 'com.tinyspeck.slackmacgap'
run = 'move-node-to-zone --no-focus right'

[[on-window-detected]]
check-app-id = 'com.spotify.client'
run = 'move-node-to-zone --no-focus left'
```

Zone memory is updated on every `move-node-to-zone` call, so subsequent openings of the app are routed automatically by zone memory without needing the callback. If `[zones.app-routing]` also defines that app, the explicit app route still wins; zone memory remains the fallback when no explicit route applies.

#### `move-floating-to-zone <zone-id>`

Repositions a floating window into the named zone without converting it to a tiling window. The window is not resized; its UL-corner offset relative to its current zone is preserved in the target zone. Zone memory is updated so a subsequent `move-node-to-zone` lands the window in the correct zone.

#### `show-workspace-menu`

Pops up an NSMenu of all workspaces at the center of the focused window (or monitor if no window is focused). Selecting an entry switches focus to that workspace. Useful for quickly navigating workspaces without remembering keybindings.

#### `show-zone-picker`

Shows a short-lived HUD centered on the focused ultrawide workspace. The overlay is intentionally lightweight and command-first: it displays each zone's ID, layout, occupancy count, active/pending state, and the current preset name without introducing a persistent editor.

Clicking a zone card runs the equivalent of `focus-zone <zone-id>`, so the HUD doubles as a quick zone picker when you want a little more visual confirmation than a blind keybinding.

#### `overview-zones`

Shows a persistent overview HUD for the focused ultrawide workspace. This is the first slice of the larger overview/editor direction: it visualizes the current zones using their live widths, shows per-zone state, and exposes command-backed controls for focusing zones, cycling a zone's layout, applying presets, resetting presets, and toggling presentation mode.

The overview remains intentionally lightweight. It is a visual front-end over existing commands, not a second layout engine.

#### `list-zones`
#### `zone --json`

Query the current zone state for scripts, bars, and debugging.

`list-zones` returns the zones on the focused workspace as JSON, one object per zone. The first implementation is intentionally narrow: focused workspace only, JSON-first, and stable field names:

```json
[
  {
    "workspace": "1",
    "monitor-id": 1,
    "monitor-name": "DELL U4025QW",
    "zone-id": "left",
    "layout": "h_accordion",
    "is-focused": false,
    "window-count": 2,
    "weight": 1100.8
  }
]
```

`zone --json` returns the single active zone object for the focused workspace. This is useful when a bar item or script only needs "where am I right now?" rather than the whole zone list.

These commands were added to make zone behavior observable without scraping the menu bar or re-deriving state from window positions. They are the foundation for later zone events, formatting variables, and richer debugging tools.

#### `subscribe zone-focused zone-preset-changed`

Adds two zone-native subscription events:

- `zone-focused` emits when the active zone changes, including the empty-zone path where `focus-zone` targets a zone that does not yet contain a window.
- `zone-preset-changed` emits after `zone-preset` rebuilds the zone containers and includes the new preset name, or `null` when `zone-preset --reset` restores the default widths/layouts.

These were added so bars and scripts can react to zone actions directly instead of polling `list-zones` and diffing snapshots after every command.

#### `subscribe zone-layout-changed zone-window-count-changed`

Adds the second wave of zone-native events:

- `zone-layout-changed` emits when a zone's layout string changes, such as `h_tiles` to `h_accordion`.
- `zone-window-count-changed` emits when the tiling window count for a zone changes.

These events are driven from zone snapshot diffs, so they stay aligned with the observable `list-zones` surface instead of each command inventing its own event payload rules.

#### Formatting variables

Adds three zone-native interpolation variables anywhere workspace format variables are supported:

- `%{zone}` returns the active zone name, or `NULL-ZONE` when there is no active zone.
- `%{zone-layout}` returns the active zone layout, or `NULL-ZONE-LAYOUT` when there is no active zone.
- `%{zone-window-count}` returns the number of tiling windows in the active zone, or `0` when there is no active zone.

Because these are implemented as workspace-scoped format variables, they work in `list-workspaces --format ...` directly and also in window formats that already inherit workspace state.

#### `list-windows --format '%{window-zone}'`

Adds per-window zone introspection to the existing `list-windows` surface instead of introducing a parallel `list-zone-windows` command.

- `%{window-zone}` returns the zone that actually contains the window.
- Windows outside the zone system report `NULL-ZONE`.
- The variable is JSON-safe, so scripts can use `list-windows --format '%{window-id} %{window-zone}' --json` and group windows by zone without re-deriving membership from geometry.

### Automatic Window Routing

When a new tiling window appears on a zoned workspace, AeroSpace decides which zone to place it in using this priority order:

1. **Explicit app routing** — if `[zones.app-routing]` maps the app bundle ID to an active zone, that route wins.
2. **Zone memory** — if the app was previously assigned to a zone on this monitor configuration, it goes back there.
3. **One-shot placement hint** (`focus-zone` on an empty zone) — the pending zone set by the user.
4. **MRU zone** — the zone containing the most-recently-focused window inherits the new window.
5. **Middle-zone fallback** — if none of the above apply, the window goes to the middle zone by definition order (`center` in the default 3-zone layout).

App routing is ignored when zones are inactive or when the configured target zone is not present in the active preset/layout.

### Declarative App Routing

Use `[zones.app-routing]` for simple “this app normally belongs in this zone” defaults:

```toml
[zones.app-routing]
"com.tinyspeck.slackmacgap" = "right"
"com.apple.mail" = "right"
"com.googlecode.iterm2" = "left"
```

This is a runtime placement rule, not `on-window-detected` sugar. It does not steal focus and it overrides zone memory, which makes it practical to keep a stable default zone for an app even if you occasionally move individual windows elsewhere. A manual `move-node-to-zone` still updates zone memory, but that remembered value is only consulted when no explicit app route applies.

### Per-Zone Insertion Policy

Once the destination zone is chosen, that zone decides where inside itself the new window lands:

```toml
[zones.behavior.left]
new-window = "append"

[zones.behavior.center]
new-window = "after-focused"

[zones.behavior.right]
new-window = "append-hidden"
```

Supported policies:

- `after-focused` (default): insert after the most-recently-focused window already in that zone. If the zone is empty, append to the zone root.
- `append`: always append to the zone root. Useful for stack-like utility columns where you do not want new windows inserted into nested editor splits.
- `append-hidden`: append to the zone root, but if the zone layout is `stack`, preserve the previously active child so the new window is added in the background instead of immediately replacing the visible stack tab.

This runs after zone selection, so the same zone-routing inputs still apply. The insertion policy only changes local placement within the chosen zone.

### Presentation / Screen-Share Mode

`presentation-mode on` applies a temporary workspace-local share layout on the currently focused ultrawide workspace.

- The center zone is sized as a full-height `16:9` region derived from the current monitor height.
- Side zones become `stack` layouts intended for chat, notes, controls, and overflow windows.
- The currently focused tiling window moves to `center`; other tiling windows are redistributed to `left` or `right`.
- The previous zone definitions, active preset name, and per-zone window ordering for that workspace are snapshotted and restored by `presentation-mode off`.
- Forced zone rebuilds such as config reloads keep presentation mode active instead of silently dropping back to the configured preset.
- If the ultrawide monitor goes away while presentation mode is active, the temporary presentation state is dropped automatically without rewriting persistent zone memory.
- Persistent zone memory is intentionally left untouched, so the temporary share layout does not pollute normal routing behavior.

For a `5120×1440` monitor, the resulting layout is:

- `left`: `1280px`
- `center`: `2560px`
- `right`: `1280px`

```text
presentation-mode on
presentation-mode off
presentation-mode toggle
show-zone-picker
overview-zones
```

### Zone Memory

Zone assignments are persisted to `~/Library/Application Support/AeroSpace/zone-memory.json`. Assignments are keyed by:

- **Monitor profile** — a stable fingerprint of all connected monitors (size + position, sorted). This means the memory is specific to your ultrawide setup and doesn't interfere when you unplug it.
- **App bundle ID** — one zone per app per monitor profile.

This means unplugging your ultrawide and re-attaching it later restores apps to their remembered zones automatically.

Two commands make the persisted store inspectable and resettable:

```text
zone-memory list
zone-memory clear --app-id com.googlecode.iterm2
zone-memory clear --all
```

These commands operate on the full persisted store, not just the current workspace. `zone-memory list` returns JSON rows keyed by monitor-profile fingerprint, which makes the per-monitor-profile scope explicit instead of implicit. Explicit app-routing remains higher priority than these remembered entries.

For live routing observability, `subscribe window-routed` emits a JSON event whenever the runtime placement pipeline routes a window into a zone. The event includes the chosen `zoneName` and the routing `source` (`appRouting`, `zoneMemory`, `focusedZoneHint`, and so on). `debug-windows` also exposes the last recorded placement source and the currently remembered zone-memory entry for the window's app when a zone profile is active.

### Menu Bar Indicator

When zones are active on the focused workspace, the menu bar tray appends a zone indicator to the workspace name:

```
1 : left [center] right
```

Brackets mark the currently active zone (the zone containing the focused window, or the one-shot hint zone). Zone IDs are shown in full so that zones with the same first letter remain distinct (e.g. `main`, `messages`, `music`). Single-character zone IDs (e.g. `l`, `c`, `r`) continue to display as SF Symbol squares in the icon tray.

### Named Zone Layout Presets

Define named sets of zone widths and layouts in the config, then switch between them at runtime:

```toml
[[zone-presets]]
name = "dev"

[[zone-presets.zone]]
id = "left"
width = 0.25
layout = "accordion"

[[zone-presets.zone]]
id = "center"
width = 0.50
layout = "tiles"

[[zone-presets.zone]]
id = "right"
width = 0.25
layout = "tiles"

[[zone-presets]]
name = "comms"

[[zone-presets.zone]]
id = "left"
width = 0.20
layout = "tiles"

[[zone-presets.zone]]
id = "center"
width = 0.60
layout = "accordion"

[[zone-presets.zone]]
id = "right"
width = 0.20
layout = "tiles"
```

Switch presets with:

```
zone-preset dev          # apply the "dev" preset
zone-preset --reset      # restore the original zones config from the config file
zone-preset --save dev   # save the current zone widths/layouts as a new runtime preset named "dev"
zone-preset --export     # print the current zones as a [[zone-presets]] TOML block (paste into config)
```

`--save <name>` captures whatever zone layout is currently active — useful after tweaking widths with `balance-sizes` or interactively resizing zones. The saved preset is available immediately as `zone-preset <name>` for the rest of the session but is not persisted to disk; use `--export` to get a TOML snippet you can paste into your config file to make it permanent.

Per-zone gap overrides (`[zones.overrides.*]`) are **not** part of presets and survive preset switches.

```toml
[mode.main.binding]
alt-1 = 'zone-preset dev'
alt-2 = 'zone-preset comms'
alt-0 = 'zone-preset --reset'
```

### Monitor-Profile Automation

Declare named monitor profiles that are automatically matched and applied whenever the monitor configuration changes, at startup, and on config reload. The first matching profile wins.

```toml
[[monitor-profiles]]
name = "home-ultrawide"
match.min-aspect-ratio = 2.0
apply-zone-layout = "dev"
restore-workspace-snapshot = "home"

[[monitor-profiles]]
name = "laptop-only"
match.monitor-count = 1
apply-zone-layout = "disabled"
```

**Matching criteria** (all are optional; a profile with no `match` fields always matches):

| Field | Type | Meaning |
|---|---|---|
| `match.min-aspect-ratio` | float | Match if any connected monitor has `width/height ≥ value` |
| `match.monitor-count` | int | Match if the total monitor count equals `value` |

**Actions:**

| Field | Type | Meaning |
|---|---|---|
| `apply-zone-layout` | string | Apply named zone preset, or `"disabled"` to suppress zones even on ultrawide |
| `restore-workspace-snapshot` | string | Restore named snapshot — only fires on profile **change**, not repeated evaluation |

**How this relates to `zone-preset`:** `apply-zone-layout = "name"` is equivalent to running `zone-preset name`. It changes `config.zones` at runtime, rebuilds zone containers on all workspaces with `force: true`, and emits a `zone-preset-changed` event.

**`apply-zone-layout = "disabled"`:** Deactivates zone containers on all workspaces even if the monitor is ultrawide. Clearing the flag (by switching to a different profile without `disabled`) re-activates them normally.

**Interaction with `[[on-monitor-changed]]`:** Both mechanisms fire on the same monitor-topology events. Monitor profiles fire after `on-monitor-changed` commands have been queued. Use `[[on-monitor-changed]]` for scripting and side effects; use `[[monitor-profiles]]` for declarative zone-layout switching.

---

### on-monitor-changed

`[[on-monitor-changed]]` fires whenever the monitor configuration changes — both when a monitor is connected and when one is disconnected. Rules are evaluated in order; all matching rules fire.

```toml
[[on-monitor-changed]]
if.any-monitor-min-aspect-ratio = 2.0
run = 'workspace-snapshot restore dev'

[[on-monitor-changed]]
# no 'if' — fires on every topology change
run = 'exec-and-forget ~/.config/aerospace/on-monitor-changed.sh'
```

**`if.any-monitor-min-aspect-ratio`** — optional matcher. When set, the rule only fires if at least one currently-connected monitor has `width/height >= value` at the time the event fires (i.e., after the connect or disconnect has already taken effect). Omitting `if` means the rule always fires.

This is the recommended way to restore a layout when your ultrawide connects:

```toml
[[on-monitor-changed]]
if.any-monitor-min-aspect-ratio = 2.0
run = 'workspace-snapshot restore dev'
```

### Event Stream (subscribe)

AeroSpace exposes a streaming event subscription for external tools (SketchyBar, custom scripts, etc.):

```sh
aerospace subscribe --all
aerospace subscribe focus-changed workspace-changed monitor-changed
```

Each event is a JSON object written to stdout, one per line. Supported event types:

| Event | Key fields |
|---|---|
| `focus-changed` | `windowId`, `workspace`, `appName` |
| `focused-workspace-changed` | `workspace`, `prevWorkspace` |
| `focused-monitor-changed` | `workspace`, `monitorId` |
| `mode-changed` | `mode` |
| `window-detected` | `windowId`, `workspace`, `appBundleId`, `appName` |
| `binding-triggered` | `mode`, `binding` |
| `monitor-changed` | `monitorCount` |

**SketchyBar integration** — SketchyBar supports custom events via `sketchybar --trigger`. A bridge script is the standard pattern:

```sh
#!/usr/bin/env bash
# ~/.config/aerospace/sketchybar-bridge.sh
# Run this as a background process alongside SketchyBar.
aerospace subscribe monitor-changed workspace-changed focus-changed | while IFS= read -r event; do
    type=$(echo "$event" | jq -r '._event')
    sketchybar --trigger "aerospace_${type}" info="$event"
done
```

SketchyBar items subscribe to the custom event and update themselves:

```lua
sketchybar --add event aerospace_monitor_changed
sketchybar --subscribe my_item aerospace_monitor_changed
-- item script receives $INFO with the full JSON payload
```

Pass `--no-send-initial` to suppress the initial state snapshot that is otherwise sent on connection.

---

#### Bridge script (`plugins/aerospace_bridge.sh`)

Subscribes to `focused-workspace-changed` and `focus-changed`, fires custom sketchybar events:

```sh
/usr/local/bin/aerospace subscribe focused-workspace-changed focus-changed --no-send-initial | \
while IFS= read -r line; do
    EVENT=$(printf '%s' "$line" | sed 's/.*"_event":"\([^"]*\)".*/\1/')
    case "$EVENT" in
        focused-workspace-changed)
            WS=$(printf '%s' "$line" | sed 's/.*"workspace":"\([^"]*\)".*/\1/')
            sketchybar --trigger aerospace_workspace_changed workspace="$WS" ;;
        focus-changed)
            APP=$(printf '%s' "$line" | sed 's/.*"appName":"\([^"]*\)".*/\1/')
            sketchybar --trigger aerospace_focus_changed app_name="$APP" ;;
    esac
done
```

Started on every `sketchybar --reload` (previous instance killed first). Custom events `aerospace_workspace_changed` and `aerospace_focus_changed` must be registered with `sketchybar --add event` before items subscribe.

#### Monitor-aware bar layout

`sketchybarrc` detects ultrawide vs laptop via physical pixel width from `system_profiler`:

| Setting | Ultrawide (≥5000px) | Laptop |
|---|---|---|
| `margin` | `screen_width × 0.32 + 5` (zone-centered) | `0` (full width) |
| `y_offset` | `0` (overlays menu bar) | `0` (overlays menu bar, left of notch) |
| `padding_left` | `640` | `680` (positions pills just left of notch) |
| `padding_right` | `480` | `10` |
| Items shown | all | workspace pills only |

`on-monitor-changed` in `aerospace.toml` runs `exec-and-forget /usr/local/bin/sketchybar --reload` so the bar automatically reconfigures when the ultrawide is connected or disconnected.

### Per-Zone Outer-Gap Overrides

Individual zones can override the global outer gap on any side. Override values are **absolute pixel distances from the screen edge** — they replace the global value for that zone, they do not add to it. Omitting a side means the zone inherits the global `outer-gaps` value for that side unchanged.

This lets you reserve space for an external bar (e.g. sketchybar) in only one zone, without wasting that space in the others:

```toml
# Global gap accounts for menu bar (25px) + sketchybar (40px) sitting above the dock.
# On laptop (no zones), this applies everywhere.
[gaps]
outer.bottom = 65

# On ultrawide, sketchybar only occupies the bottom of the center zone.
# Left and right zones reclaim that space — their bottom gap is just the dock clearance.
[zones.overrides.left]
bottom = 25

[zones.overrides.right]
bottom = 25

# center inherits outer.bottom = 65 from [gaps] — no override needed
```

Because override values can be set below the global, left/right zones effectively "expand downward" into the space the global gap had reserved for sketchybar.

### Zone Focus Mode

A command to temporarily maximize one zone while collapsing the others to 8px slivers:

```
zone-focus-mode [--zone <left|center|right>] (on|off|toggle)
```

`on` — collapse all zones except the target zone. If `--zone` is omitted, the currently focused zone (or MRU zone) is used.
`off` — restore zones to their weights at the time `on` was called.
`toggle` — turns on if currently off, off if currently on.

```toml
[mode.main.binding]
alt-z = 'zone-focus-mode toggle'            # toggle focus mode on current zone
alt-shift-z = 'zone-focus-mode off'          # explicitly exit focus mode
```

When `focus-zone` is called while focus mode is active and the target zone differs from the current focused zone, focus mode automatically shifts to the new zone (discarding prior saved weights and re-capturing current weights).

Collapsed zones remain visible at 8px. Zone weights captured at `on` time are restored exactly on `off` — not from config defaults.

### Per-Zone Default Layouts

Each zone can have its own default tiling layout (`tiles`, `accordion`, `stack`). When `ensureZoneContainers()` creates a zone container for the first time it applies the configured layout for that position.

### Workspace Snapshots

Save and restore the current window arrangement across all workspaces:

```
workspace-snapshot save dev      # save current layout as "dev"
workspace-snapshot restore dev   # restore windows to their saved zones
```

Snapshot names must match `[a-zA-Z0-9_-]+`. Snapshots are saved to `~/Library/Application Support/AeroSpace/snapshots/<name>.json`.

**Save:** For each workspace, records which zone each tiling window belongs to (by app bundle ID). Floating windows are recorded separately.

**Restore:** For each zone entry, finds a running window with the matching bundle ID (first-come-first-served for apps with multiple windows) and binds it to the recorded zone. Missing apps are skipped gracefully. Excess windows stay in their current location.

```toml
[mode.main.binding]
alt-s = 'workspace-snapshot save dev'
alt-r = 'workspace-snapshot restore dev'
```

### Startup Placement

On startup, existing windows are distributed across zones based on zone memory before the first layout pass, so windows land in the right columns immediately rather than all piling into center.

### Accordion Cascade Mode

The accordion layout now supports a `cascade` mode where every window in the stack has a visible strip, rather than only the one directly behind the focused window.

```toml
[accordion]
mode = "cascade"   # vs "overlap" (default)
offset-x = 24      # horizontal shift per window depth level
offset-y = 0       # vertical shift per window depth level
padding = 30       # peek size used in overlap mode
```

In cascade mode, each window is offset by `(i * offset-x, i * offset-y)` from the container origin, and all windows share the same size (container dimensions minus total offset). The focused window is naturally on top due to OS focus z-order.

### Accordion Indicator Overlay

> Ported from [nikitabobko/AeroSpace#2038](https://github.com/nikitabobko/AeroSpace/pull/2038) by [@frecano](https://github.com/frecano).

When an accordion zone contains more than one window, a floating icon strip appears along the zone edge showing each window's app icon. Clicking an icon focuses that window. The focused window's icon is highlighted; others are dimmed.

The indicator only appears with ≥2 windows. When it is showing, the zone's content area is automatically inset on the indicator side so windows never slide underneath the overlay.

```toml
[accordion-indicator]
enabled = true
icon-size = 30          # app icon size in points
icon-padding = 2        # padding between icons
bar-padding = 4         # padding inside the indicator bar
position = 'left'       # left | right | top | bottom
vertical-navigation = false  # if true, up/down always navigates accordion regardless of orientation
```

The inset is computed from `icon-size + bar-padding * 2 + 4` (the fixed gap between indicator and window edge) and applied during the layout pass — so it participates in all the same gap override and zone focus mode math as the rest of the layout.

### Stack Layout for Zones

A `stack` zone layout shows one window at a time — the most-recently-focused child fills the entire zone rect, and all other children are stacked behind it (at the same position, in z-order behind the active window). This is ideal for narrow utility columns (chat, mail, music) where you want a stable-width region that never gets visually messy regardless of how many windows you park there.

```toml
[[zones.zone]]
id = "left"
width = 0.22
layout = "stack"    # one window visible at a time

[[zones.zone]]
id = "center"
width = 0.56
layout = "tiles"

[[zones.zone]]
id = "right"
width = 0.22
layout = "stack"
```

**Navigation:** `focus up` / `focus down` cycles through stack children (previous / next). `focus left` / `focus right` navigates to the adjacent zone, as normal.

**Stack indicator bar:** A tab-bar-style overlay shows each window's app icon and name. Clicking an entry focuses that window. The active entry is highlighted.

```toml
[stack-indicator]
enabled = true
bar-height = 28           # height of the bar in points
icon-size = 20            # app icon size in points
icon-padding = 4          # padding between icon and label
bar-padding = 4           # padding inside the bar panel
position = "top"          # top | bottom | left | right
show-title = true         # show app name next to icon
```

The bar is positioned inside the zone: content is inset by `bar-height + 4` on the `position` side, and the bar panel fills the remaining strip. The inset participates in the same layout pass as gap overrides and zone focus mode.

**Runtime toggle:** `layout stack` changes the focused window's parent container to stack layout, exactly like `layout accordion`. Toggle between layouts with:

```
layout tiles stack      # toggle current zone between tiles and stack
```

### DFS Scope for Accordion Cycling

`focus dfs-next` and `focus dfs-prev` now accept a `--scope` flag to limit cycling to the immediate parent container of the focused window:

```
focus dfs-next --scope current-container   # cycles within accordion stack or zone only
focus dfs-prev --scope current-container
focus dfs-next --scope workspace           # default: all windows in workspace
```

This is the recommended binding for cycling through an accordion stack without jumping to other zones.

### Sticky Floating Windows

A floating window can be marked **sticky** so it follows the user across workspace switches. Sticky windows are useful for persistent overlays — terminals, music players, reference docs — that should always be visible regardless of which workspace is active.

#### Usage

```
layout sticky    # make the focused window floating and sticky
layout floating  # remove sticky (window stays floating but no longer follows)
layout tiling    # tile the window and remove sticky
```

`layout sticky` is a superset of `layout floating`: it makes the window floating AND marks it sticky in one command. Toggling between `sticky` and `floating` does not resize the window.

#### Persistence

Sticky state is saved to `~/Library/Application Support/AeroSpace/sticky-windows.json` and survives AeroSpace restarts. The window will be floating and sticky the next time AeroSpace starts, regardless of which workspace it was on when AeroSpace quit.

#### Behavior

When the user switches to a different workspace, all sticky floating windows on the previous workspace are moved to the new workspace before the layout pass runs. They remain at their current screen position.

---

### Floating Defaults

Many real configs end up with a long run of identical `[[on-window-detected]]` rules whose only purpose is to float specific apps:

```toml
[[on-window-detected]]
if.app-id = 'com.apple.finder'
run = ['layout floating']
```

That works, but it is verbose and obscures the real intent: some apps simply belong in the floating layer by default.

The fork now supports a dedicated config primitive for that common case:

```toml
[floating]
app-ids = [
  'com.apple.finder',
  'com.raycast.macos',
  'com.1password.1password',
]
```

#### Why this was added

- It replaces repetitive callback boilerplate with a declarative default.
- It makes configs easier to read: “these apps float” instead of “run this callback for each app”.
- It leaves `[[on-window-detected]]` available for the cases that are actually conditional or procedural.

#### Behavior

- Each listed bundle ID is handled by the runtime placement pipeline before generic `[[on-window-detected]]` callbacks run.
- Matching windows are floated directly, without lowering `[floating]` into synthetic callbacks.
- Explicit `[[on-window-detected]]` callbacks still run afterward, so conditional automation remains the escape hatch for special cases.

Use `[floating]` for simple “always float this app” defaults. Use `[[on-window-detected]]` when the action depends on title matching, workspace routing, startup state, or multi-step logic.

---

### Window Borders

An integrated border renderer that draws a colored outline around tiling windows — similar to jankyborders, but with zero lag because borders are updated synchronously as part of AeroSpace's own layout pass.

#### Configuration

```toml
[borders]
enabled = true
width = 2.0

# 0xAARRGGBB hex integer format
active-color = 0xff5e81ac     # border on the focused window
inactive-color = 0x00000000   # 0x00... = transparent = no border for inactive windows

# App bundle IDs that should never receive a border.
# Useful for apps whose install/auth dialogs break when an overlay panel is present.
ignore-app-ids = ["com.apple.AppStore", "com.apple.systempreferences"]
```

Setting `inactive-color` to a non-transparent color draws borders around all visible tiling windows (not just the focused one). Setting it to `0x00000000` (the default) means only the focused window gets a border.

#### Notes

- Borders are drawn as transparent `NSPanel` overlays at `normal+1` window level — above normal windows but below floating-level windows (PiP, system overlays). This prevents borders from bleeding through always-on-top windows.
- Borders are removed immediately when a window is closed or garbage-collected.
- Border colors sync on every focus change, not just on layout passes, so the active border updates immediately when clicking between windows.
- No ricing by default — `enabled = false` is the default. Opt in explicitly.

---

### Debug Logging

AeroSpace writes a structured debug log to `~/Library/Logs/AeroSpace/debug.log` (rotates at 4 MB, previous saved as `debug.log.old`). Logged events include: refresh session triggers, focus changes, window detection/close, and monitor rearrangements.

#### Marker command

Drop a visible marker into the log so you can find what happened before a bug:

```
debug-log-marker [--label <text>]
```

Bind it to a key for instant use when something goes wrong:

```toml
[mode.main.binding]
hyper-b = 'debug-log-marker'
```

Then inspect the log:

```sh
tail -100 ~/Library/Logs/AeroSpace/debug.log
# or live:
tail -f ~/Library/Logs/AeroSpace/debug.log
```

---

### Scratchpad

An i3-style **scratchpad** workspace for windows that don't belong in the main layout but need fast, hotkey-driven access. The scratchpad is a hidden workspace named `__scratchpad__`; its windows are never part of any visible tiling or floating layout unless explicitly summoned.

#### Commands

```
send-to-scratchpad [--window-id <id>]   # send focused (or specified) window to the scratchpad
scratchpad                               # toggle: summon MRU scratchpad window, or hide it if already visible
```

**`send-to-scratchpad`**: Moves the focused window into the scratchpad workspace as a floating window. If the window is currently tiling, it is automatically floated first. The window's current position and size are saved for restoration.

**`scratchpad`**: Toggle behavior —
- If the focused window is a scratchpad window visible on the current workspace → it is sent back to the scratchpad workspace (hidden).
- Otherwise → the most-recently-used scratchpad window is moved to the current workspace as a floating window at its last known position. If no position was remembered, it is centered on the monitor.

Subsequent presses of `scratchpad` cycle through scratchpad windows in MRU order: each call shows the next hidden window. Already-visible scratchpad windows are not reshown until hidden again.

#### Persistence

The set of scratchpad windows and their last-known positions are saved to `~/Library/Application Support/AeroSpace/scratchpad-windows.json`. On restart, scratchpad windows are returned to the scratchpad workspace automatically regardless of which regular workspace they were on when AeroSpace quit.

#### Notes

- The scratchpad workspace is hidden from `list-workspaces` output and cannot be switched to via the `workspace` command.
- Sticky and scratchpad are independent features: a scratchpad window is not sticky (it stays in the scratchpad workspace when you switch workspaces, rather than following you).

---

### Bug Fix: Zone Containers Lost After Closed-Windows Cache Restore

**Symptom:** On ultrawide, zone containers disappeared across all workspaces whenever a frequently-appearing/disappearing window (e.g. the Granola nub overlay) triggered the closed-windows cache restore. Tiling windows (Slack, Dia, etc.) would be laid out flat across the full screen width instead of within their zones.

**Root cause:** AeroSpace's closed-windows cache protects against the lock screen (where all AX API returns empty, making AeroSpace think every window closed). When any window reappears that was in the cache, the entire world tree is restored via `restoreTreeRecursive`. This function created new `TilingContainer` objects with `isZoneContainer = false` (the default), and the workspace's `zoneContainers` dict was left pointing to the now-detached old containers. On the next `refreshModel()` call, `normalizeContainers` treated the restored zone containers as ordinary single-child containers and flattened them, promoting windows into `rootTilingContainer` directly. Since `zoneContainers` wasn't empty (stale entries), `ensureZoneContainers` never re-activated zones.

**Fix:** During freeze (`FrozenContainer`), tag each zone container child with its zone name. During restore (`restoreTreeRecursive`), clear the stale `zoneContainers` dict, set `isZoneContainer = true` on the recreated containers, and re-register them in `workspace.zoneContainers`.

### Bug Fix: on-monitor-changed Not Firing After Sleep + Disconnect

**Symptom:** Disconnecting the ultrawide while the MacBook is asleep, then opening the lid, left AeroSpace confused about the monitor setup: sketchybar was not notified (via `monitor-changed` subscribe event or `[[on-monitor-changed]]` rules), zones remained active on the now-laptop-only session, and window layouts were wrong.

**Root cause:** `gcMonitors()` in `Workspace.swift` guards `rearrangeWorkspacesOnMonitors()` with a simple count check: `screenPointToVisibleWorkspace.count != monitors.count`. When the ultrawide is disconnected during sleep, both before and after sleep there is exactly 1 monitor (ultrawide → MacBook built-in), both at origin (0, 0). Count stays 1, origin stays the same, so `rearrangeWorkspacesOnMonitors()` was never called and `on-monitor-changed` never fired.

**Fix:** Extend the guard in `gcMonitors()` to also compare the monitor resolution profile (a multiset of `MonitorProfile.MonitorEntry`) against `previousMonitorEntries`. Since `MonitorEntry` is `Hashable`, the same `[entry: count]` dictionary comparison that `rearrangeWorkspacesOnMonitors()` uses internally is applied up front. A same-count substitution (different resolution or aspect ratio) now correctly triggers rearrangement and fires all `on-monitor-changed` callbacks.
