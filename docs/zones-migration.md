# Migrating an AeroSpace configuration to the zones fork

This fork adds zones, window placement memory, and zone indicators to AeroSpace. Start with a backup of your existing TOML configuration. The fork reads the normal AeroSpace configuration; it does not require you to replace your bindings or use the examples below. Existing Vim-style `alt-h/j/k/l` bindings continue to work unless you choose to change them.

## What changes on an ultrawide

By default, a display with a visible width-to-height ratio greater than 2.1 uses three equal zones named `left`, `center`, and `right`. This changes how windows are tiled on such displays even if your old config has no `[zones]` table. Normal-aspect displays use the regular workspace tiling tree. Custom names, proportions, and layouts are described in [ULTRAWIDE.md](../ULTRAWIDE.md).

The display-specific icon overlay appears on screens with a width-to-height ratio of at least 2.3 and more than one active zone. It shows clickable windows by zone and a separate floating-window group when needed. It overlays the macOS menu bar rather than registering a normal status item; in a crowded menu bar it may cover other items.

Holding Option displays zone borders and compact shortcut help. The overlay reads the **active mode's actual parsed bindings** from the loaded configuration and groups common window and zone actions, including Vim keys or custom modifiers. It shows up to two groups of alternate keys per action; an ellipsis indicates more. Shell arguments and unrelated bindings are omitted. The activation gesture itself is currently fixed to holding Option; it is not controlled by a keybinding in TOML. On release the overlay disappears.

## Optional shortcuts

Add only bindings you want to the **existing** `[mode.main.binding]` section, choosing keys that don't conflict with your current setup. These are examples, not required defaults:

```toml
# Focus a zone, or move the focused window into it.
alt-ctrl-1 = 'focus-zone left'
alt-ctrl-2 = 'focus-zone center'
alt-ctrl-3 = 'focus-zone right'
alt-ctrl-shift-1 = 'move-node-to-zone left'
alt-ctrl-shift-2 = 'move-node-to-zone center'
alt-ctrl-shift-3 = 'move-node-to-zone right'

# Cycle the current zone through horizontal, vertical, and stacked windows.
alt-slash = 'layout --zone --cycle h_tiles v_tiles stack'
# Toggle the focused window between floating and tiled.
alt-t = 'layout floating tiling'
# Switch windows within the focused container; useful for stacks.
alt-ctrl-tab = 'focus --scope current-container --wrap-around dfs-next'
alt-ctrl-shift-tab = 'focus --scope current-container --wrap-around dfs-prev'
# Adjust a zone boundary in points.
alt-ctrl-minus = 'resize --zone width -50'
alt-ctrl-equal = 'resize --zone width +50'
```

If your existing config uses any of these keys, keep your current binding or choose another key; TOML cannot contain the same binding twice in one mode. The names `left`, `center`, and `right` above must match your own configured zone IDs.

`layout --zone` applies to the current zone rather than an inner split. With no zones, it targets the workspace root. `--cycle` advances through the supplied descriptions in order; without it, AeroSpace retains the existing first-nonmatching toggle behavior. `move-node-to-zone` turns a floating window back into a tile in the chosen zone; `move-floating-to-zone` moves it while keeping it floating. `layout stack tiles` toggles the focused container, which can be a nested container rather than the whole zone.

Check and reload after editing:

```sh
aerospace reload-config --dry-run --no-gui
aerospace reload-config
```

Review any warnings before reloading. Zone definitions and window arrangements can change when the config is reloaded, so verify the result on your displays.

## Placement and floating windows

Zone layout snapshots and window placement memories are saved under `~/Library/Application Support/AeroSpace/`. Floating positions and sizes are remembered by app, window title, and display profile when the floating window is manipulated or returned to tiling. When a matching window is floated again, its saved frame is restored if it fits in the chosen zone. Otherwise it is centered with a smaller default size. Matching deliberately avoids guessing when multiple windows have indistinguishable identities. A new window does not automatically become floating merely because an earlier instance had a saved floating frame.

These memories are local to the Mac and are not stored in the TOML or the repository. Keep backups if the arrangements are important. A freshly rebuilt, ad-hoc-signed app can require Accessibility permission to be re-enabled in macOS System Settings.

The fork has `tiles`, `accordion`, and `stack` layouts. It does not currently implement a scrolling workspace or a zone-wide floating workspace.

## Building this branch

This branch is based on upstream v0.21.3-Beta plus the [johnstegeman zones branch](https://github.com/johnstegeman/AeroSpace/tree/zones), with additional local changes. It is not yet a port to the latest upstream `main`. Use an Xcode toolchain compatible with the package and macOS SDK.

From a clean checkout, build the CLI and app separately:

```sh
swift build -c release --product aerospace
xcodebuild -project xcode/AeroSpace.xcodeproj -scheme AeroSpace \
  -configuration Release -derivedDataPath .build/xcode \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES build
```

The results are `.build/release/aerospace` and `.build/xcode/Build/Products/Release/AeroSpace.app`. Back up your installed app, CLI, and TOML before replacing them; quit the running app first. After installation, confirm `aerospace --version` and re-enable Accessibility if macOS asks. Ad-hoc signatures can require renewed permission after each rebuild. Do not run `build-release.sh` in a checkout with uncommitted work: it resets tracked files.

The fork includes a port of upstream [balance-sizes/resize fix 80092f30](https://github.com/nikitabobko/AeroSpace/commit/80092f303face86d3987826a10bcc6724508c2b0), adapted for stack layouts. Other newer upstream changes have not been merged wholesale.
