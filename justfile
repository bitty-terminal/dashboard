# Quality gates for Dashboard (bitty-terminal.dashboard).
#
# Dependencies are pinned in package.json and locked in bun.lock; `just
# install` materializes them and `just deps` fails closed when they are
# missing. Every gate below runs offline once install has completed. Never use
# npm, npx, or yarn in this repository.

# Pinned parser version; keep identical to the luaparse devDependency in
# package.json.
luaparse_pin := "0.3.1"

# Lua 5.4 compiler used as a parse-only checker (`-p` writes no output).
# Override with `LUAC=/path/to/luac5.4 just check` when your platform names
# the binary differently.
luac := env("LUAC", "luac5.4")

# List available recipes.
default:
    @just --list

# Install pinned dev dependencies from bun.lock. This is the only gate step
# that may use the network; install once, then `just check` is offline.
install:
    bun install --frozen-lockfile

# Fail closed when dependencies are absent, so a gate never silently fetches
# from the network. Run `just install` first.
deps:
    @test -d node_modules || { echo "dependencies are not installed; run 'just install'" >&2; exit 1; }

# Lint all Markdown sources with markdownlint-cli2 (.markdownlint-cli2.jsonc).
lint: deps
    bun run markdownlint-cli2

# Format all files with Prettier.
fmt: deps
    bun run prettier --write . --ignore-unknown

# Check formatting of all files with Prettier.
fmt-check: deps
    bun run prettier --check . --ignore-unknown

# Validate bitty-plugin.toml with the authoritative SDK linter (R-SDK-2),
# pinned by commit in package.json and bun.lock. The manifest schema is owned
# by bitty-docs, not by this repository.
manifest: deps
    @test -x node_modules/.bin/bitty-plugin-lint || { echo "bitty-plugin-lint is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-lint bitty-plugin.toml

# Validate README.md against the SDK user-documentation contract: the six
# required H2 sections in order, and the Configuration table matching
# `[settings]` (this plugin declares none, so the exact no-settings sentence).
docs: deps
    @test -x node_modules/.bin/bitty-plugin-docs-check || { echo "bitty-plugin-docs-check is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-docs-check .

# Parse every Lua source with a pinned Lua 5.1 grammar parser.
lua: deps
    @test -x node_modules/.bin/luaparse || { echo "luaparse is not installed; run 'just install'" >&2; exit 1; }
    bun run luaparse --quiet --file lua/dashboard/init.lua
    bun run luaparse --quiet --file lua/dashboard/inspect.lua
    bun run luaparse --quiet --file lua/dashboard/model.lua
    bun run luaparse --quiet --file lua/dashboard/render.lua
    bun run luaparse --quiet --file lua/dashboard/text.lua
    {{ luac }} -p lua/dashboard/init.lua
    {{ luac }} -p lua/dashboard/inspect.lua
    {{ luac }} -p lua/dashboard/model.lua
    {{ luac }} -p lua/dashboard/render.lua
    {{ luac }} -p lua/dashboard/text.lua

# Fail-closed control for the parse gate: the same checkers must reject an
# invalid snippet, so a lost file argument cannot silently pass.
lua-control: deps
    @! bun run luaparse --quiet --code 'local =' 2>/dev/null
    @! printf 'local =\n' | {{ luac }} -p - 2>/dev/null

# Run the Lua behavior suite: bounded strings, snapshot normalization, section
# rows, both layouts, key/wheel navigation, and the overlay lifecycle against
# an in-process host stub.
test-lua:
    lua5.4 tests/run.lua

# Run the manifest/README contract suite against the pinned SDK commit.
test-manifest: deps
    bun test tests/manifest.test.ts

# Run all behavior and contract tests.
test: test-lua test-manifest

# Aggregate gate run locally and in CI (after `just install`).
check: lint fmt-check manifest docs lua lua-control test
