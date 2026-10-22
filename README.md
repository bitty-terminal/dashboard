# Dashboard

Read-only configuration and status dashboard for the Bitty terminal.

## Overview

Dashboard is one panel over the runtime's own read-only inspection snapshot:
runtime diagnostics, installed plugins, installed extensions, declared
settings, profiles, and resolved paths. It answers "what is this terminal
actually running?" without asking you to read Lua config files or remember CLI
verbs.

Everything on screen comes from `bitty.runtime.inspect()` (bitty#2396, merged
in bitty#2410). The plugin has no other data source, no filesystem access, and
no process or network authority.

> Status: the dashboard is read-only by design. Editing settings, toggling
> plugins, and switching profiles are **not implemented** and are explicitly
> deferred until the typed `config.manage` API (bitty#2393) lands with its
> security review. The panel title and its read-only note state this; nothing
> here writes configuration.

Sections:

| Section     | Contents                                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| Overview    | App version, active profile and its source, theme and source, font, decoration, and per-section counts.             |
| Plugins     | Every reported plugin: name, version, provenance, enabled state, ledger state.                                      |
| Extensions  | Every installed extension: version, tier, ABI compatibility, activation, trust, descriptor digest, executable name. |
| Settings    | Declared settings rows with current value, shipped default, and source layer.                                       |
| Profiles    | Defined profiles and which one is active.                                                                           |
| Diagnostics | App version, config file/dir, plugin ledger, plugin store, extension roots, font, decoration.                       |

Each section either renders bounded rows or an explicit
`unavailable: <reason>` marker. A failed source is never rendered as "none
installed"; an empty source renders its own empty state instead.

## Install

Prerequisites: Bitty `>=0.0.26` and Plugin API `^1.0`. The 0.0.26 floor is
the first release train that ships `bitty.runtime.inspect()`; an older host
rejects the manifest at install time instead of activating a panel with no
data. There is no declared ceiling: a newer host is admitted rather than
failed closed by an upper bound.

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

`bitty plugin list` confirms activation: the entry must be enabled and list the
granted capabilities. A disabled entry carries a `disabled_reason`; see
[Troubleshooting](#troubleshooting).

## Commands

| Command                                     | What it does                                                     | Arguments                                                 |
| ------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------- |
| `bitty-terminal.dashboard:toggle_dashboard` | Open the panel when closed; close and release capture when open. | `width` (integer, optional), `height` (integer, optional) |

No default keybinding is installed. `width` and `height` are presentation
hints: the Plugin API v1 has no viewport-size surface, so they bound row
truncation and page size, while the host clips the painted panel to the live
window.

There is no standalone CLI verb for plugin commands: bind the command as a
`command:` keymap action (below), or invoke it from an existing binding. The
CLI verb `bitty cmd` addresses terminal commands, not plugin commands.

## Configuration

This plugin declares no settings.

The panel does not read or write your configuration. Declared settings are
displayed read-only: editing them is deferred until the typed `config.manage`
API (bitty#2393) lands, and the panel's Settings section says so in place.

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
`bitty key <chord>` to check a binding before relying on it.

While the panel is open it owns a transient input capture, so its own keys are:

| Key                   | Action                            |
| --------------------- | --------------------------------- |
| `j` / `Down`          | Next row                          |
| `k` / `Up`            | Previous row                      |
| `h` / `Left`          | Previous section                  |
| `l` / `Right`, `Tab`  | Next section                      |
| `Shift+Tab`           | Previous section                  |
| `1` … `6`             | Jump to a section                 |
| `g` / `Home`          | First row                         |
| `G` / `End`           | Last row                          |
| `PageUp` / `PageDown` | One page up or down               |
| Mouse wheel           | Scroll the active section         |
| `r`                   | Re-read `bitty.runtime.inspect()` |
| `q` / `Esc`           | Close the panel                   |

## Troubleshooting

**The binding does nothing.** Check `bitty --version` first: hosts older than
0.0.26 have no `bitty.runtime.inspect()` and reject the manifest. Then confirm
the plugin is enabled and granted in `bitty plugin list`.

**The panel shows `unavailable` or does not open.** The host denied
`bitty.runtime.inspect` or `ui.overlay.focus`. A denied snapshot still opens
the panel and renders `unavailable: <reason>` in each section; a denied overlay
grant (or safe mode) keeps the panel closed and the command returns `false`.
Re-grant with `bitty plugin install bitty-terminal.dashboard --yes`, or check
`bitty plugin info bitty-terminal.dashboard` for the recorded grant set.

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

Two grants, deny by default:

| Capability         | Why                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------- |
| `runtime.inspect`  | The only data source: one argument-free, read-only, 64 KiB-bounded snapshot per refresh. |
| `ui.overlay.focus` | The accepted W-01 focusable overlay plus its transient input capture.                    |

`ui.overlay.focus` is required because the host paints an `overlay`-slot block
only for the plugin that owns the capture session; the spec-path
`bitty.ui.overlay.acquire()` mounts the surface directly, so the presentation
grants (`ui.rich`, `ui.overlay`) are not requested.

Not requested: `config.manage`, `runtime.configure`, `runtime.plugin-manage`,
`terminal.input.*`, any `fs.*`, `process.*`, `network.connect`,
`clipboard.*`, all platform heads, and every debug grant. There is no shell,
install-time execution, or network path in this plugin.

## Development

```sh
just install   # materialize pinned dev dependencies (network, once)
just check     # lint + fmt-check + manifest + docs + lua + test
```

`just check` runs Markdown lint and Prettier, validates `bitty-plugin.toml`
with the SDK-pinned `bitty-plugin-lint`, validates this README against the SDK
user-documentation contract, parses every Lua source with `luac5.4 -p` (plus a
fail-closed parser control), and runs two suites:

- `lua5.4 tests/run.lua` — 70 behavior checks over display bounds, snapshot
  normalization, path redaction, section rows, both layouts (80×24 and
  120×40), direct-child overlay flattening, key and wheel navigation, the
  overlay lifecycle and its error/timeout release paths against an in-process
  host stub, and leak checks for host paths and command identifiers.
- `bun test tests/manifest.test.ts` — the manifest validator, the exact
  capability set, the lazy command and event set, and the README contract.

Layout:

| Path                        | Purpose                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `bitty-plugin.toml`         | Static manifest: identity, compat, grants, lazy triggers.   |
| `lua/dashboard/init.lua`    | Commands, events, overlay session, and captured input.      |
| `lua/dashboard/inspect.lua` | Read-only snapshot adapter and row normalization.           |
| `lua/dashboard/model.lua`   | Pure section rows, paging, and key/wheel navigation.        |
| `lua/dashboard/render.lua`  | Declarative `Text`/`Row`/`Column`/`List` scene builder.     |
| `lua/dashboard/text.lua`    | Bounded strings, path redaction, and UTF-8-safe truncation. |
| `tests/`                    | Lua behavior suite plus the manifest/README contract test.  |

## Known gaps

- Settings, plugin enable/disable, profile switching, and extension
  install/remove are read-only placeholders until `config.manage` (bitty#2393)
  and the management APIs ship with their security reviews.
- Overlay pointer routing is not part of the accepted host contract yet, so
  tab clicks are not delivered. The wheel is captured and works.
- The panel is transient by host contract: it owns input capture while open and
  releases on `q`/`Esc`, focus switch, unload, activity timeout, the ten-minute
  keep-alive ceiling, or a failed poll/repaint.

## Security

Report vulnerabilities through the process in the umbrella project's security
policy rather than a public issue. This plugin contains no credentials, no
install-time execution, and no ambient authority. Treat the runtime snapshot as
untrusted data: it is bounded, sanitized, and path-shaped tokens are redacted
before rendering.
