# Changelog

All notable changes to `bitty-terminal.dashboard` are recorded here. The
format follows Keep a Changelog; versions follow the plugin's own `0.x` line
while the host is pre-1.0.

## [0.2.0] - 2026-11-07

### Added

- Typed `config.manage` editing (bitty#2393): allowlisted settings, plugin
  enablement, and profile selection, each through the host's
  `preview` → confirm → `set` one-shot-digest flow.
- Settings tab renders the key and logical source for the editable subset and
  reads the selected row's current value with `config.get`; bools toggle,
  enums cycle, and text/number values open a one-line input seeded with the
  current value.
- Plugins tab toggles ledger-managed plugins with `Space`/`Enter`; Profiles
  tab switches profiles and reports the host's `pending_restart` flag.
- Bounded `config.manage` adapter (`lua/dashboard/config.lua`) and an
  input/confirm state machine (`lua/dashboard/edit.lua`).
- Row selection cursor with a highlighted selected row.

### Changed

- Manifest: version `0.2.0`, the high-risk `config.manage` grant, and a
  `bitty >=0.0.31` compatibility floor (the first release with the full
  read/write verb set).
- README documents the preview/confirm flow, the editable keys, the source
  labels, and the degraded read-only mode.

### Removed

- The "settings editing is deferred until config.manage" claim and the
  read-only title on a host that grants the capability.

### Fixed

- Enter delivered as a carriage return (platform key text) now starts an edit
  and confirms an apply, not just `key:Enter`.

## [0.0.1] - 2026-10-22

### Added

- Read-only dashboard panel over `bitty.runtime.inspect()` with six sections:
  Overview, Plugins, Extensions, Settings, Profiles, Diagnostics.
- `toggle_dashboard` command (`bitty-terminal.dashboard:toggle_dashboard`) and
  the lazy command reservation that makes it bindable without a VM.
- Bounded keyboard and wheel navigation inside the panel; `r` refreshes the
  snapshot, `q`/`Esc` closes and releases the capture session.
- Typed `unavailable: <reason>` markers per section, explicit empty states, and
  bounded rows at 80×24 and 120×40.
- Path redaction: diagnostics and extension rows show presence plus a basename,
  never an absolute host path.
- A visible read-only statement that settings editing is deferred until the
  typed `config.manage` API (bitty#2393).
