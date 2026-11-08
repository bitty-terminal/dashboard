# Dashboard

Configuration and status dashboard for the Bitty terminal.

## Overview

Dashboard is one panel over the runtime's own inspection snapshot and its
typed configuration surface: runtime diagnostics, installed plugins, installed
extensions, editable settings, profiles, and resolved paths. It answers "what
is this terminal actually running?" and lets you change the presentation
settings, plugin enablement, and active profile without hand-editing Lua or
remembering CLI verbs.

Reads come from `bitty.runtime.inspect()` (bitty#2396, merged in bitty#2410).
Writes go through the typed `config.manage` surface (bitty#2393): one
consent-bound grant covering a bounded read query and three token-bound write
pairs. The plugin has no filesystem access and no process or network
authority.

Every write is previewed first. The host renders the exact user-layer change,
returns its one-shot approval digest, and refuses the commit unless the bytes
are still identical; the panel shows that rendering and applies it only on a
second Enter.

Sections:

| Section     | Contents                                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| Overview    | App version, active profile and its source, theme and source, font, decoration, and per-section counts.             |
| Plugins     | Every reported plugin: name, version, provenance, enabled state, ledger state.                                      |
| Extensions  | Every installed extension: version, tier, ABI compatibility, activation, trust, descriptor digest, executable name. |
| Settings    | Editable allowlisted keys with current value and logical source; preview and confirm before every write.            |
| Profiles    | Defined profiles and which one is active; switch with a previewed, token-bound write.                               |
| Diagnostics | App version, config file/dir, plugin ledger, plugin store, extension roots, font, decoration.                       |

Each section either renders bounded rows or an explicit
`unavailable: <reason>` marker. A failed source is never rendered as "none
installed"; an empty source renders its own empty state instead.

Open it with `bitty-terminal.dashboard:toggle_dashboard`; the plugin installs
no default chord. For example, bind the command to `alt+g` as shown under
[Keybindings](#keybindings) and press it: the panel opens on the Overview
section, `l`/`Tab` and `h`/`Shift+Tab` move between sections, `j`/`k` move
between rows, and `Esc` closes the panel. `Enter` on a setting starts a
previewed edit; a second `Enter` applies it.

## Install

Prerequisites: Bitty `>=0.0.31` and Plugin API `^1.0`. The 0.0.31 floor is the
first release train that ships the full `config.manage` read/write verb set
(bitty#2393); an older host rejects the manifest at install time instead of
activating a panel with a surface it cannot serve. There is no declared
ceiling: a newer host is admitted rather than failed closed by an upper bound.

From the registry (once the entry is merged) or directly from this repository:

```sh
bitty plugin install https://github.com/bitty-terminal/dashboard.git
bitty plugin enable bitty-terminal.dashboard
bitty plugin list   # confirm state and granted capabilities
```

From a local checkout:

```sh
bitty plugin install ./dashboard --yes
bitty plugin enable bitty-terminal.dashboard
```

`config.manage` is high-risk, so consent presents it distinctly. Decline it and
the panel still opens with the read-only rendering described under
[Configuration](#configuration). `bitty plugin list` confirms activation: the
entry must be enabled and list the granted capabilities. A disabled entry
carries a `disabled_reason`; see [Troubleshooting](#troubleshooting).

## Commands

| Command                                     | What it does                                                     | Arguments                                                                 |
| ------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `bitty-terminal.dashboard:toggle_dashboard` | Open the panel when closed; close and release capture when open. | `width` (integer, optional, 40–240), `height` (integer, optional, 12–100) |

No default keybinding is installed. `width` and `height` are presentation
hints: the Plugin API v1 has no viewport-size surface, so they bound row
truncation and page size, while the host clips the painted panel to the live
window.

There is no standalone CLI verb for plugin commands: bind the command as a
`command:` keymap action (below), or invoke it from an existing binding. The
CLI verb `bitty cmd` addresses terminal commands, not plugin commands.

## Configuration

This plugin declares no settings.

The panel edits a bounded, presentation-safe subset of the host's writable
configuration. All writes land in your user layer through the host's atomic
writer; the panel never touches a file itself. `bitty.config.sources()` lists
the allowlisted keys and their logical source (`default`, `user`, or
`plugin:<id>`); it carries no value, so the panel reads the selected row with
`bitty.config.get()` and caches values while you browse. A profile or
trusted-local override is attributed as `user`, because the host treats those
layers as user-owned.

| Key                             | Type    | Editing                                                                                                                           |
| ------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `appearance.theme`              | text    | One-line input; theme resolution is the loader's job.                                                                             |
| `appearance.animations.enabled` | bool    | Enter toggles.                                                                                                                    |
| `font.family`                   | text    | One-line input.                                                                                                                   |
| `font.size`                     | number  | One-line input; a finite number is required.                                                                                      |
| `window.opacity`                | number  | One-line input; a finite number is required.                                                                                      |
| `window.padding`                | integer | One-line input; a non-negative integer is required.                                                                               |
| `terminal.scrollback`           | integer | One-line input; a non-negative integer is required.                                                                               |
| `terminal.cursor_style`         | enum    | Enter cycles `default`, `blinking_block`, `steady_block`, `blinking_underline`, `steady_underline`, `blinking_bar`, `steady_bar`. |
| `terminal.bell`                 | enum    | Enter cycles `off`, `visual`, `audible`, `both`.                                                                                  |
| `selection.auto_copy`           | bool    | Enter toggles.                                                                                                                    |
| `close_confirm`                 | enum    | Enter cycles `always`, `when_busy`, `never`.                                                                                      |
| `scrollbar.mode`                | enum    | Enter cycles `hidden`, `always`, `auto`.                                                                                          |
| `decoration.gaps_in`            | integer | One-line input; a non-negative integer is required.                                                                               |
| `decoration.gaps_out`           | integer | One-line input; a non-negative integer is required.                                                                               |
| `decoration.radius`             | integer | One-line input; a non-negative integer is required.                                                                               |

Every key is one of Core's `CONFIG_WRITABLE_SETTINGS` entries. Command-like
keys (`terminal.shell`), canonicalizing aliases, list-valued keys, and
`history.capture.*` are deliberately outside the subset and stay on the
CLI/user path.

The preview/confirm flow is always the same:

1. Enter on a setting starts the edit: a bool flips, an enum advances one
   value, and a text/number setting opens a one-line input seeded with the
   current value. Enter submits the input; Esc cancels it.
2. The panel calls `bitty.config.preview(key, value)` and shows the host's
   exact `rendered` diff plus the `keys` it changes.
3. A second Enter calls `bitty.config.set(key, value, digest)` with the
   one-shot digest from that preview. Esc cancels; nothing is written.
4. The panel updates the row and shows `applied · reload auto` (or
   `no change` when the value already matched).

Plugins and profiles use the same two-press contract with their own pairs:
`bitty.config.preview_enabled()` then `bitty.config.set_enabled()` on the
Plugins tab, and `bitty.profiles.preview_use()` then `bitty.profiles.use()` on
the Profiles tab. When the host exposes the profile lifecycle verbs
(bitty#2449, bitty#3035), the Profiles tab also supports creating (`n`/`a`,
`preview_create`/`create`), cloning (`c`, `preview_clone`/`clone`), renaming
(`e`/`R`, `preview_rename`/`rename`), and deleting (`d`/`x`,
`preview_delete`/`delete`) profiles with the same preview and one-shot digest
confirmation; on a host that only exposes `preview_use`/`use`, those keys
report a non-blocking notice while keeping profile switching active. A profile
switch that cannot take effect in the running process reports `restart required`
from the host's `pending_restart` flag.

If the host does not expose the surface, the grant is missing, the backend is
unwired (`--safe`), or the user layer is not a safe target, every tab keeps the
read-only `bitty.runtime.inspect()` rendering and the panel says so. No write
is attempted, and the Settings tab falls back to the declared-settings rows
with the read-only note.

## Keybindings

Bind `command:bitty-terminal.dashboard:toggle_dashboard` in your keymaps:

```lua
return {
  keymaps = {
    { chord = "alt+g", action = "command:bitty-terminal.dashboard:toggle_dashboard", context = "global" },
  },
}
```

A single-character key needs a modifier; named keys may stand alone. Use
`bitty inspect key <chord>` (or `bitty +list-keybinds`) to check a binding before relying on it.

While the panel is open it owns a transient input capture, so its own keys are:

| Key                   | Action                                                           |
| --------------------- | ---------------------------------------------------------------- |
| `j` / `Down`          | Next row                                                         |
| `k` / `Up`            | Previous row                                                     |
| `h` / `Left`          | Previous section                                                 |
| `l` / `Right`, `Tab`  | Next section                                                     |
| `Shift+Tab`           | Previous section                                                 |
| `1` … `6`             | Jump to a section                                                |
| `g` / `Home`          | First row                                                        |
| `G` / `End`           | Last row                                                         |
| `PageUp` / `PageDown` | One page up or down                                              |
| Mouse wheel           | Scroll the active section                                        |
| `Enter`               | Edit the selected setting, or preview the selected toggle/switch |
| `Space`               | Toggle the selected plugin                                       |
| `n` / `a`             | Create a new profile on the Profiles tab                         |
| `c`                   | Clone the selected profile on the Profiles tab                   |
| `e` / `R`             | Rename the selected profile on the Profiles tab                  |
| `d` / `x`             | Preview deleting the selected profile on the Profiles tab        |
| `Enter` (again)       | Apply the previewed change                                       |
| `Esc`                 | Cancel the edit or confirm step, or close the panel              |
| `r`                   | Re-read the snapshot and the managed values                      |
| `q`                   | Close the panel                                                  |

While an input is open, printable characters type into it, `Backspace`
deletes, `Enter` previews, and `Esc` cancels. While a change is awaiting
confirmation, only `Enter` (apply) and `Esc` (cancel) act.

## Troubleshooting

**The binding does nothing.** Check `bitty --version` first: hosts older than
0.0.31 do not know the full `config.manage` verb set and reject the manifest.
Then confirm the plugin is enabled and granted in `bitty plugin list`.

**The Settings tab says read-only.** `config.manage` is not usable for this
generation: the grant is missing or denied, the host was started with
`--safe` (the backend is unwired, so calls return `E_CONFIG_UNAVAILABLE`), or
the user layer is not a safe target (`E_CONFIG_UNSAFE`). No write is
attempted. Re-grant with `bitty plugin install bitty-terminal.dashboard --yes`,
restart without `--safe`, or check `bitty plugin info
bitty-terminal.dashboard` for the recorded grant set.

**A change says "the value changed, review again".** The user layer moved
between your preview and the commit (another edit, or a profile switch). The
panel re-previewed the same value; review the new rendering and press Enter
again.

**A change says "approval expired, review again".** The one-shot digest was
already spent or timed out. The panel re-previewed it; press Enter again.

**A profile switch says "restart required".** The persisted selector changed,
but the running process cannot adopt the new profile live. The panel shows the
host's `pending_restart` flag; restart Bitty to finish the switch.

**A plugin row says "unmanaged".** Only ledger-managed plugins can be toggled
through `config.manage`; a bundled or unrecorded plugin stays read-only.

**A section shows `unavailable: source unavailable`.** That section's host
source could not be read. It is not an empty list and not "none installed"; the
rest of the panel is unaffected.

**The panel will not open while another modal is up.** Only one plugin may own
the overlay capture at a time. Close the command palette or composer first.

**The panel closes by itself.** The host ends an overlay capture after 30 s
without activity. While the panel is open it re-arms a generation-owned timer
that polls the session to stay alive. That budget is finite: a session is
released after ten minutes even without input, so an abandoned panel cannot
hold capture indefinitely; open it again to continue. If the host refuses
timers (`E_BUDGET_TIMER`) or the plugin is suspended, the transient capture
timeout applies instead.

**Clicking tabs does nothing.** Captured pointer presses carry no coordinates,
and the host does not route overlay click/scroll bindings yet. Keyboard and
wheel navigation are the supported paths.

## Capabilities

Three grants, deny by default:

| Capability         | Why                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| `runtime.inspect`  | Read-only data source for the unmanaged sections: one argument-free, 64 KiB-bounded snapshot.    |
| `ui.overlay.focus` | The accepted W-01 focusable overlay plus its transient input capture.                            |
| `config.manage`    | High-risk, consent-bound writes: bounded reads plus one-shot-digest `preview`/`set` write pairs. |

`ui.overlay.focus` is required because the host paints an `overlay`-slot block
only for the plugin that owns the capture session; the spec-path
`bitty.ui.overlay.acquire()` mounts the surface directly, so the presentation
grants (`ui.rich`, `ui.overlay`) are not requested.

`config.manage` is the only write authority. The host enforces the recorded
grant, the allowlist, per-generation call/byte budgets, and a one-shot digest
bound to the exact rendered bytes; the panel's preview/confirm flow is a UI
contract layered on top, never a replacement for that token.

Not requested: `runtime.configure`, `runtime.plugin-manage`, `terminal.input.*`,
any `fs.*`, `process.*`, `network.connect`, `clipboard.*`, all platform heads,
and every debug grant. There is no shell, install-time execution, or network
path in this plugin.

## Development

```sh
just install   # materialize pinned dev dependencies (network, once)
just check     # lint + fmt-check + manifest + docs + lua + test
```

`just check` runs Markdown lint and Prettier, validates `bitty-plugin.toml`
with the SDK-pinned `bitty-plugin-lint`, validates this README against the SDK
user-documentation contract, parses every Lua source with `luac5.4 -p` (plus a
fail-closed parser control), and runs two suites:

- `lua5.4 tests/run.lua` — 110 behavior checks over display bounds, snapshot
  normalization, path redaction, section rows, both layouts (80×24 and
  120×40), direct-child overlay flattening, key and wheel navigation, the
  overlay lifecycle and its error/timeout release paths, the `config.manage`
  adapter, the edit state machine, and the full preview/confirm/apply flow
  against an in-process host stub, including stale digests, denied grants,
  plugin toggles, and profile switches.
- `bun test tests/manifest.test.ts` — the manifest validator, the exact
  capability set, the lazy command and event set, and the README contract.

Layout:

| Path                        | Purpose                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `bitty-plugin.toml`         | Static manifest: identity, compat, grants, lazy triggers.   |
| `lua/dashboard/init.lua`    | Commands, events, overlay session, and captured input.      |
| `lua/dashboard/config.lua`  | Bounded `config.manage` adapter and curated key subset.     |
| `lua/dashboard/edit.lua`    | Input/confirm state machine and typed value parsing.        |
| `lua/dashboard/inspect.lua` | Read-only snapshot adapter and row normalization.           |
| `lua/dashboard/model.lua`   | Pure section rows, paging, selection, and key navigation.   |
| `lua/dashboard/render.lua`  | Declarative `Text`/`Row`/`Column`/`List` scene builder.     |
| `lua/dashboard/text.lua`    | Bounded strings, path redaction, and UTF-8-safe truncation. |
| `tests/`                    | Lua behavior suite plus the manifest/README contract test.  |

## Known gaps

- Extension install/remove stays read-only; only settings, plugin enablement,
  and profile selection have typed write surfaces today.
- The editable set is a curated presentation subset of Core's allowlist.
  Command-like keys (`terminal.shell`), canonicalizing aliases, list-valued
  keys, and anything that changes what the next launch executes stay on the
  CLI/user path.
- Overlay pointer routing is not part of the accepted host contract yet, so
  tab clicks are not delivered. The wheel is captured and works.
- The panel is transient by host contract: it owns input capture while open and
  releases on `q`/`Esc`, focus switch, unload, activity timeout, the ten-minute
  keep-alive ceiling, or a failed poll/repaint.

## Security

Report vulnerabilities through the process in the umbrella project's security
policy rather than a public issue. This plugin contains no credentials, no
install-time execution, and no ambient authority. Treat the runtime snapshot
as untrusted data: it is bounded, sanitized, and path-shaped tokens are
redacted before rendering. Configuration values and host error messages follow
the same rule, and every write requires the host's one-shot approval digest.
