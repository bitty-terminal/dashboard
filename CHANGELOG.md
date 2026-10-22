# Changelog

All notable changes to `bitty-terminal.dashboard` are recorded here. The
format follows Keep a Changelog; versions follow the plugin's own `0.0.x`
line while the host is pre-1.0.

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
