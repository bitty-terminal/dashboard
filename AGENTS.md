# Dashboard repository guidance

## Repository and authority

- This is the independent `dashboard` repository. Its canonical remote is
  <https://github.com/bitty-terminal/dashboard>.
- The Bitty umbrella directory and
  [bitty-plugins](https://github.com/bitty-terminal/bitty-plugins) are grouping
  only; neither owns this repository's Git or CarryCtx state.
- Enter this repository before running Git, CarryCtx, validation, or toolchain
  commands.
- [bitty-terminal-docs](https://github.com/bitty-terminal/bitty-terminal-docs),
  [bitty-plugins-docs](https://github.com/bitty-terminal/bitty-plugins-docs),
  and [bitty-docs](https://github.com/bitty-terminal/bitty-docs) are the
  canonical sources for plugin architecture, API, security, packaging,
  compatibility, and public-behavior contracts. This repository must not
  invent capabilities, lifecycle semantics, or release policy.

## Plugin identity and scope

- Plugin id: `bitty-terminal.dashboard` (manifest `plugin.id`), repository
  `dashboard`, Lua module `lua/dashboard/`.
- Purpose: a read-only configuration/status panel over
  `bitty.runtime.inspect()` (bitty#2396, merged in bitty#2410), presented
  through the accepted W-01 focusable-overlay and transient-input-capture
  contract.
- Authority boundary: only `runtime.inspect` and `ui.overlay.focus`. No
  `config.manage`, no `runtime.configure`, no `runtime.plugin-manage`, no
  filesystem, process, network, clipboard, terminal-input, platform, or debug
  authority, and no install-time execution.
- Settings, plugin enable/disable, profile switching, and extension management
  are read-only displays until the typed `config.manage` API (bitty#2393)
  lands. Never claim write support; the panel and README must keep saying that
  editing is deferred.

## Terminology

- User-facing text says **extensions** for installable artifacts.
- **components** is reserved for the internal host seam. A host-recorded
  activation class such as `component_untrusted` may be shown verbatim because
  it is a Core-authored label, not this repository's vocabulary.
- Never add a stale catalog of plugin or extension names; the panel renders
  what the host reports.

## CarryCtx and delivery

- Use this repository's CarryCtx state for tasks, dependencies, scopes,
  sessions, progress, decisions, checkpoints, handoffs, and review.
- The commander coordinates; implementation is delegated to scoped subagents
  and accepted by a different reviewer. Self-reports are not acceptance
  evidence.
- Branches use `ctx-XXXX/<type>-<short-slug>` after the first commit; before
  that, shared-checkout initialization is allowed for disjoint scopes with the
  full local gate.
- Do not commit, push, release, publish packages, create repositories, or
  mutate remote state without authorization.

## No hardcoded values

- Never hardcode host- or environment-specific values: absolute paths,
  usernames, hostnames, repository URLs beyond the canonical identity above,
  credentials, ports, or machine layout.
- Named constants own policy bounds (row caps, layout bounds, timeouts).
- Tests and fixtures must not embed a developer's home or checkout path; use
  synthetic paths under `/home/tester` only as redaction fixtures.

## Toolchain policy

- JavaScript runs on `bun` (pinned in `package.json`).
- Run gates through the justfile: `just check`, `just lint`, `just fmt`,
  `just manifest`, `just docs`, `just lua`, `just test`.
- Version pins live in exactly one place: `package.json` + `bun.lock` for
  installed dev dependencies. Do not bump pins as a side effect of an
  unrelated task; report drift instead.
- CI success is a hard acceptance gate. Validate workflow changes with
  `actionlint` before push.

## Security and supply chain

- The manifest, the runtime snapshot, and captured input are untrusted data.
  Bound and sanitize before rendering; redact absolute host paths.
- Keep the requested capability set minimal and declared in
  `bitty-plugin.toml`; the manifest is the single source of authority.
- No secrets, tokens, or local configuration in the repository, fixtures,
  logs, or CI output.

## Verification and handoff

- Ephemeral scratch goes under `/tmp/bitty/`; durable material goes under
  repo-local `recording/` (gitignored).
- Run `just check`, `actionlint` on affected workflows, and
  `gitleaks detect --source .` before concluding a change.
- Report changed files, exact evidence, residual risks, and remaining work.
