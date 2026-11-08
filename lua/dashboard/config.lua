-- Bounded adapter over the shipped `config.manage` plugin surface
-- (CTX-1613/CTX-1647, bitty#2393).
--
-- The host exposes one recorded grant for a bounded read query and three
-- token-bound writes:
--
--   bitty.config.get(key)                     -> { key, found, value, kind, source, redacted }
--   bitty.config.sources()                    -> { rows = { { key, source } }, count, truncated }
--   bitty.config.preview(key, value)          -> { digest, rendered, keys }
--   bitty.config.set(key, value, digest)      -> { applied, reload }
--   bitty.plugins.list()                      -> { rows = { { id, enabled, managed, source, version } }, truncated }
--   bitty.config.preview_enabled(id, enabled) -> { digest, rendered, keys, changed }
--   bitty.config.set_enabled(id, enabled, d)  -> { changed, reload }
--   bitty.profiles.list()                            -> { rows = { { name, active } }, active, truncated }
--   bitty.profiles.preview_use(name)                 -> { digest, rendered, keys, changed }
--   bitty.profiles.use(name, digest)                 -> { active, changed, reload, pending_restart }
--   bitty.profiles.preview_create(name, opts?)       -> { digest, rendered, changed_keys, changed, replaces_existing, selector_updated, active }
--   bitty.profiles.create(name, opts_or_digest, d?)  -> { name, created, changed, replaced, backed_up, extends, preset, reload }
--   bitty.profiles.preview_clone(src, dst, opts?)    -> { digest, rendered, changed_keys, changed, replaces_existing, selector_updated, active }
--   bitty.profiles.clone(src, dst, opts_or_d, d?)    -> { source, name, target, cloned, changed, replaced, backed_up, extends, reload }
--   bitty.profiles.preview_rename(old, new, opts?)   -> { digest, rendered, changed_keys, changed, replaces_existing, selector_updated, active }
--   bitty.profiles.rename(old, new, opts_or_d, d?)   -> { old_name, new_name, name, renamed, changed, replaced, backed_up, selector_updated, reload }
--   bitty.profiles.preview_delete(name, opts?)       -> { digest, rendered, changed_keys, changed, replaces_existing, selector_updated, active }
--   bitty.profiles.delete(name, opts_or_d, d?)       -> { name, deleted, changed, backed_up, was_active, reload }
--
-- Every write needs the one-shot digest from the matching preview. Nothing in
-- this module guesses at a value: the typed scalar and its kind come from the
-- host, and a malformed reply is dropped instead of trusted. No call here
-- opens a file, spawns a process, or touches the network.
--
-- The dashboard edits a bounded, presentation-safe subset of the Core
-- allowlist (`CONFIG_WRITABLE_SETTINGS`). Twelve keys plus one `sources` call
-- per refresh stay inside the host's 16-calls-per-second generation budget,
-- so a full refresh never trips the rate window on its own.

local text = require("dashboard.text")

local M = {}

M.KIND_TEXT = "text"
M.KIND_INTEGER = "integer"
M.KIND_NUMBER = "number"
M.KIND_BOOL = "bool"
M.KIND_ABSENT = "absent"

M.CODE_DENIED = "E_CAPABILITY_DENIED"
M.CODE_STALE = "E_CONFIG_STALE"
M.CODE_APPROVAL_REQUIRED = "E_CONFIG_APPROVAL_REQUIRED"
M.CODE_APPROVAL_MISMATCH = "E_CONFIG_APPROVAL_MISMATCH"
M.CODE_KEY = "E_CONFIG_KEY"
M.CODE_VALUE = "E_CONFIG_VALUE"
M.CODE_UNSAFE = "E_CONFIG_UNSAFE"
M.CODE_IO = "E_CONFIG_IO"
M.CODE_INVALID = "E_CONFIG_INVALID"
M.CODE_UNAVAILABLE = "E_CONFIG_UNAVAILABLE"
M.CODE_LIMIT = "E_DEF_LIMIT"
M.CODE_MALFORMED = "E_CONFIG_MALFORMED"
M.CODE_PROFILE_CONFLICT = "E_PROFILE_CONFLICT"
M.CODE_PROFILE_NOT_FOUND = "E_PROFILE_NOT_FOUND"

-- Display bounds. The host already bounds every payload; these are defense in
-- depth for a malformed or hostile reply.
M.MAX_KEY_BYTES = 64
M.MAX_SOURCE_BYTES = 64
M.MAX_VALUE_BYTES = 256
M.MAX_ID_BYTES = 128
M.MAX_NAME_BYTES = 64
M.MAX_RENDERED_BYTES = 4096
M.MAX_DIFF_LINES = 32
M.MAX_KEYS = 64
M.MAX_ROWS = 64

-- Editable subset, in display order. Every key is in Core's allowlist and is
-- presentation-only: none of them changes what the next launch executes.
M.KEYS = {
  { key = "appearance.theme", kind = M.KIND_TEXT },
  { key = "appearance.animations.enabled", kind = M.KIND_BOOL },
  { key = "font.family", kind = M.KIND_TEXT },
  { key = "font.size", kind = M.KIND_NUMBER },
  { key = "window.opacity", kind = M.KIND_NUMBER },
  { key = "window.padding", kind = M.KIND_INTEGER },
  { key = "terminal.scrollback", kind = M.KIND_INTEGER },
  { key = "terminal.cursor_style", kind = M.KIND_TEXT },
  { key = "terminal.bell", kind = M.KIND_TEXT },
  { key = "selection.auto_copy", kind = M.KIND_BOOL },
  { key = "close_confirm", kind = M.KIND_TEXT },
  { key = "scrollbar.mode", kind = M.KIND_TEXT },
  { key = "decoration.gaps_in", kind = M.KIND_INTEGER },
  { key = "decoration.gaps_out", kind = M.KIND_INTEGER },
  { key = "decoration.radius", kind = M.KIND_INTEGER },
}

-- Closed enum values, spelled exactly as the strict loader accepts them.
-- Keys without an entry open a free-text input instead of cycling.
M.ENUMS = {
  ["terminal.cursor_style"] = {
    "default",
    "blinking_block",
    "steady_block",
    "blinking_underline",
    "steady_underline",
    "blinking_bar",
    "steady_bar",
  },
  ["terminal.bell"] = { "off", "visual", "audible", "both" },
  ["close_confirm"] = { "always", "when_busy", "never" },
  ["scrollbar.mode"] = { "hidden", "always", "auto" },
}

local KIND_BY_KEY = {}
for index = 1, #M.KEYS do
  KIND_BY_KEY[M.KEYS[index].key] = M.KEYS[index].kind
end

-- Local kind for one editable key, or nil when the key is not in the subset.
function M.kind_of(key)
  return KIND_BY_KEY[key]
end

function M.is_editable(key)
  return KIND_BY_KEY[key] ~= nil
end

-- Typed failure. The message is bounded, single-line, and path-redacted: the
-- host's own diagnostic may name a path that never reaches the panel.
function M.error(code, message)
  return {
    code = text.field(code or M.CODE_MALFORMED, 64),
    message = text.field(message or "config.manage call failed", 96),
    denied = (code == M.CODE_DENIED),
  }
end

function M.error_from(value, fallback)
  if type(value) == "table" and type(value.code) == "string" and value.code ~= "" then
    return M.error(value.code, value.message)
  end
  return M.error(fallback or M.CODE_MALFORMED, "config.manage call failed")
end

-- Whether one refusal means the write surface is unusable for this
-- generation: the grant is missing, the backend is unwired (`--safe`), or the
-- user layer is not a safe target. The panel keeps its read-only rendering
-- for all three.
function M.is_blocked(err)
  if err == nil then
    return false
  end
  return err.code == M.CODE_DENIED or err.code == M.CODE_UNAVAILABLE or err.code == M.CODE_UNSAFE
end

-- One bounded explanation for a blocked surface.
function M.blocked_notice(err)
  if err ~= nil and err.code == M.CODE_DENIED then
    return "config.manage denied: showing read-only data"
  end
  if err ~= nil and err.code == M.CODE_UNSAFE then
    return "config.manage refused the user layer: read-only"
  end
  return "config.manage unavailable: showing read-only data"
end

local function table_at(host, name)
  if type(host) ~= "table" then
    return nil
  end
  local surface = host[name]
  if type(surface) ~= "table" then
    return nil
  end
  return surface
end

local function function_at(host, name, method)
  local surface = table_at(host, name)
  if surface == nil then
    return nil
  end
  local fn = surface[method]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

-- Resolve a profile verb from `bitty.profiles` or its read-only proxy alias
-- `bitty.config.profiles` (bitty#3047).
local function profile_fn(host, method)
  local fn = function_at(host, "profiles", method)
  if fn ~= nil then
    return fn
  end
  local cfg = table_at(host, "config")
  if cfg == nil then
    return nil
  end
  return function_at(cfg, "profiles", method)
end

-- Whether the host exposes the bounded read query at all. An older host has
-- no `config` namespace, so the panel keeps its read-only rendering.
function M.readable(host)
  return function_at(host, "config", "sources") ~= nil and function_at(host, "config", "get") ~= nil
end

function M.writable(host)
  return M.readable(host)
    and function_at(host, "config", "preview") ~= nil
    and function_at(host, "config", "set") ~= nil
end

function M.toggleable(host)
  return M.writable(host)
    and function_at(host, "plugins", "list") ~= nil
    and function_at(host, "config", "preview_enabled") ~= nil
    and function_at(host, "config", "set_enabled") ~= nil
end

function M.switchable(host)
  return M.writable(host)
    and profile_fn(host, "list") ~= nil
    and profile_fn(host, "preview_use") ~= nil
    and profile_fn(host, "use") ~= nil
end

function M.profile_lifecycle(host)
  return M.switchable(host)
    and profile_fn(host, "preview_create") ~= nil
    and profile_fn(host, "create") ~= nil
    and profile_fn(host, "preview_clone") ~= nil
    and profile_fn(host, "clone") ~= nil
    and profile_fn(host, "preview_rename") ~= nil
    and profile_fn(host, "rename") ~= nil
    and profile_fn(host, "preview_delete") ~= nil
    and profile_fn(host, "delete") ~= nil
end

local function invoke(fn, ...)
  local ok, value = pcall(fn, ...)
  if not ok then
    return nil, M.error_from(value)
  end
  if type(value) ~= "table" then
    return nil, M.error(M.CODE_MALFORMED, "config.manage returned no table")
  end
  return value, nil
end

local function boolean(value)
  return value == true
end

local function finite(value)
  if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return nil
end

-- One typed scalar from the host. Tables, functions, and non-finite numbers
-- are dropped: the panel only renders values it can display.
local function scalar(value, kind)
  if kind == M.KIND_TEXT or type(value) == "string" then
    if type(value) == "string" then
      return text.field(value, M.MAX_VALUE_BYTES)
    end
    return nil
  end
  if kind == M.KIND_BOOL or type(value) == "boolean" then
    if type(value) == "boolean" then
      return value
    end
    return nil
  end
  return finite(value)
end

local function hex_digest(value)
  if type(value) ~= "string" or #value ~= 64 then
    return nil
  end
  if string.match(value, "^[0-9a-f]+$") == nil then
    return nil
  end
  return value
end

-- Split one rendered diff into bounded single-line rows. The host renders
-- `-old`/`+new` lines; each line is sanitized and truncated for display.
function M.diff_lines(rendered)
  local lines = {}
  if type(rendered) ~= "string" or rendered == "" then
    return lines
  end
  local bounded = text.slice_bytes(rendered, M.MAX_RENDERED_BYTES)
  local start = 1
  while #lines < M.MAX_DIFF_LINES and start <= #bounded do
    local newline = string.find(bounded, "\n", start, true)
    local line
    if newline == nil then
      line = string.sub(bounded, start)
    else
      line = string.sub(bounded, start, newline - 1)
    end
    lines[#lines + 1] = text.field(line, text.MAX_FIELD_BYTES)
    if newline == nil then
      break
    end
    start = newline + 1
  end
  return lines
end

local function key_list(raw)
  local keys = {}
  if type(raw) ~= "table" then
    return keys
  end
  for index = 1, #raw do
    if #keys >= M.MAX_KEYS then
      break
    end
    local key = text.field(raw[index], M.MAX_KEY_BYTES)
    if key ~= "" then
      keys[#keys + 1] = key
    end
  end
  return keys
end

-- `bitty.config.sources()`: the host's allowlist plus logical attribution.
function M.sources(host)
  local fn = function_at(host, "config", "sources")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.sources surface")
  end
  local raw, err = invoke(fn)
  if raw == nil then
    return nil, err
  end
  local rows = {}
  local truncated = raw.truncated == true
  local source_rows = type(raw.rows) == "table" and raw.rows or {}
  for index = 1, #source_rows do
    if #rows >= M.MAX_ROWS then
      truncated = true
      break
    end
    local item = source_rows[index]
    if type(item) == "table" then
      local key = text.field(item.key, M.MAX_KEY_BYTES)
      if key ~= "" then
        rows[#rows + 1] = {
          key = key,
          source = text.field(item.source, M.MAX_SOURCE_BYTES),
        }
      end
    end
  end
  return { rows = rows, truncated = truncated }
end

-- `bitty.config.get(key)`: one typed value plus its logical source.
function M.get(host, key)
  local fn = function_at(host, "config", "get")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.get surface")
  end
  local raw, err = invoke(fn, key)
  if raw == nil then
    return nil, err
  end
  local found = boolean(raw.found)
  local kind = text.field(raw.kind, 16)
  if kind == "" then
    kind = found and M.KIND_TEXT or M.KIND_ABSENT
  end
  local value = nil
  if found then
    value = scalar(raw.value, kind)
  end
  return {
    key = text.field(raw.key, M.MAX_KEY_BYTES),
    found = found and value ~= nil,
    value = value,
    kind = kind,
    source = text.field(raw.source, M.MAX_SOURCE_BYTES),
    redacted = boolean(raw.redacted),
  }
end

local function preview_result(raw, fallback)
  local digest = hex_digest(raw.digest)
  if digest == nil then
    return nil, M.error(M.CODE_MALFORMED, fallback .. " returned no approval digest")
  end
  local raw_keys = type(raw.keys) == "table" and raw.keys or raw.changed_keys
  return {
    digest = digest,
    lines = M.diff_lines(raw.rendered),
    keys = key_list(raw_keys),
    changed = raw.changed == nil and true or boolean(raw.changed),
    replaces_existing = boolean(raw.replaces_existing),
    selector_updated = boolean(raw.selector_updated),
    active = boolean(raw.active),
  }
end

-- `bitty.config.preview(key, value)`: render the exact candidate and issue
-- its one-shot approval digest. Nothing is written.
function M.preview(host, key, value)
  local fn = function_at(host, "config", "preview")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.preview surface")
  end
  local raw, err = invoke(fn, key, value)
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "config.preview")
end

-- `bitty.config.set(key, value, digest)`: apply one approved change.
function M.set(host, key, value, digest)
  local fn = function_at(host, "config", "set")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.set surface")
  end
  local raw, err = invoke(fn, key, value, digest)
  if raw == nil then
    return nil, err
  end
  return {
    applied = boolean(raw.applied),
    reload = text.field(raw.reload, 16),
  }
end

-- `bitty.plugins.list()`: bounded rows without grants or paths.
function M.plugins(host)
  local fn = function_at(host, "plugins", "list")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no plugins.list surface")
  end
  local raw, err = invoke(fn)
  if raw == nil then
    return nil, err
  end
  local rows = {}
  local truncated = raw.truncated == true
  local source_rows = type(raw.rows) == "table" and raw.rows or {}
  for index = 1, #source_rows do
    if #rows >= M.MAX_ROWS then
      truncated = true
      break
    end
    local item = source_rows[index]
    if type(item) == "table" then
      local id = text.field(item.id, M.MAX_ID_BYTES)
      if id ~= "" then
        rows[#rows + 1] = {
          id = id,
          enabled = boolean(item.enabled),
          managed = boolean(item.managed),
          source = text.field(item.source, M.MAX_SOURCE_BYTES),
          version = text.field(item.version, 32),
        }
      end
    end
  end
  return { rows = rows, truncated = truncated }
end

-- `bitty.config.preview_enabled(id, enabled)`.
function M.preview_enabled(host, id, enabled)
  local fn = function_at(host, "config", "preview_enabled")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.preview_enabled surface")
  end
  local raw, err = invoke(fn, id, enabled)
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "config.preview_enabled")
end

-- `bitty.config.set_enabled(id, enabled, digest)`.
function M.set_enabled(host, id, enabled, digest)
  local fn = function_at(host, "config", "set_enabled")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.set_enabled surface")
  end
  local raw, err = invoke(fn, id, enabled, digest)
  if raw == nil then
    return nil, err
  end
  return {
    changed = boolean(raw.changed),
    reload = text.field(raw.reload, 16),
  }
end

-- `bitty.profiles.list()`: validated names plus the active marker.
function M.profiles(host)
  local fn = profile_fn(host, "list")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.list surface")
  end
  local raw, err = invoke(fn)
  if raw == nil then
    return nil, err
  end
  local rows = {}
  local truncated = raw.truncated == true
  local source_rows = type(raw.rows) == "table" and raw.rows
    or (type(raw.profiles) == "table" and raw.profiles or {})
  for index = 1, #source_rows do
    if #rows >= M.MAX_ROWS then
      truncated = true
      break
    end
    local item = source_rows[index]
    if type(item) == "table" then
      local name = text.field(item.name, M.MAX_NAME_BYTES)
      if name ~= "" then
        rows[#rows + 1] = { name = name, active = boolean(item.active) }
      end
    end
  end
  return {
    rows = rows,
    active = text.field(raw.active, M.MAX_NAME_BYTES),
    truncated = truncated,
    lifecycle = M.profile_lifecycle(host),
  }
end

-- `bitty.profiles.preview_use(name)`.
function M.preview_use(host, name)
  local fn = profile_fn(host, "preview_use")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.preview_use surface")
  end
  local raw, err = invoke(fn, name)
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "profiles.preview_use")
end

-- `bitty.profiles.use(name, digest)`.
function M.use(host, name, digest)
  local fn = profile_fn(host, "use")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.use surface")
  end
  local raw, err = invoke(fn, name, digest)
  if raw == nil then
    return nil, err
  end
  return {
    active = text.field(raw.active, M.MAX_NAME_BYTES),
    changed = boolean(raw.changed),
    reload = text.field(raw.reload, 16),
    pending_restart = boolean(raw.pending_restart),
  }
end

local function split_opts_and_digest(opts_or_digest, digest)
  if digest == nil and type(opts_or_digest) == "string" then
    return nil, opts_or_digest
  end
  if type(opts_or_digest) == "table" and next(opts_or_digest) ~= nil then
    return opts_or_digest, digest
  end
  return nil, digest
end

-- `bitty.profiles.preview_create(name, opts?)`.
function M.preview_create(host, name, opts)
  local fn = profile_fn(host, "preview_create")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.preview_create surface")
  end
  local raw, err
  if type(opts) == "table" and next(opts) ~= nil then
    raw, err = invoke(fn, name, opts)
  else
    raw, err = invoke(fn, name)
  end
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "profiles.preview_create")
end

-- `bitty.profiles.create(name, opts_or_digest, digest?)`.
function M.create(host, name, opts_or_digest, digest)
  local fn = profile_fn(host, "create")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.create surface")
  end
  local opts, token = split_opts_and_digest(opts_or_digest, digest)
  local raw, err
  if opts ~= nil then
    raw, err = invoke(fn, name, opts, token)
  else
    raw, err = invoke(fn, name, token)
  end
  if raw == nil then
    return nil, err
  end
  local extends = type(raw.extends) == "string" and text.field(raw.extends, M.MAX_NAME_BYTES) or nil
  local preset = type(raw.preset) == "string" and text.field(raw.preset, M.MAX_NAME_BYTES) or nil
  return {
    name = text.field(raw.name ~= nil and raw.name or name, M.MAX_NAME_BYTES),
    created = raw.created == nil and true or boolean(raw.created),
    changed = raw.changed == nil and true or boolean(raw.changed),
    replaced = boolean(raw.replaced),
    backed_up = boolean(raw.backed_up),
    extends = extends ~= "" and extends or nil,
    preset = preset ~= "" and preset or nil,
    reload = text.field(raw.reload, 16),
  }
end

-- `bitty.profiles.preview_clone(src, dst, opts?)`.
function M.preview_clone(host, src, dst, opts)
  local fn = profile_fn(host, "preview_clone")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.preview_clone surface")
  end
  local raw, err
  if type(opts) == "table" and next(opts) ~= nil then
    raw, err = invoke(fn, src, dst, opts)
  else
    raw, err = invoke(fn, src, dst)
  end
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "profiles.preview_clone")
end

-- `bitty.profiles.clone(src, dst, opts_or_digest, digest?)`.
function M.clone(host, src, dst, opts_or_digest, digest)
  local fn = profile_fn(host, "clone")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.clone surface")
  end
  local opts, token = split_opts_and_digest(opts_or_digest, digest)
  local raw, err
  if opts ~= nil then
    raw, err = invoke(fn, src, dst, opts, token)
  else
    raw, err = invoke(fn, src, dst, token)
  end
  if raw == nil then
    return nil, err
  end
  local target_name = raw.name ~= nil and raw.name or (raw.target ~= nil and raw.target or dst)
  local extends = type(raw.extends) == "string" and text.field(raw.extends, M.MAX_NAME_BYTES) or nil
  return {
    source = text.field(raw.source ~= nil and raw.source or src, M.MAX_NAME_BYTES),
    name = text.field(target_name, M.MAX_NAME_BYTES),
    target = text.field(raw.target ~= nil and raw.target or target_name, M.MAX_NAME_BYTES),
    cloned = raw.cloned == nil and true or boolean(raw.cloned),
    changed = raw.changed == nil and true or boolean(raw.changed),
    replaced = boolean(raw.replaced),
    backed_up = boolean(raw.backed_up),
    extends = extends ~= "" and extends or nil,
    reload = text.field(raw.reload, 16),
  }
end

-- `bitty.profiles.preview_rename(old_name, new_name, opts?)`.
function M.preview_rename(host, old_name, new_name, opts)
  local fn = profile_fn(host, "preview_rename")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.preview_rename surface")
  end
  local raw, err
  if type(opts) == "table" and next(opts) ~= nil then
    raw, err = invoke(fn, old_name, new_name, opts)
  else
    raw, err = invoke(fn, old_name, new_name)
  end
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "profiles.preview_rename")
end

-- `bitty.profiles.rename(old_name, new_name, opts_or_digest, digest?)`.
function M.rename(host, old_name, new_name, opts_or_digest, digest)
  local fn = profile_fn(host, "rename")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.rename surface")
  end
  local opts, token = split_opts_and_digest(opts_or_digest, digest)
  local raw, err
  if opts ~= nil then
    raw, err = invoke(fn, old_name, new_name, opts, token)
  else
    raw, err = invoke(fn, old_name, new_name, token)
  end
  if raw == nil then
    return nil, err
  end
  local resolved_new = raw.new_name ~= nil and raw.new_name or (raw.name ~= nil and raw.name or new_name)
  return {
    old_name = text.field(raw.old_name ~= nil and raw.old_name or old_name, M.MAX_NAME_BYTES),
    new_name = text.field(resolved_new, M.MAX_NAME_BYTES),
    name = text.field(raw.name ~= nil and raw.name or resolved_new, M.MAX_NAME_BYTES),
    renamed = raw.renamed == nil and true or boolean(raw.renamed),
    changed = raw.changed == nil and true or boolean(raw.changed),
    replaced = boolean(raw.replaced),
    backed_up = boolean(raw.backed_up),
    selector_updated = boolean(raw.selector_updated),
    reload = text.field(raw.reload, 16),
  }
end

-- `bitty.profiles.preview_delete(name, opts?)`.
function M.preview_delete(host, name, opts)
  local fn = profile_fn(host, "preview_delete")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.preview_delete surface")
  end
  local raw, err
  if type(opts) == "table" and next(opts) ~= nil then
    raw, err = invoke(fn, name, opts)
  else
    raw, err = invoke(fn, name)
  end
  if raw == nil then
    return nil, err
  end
  return preview_result(raw, "profiles.preview_delete")
end

-- `bitty.profiles.delete(name, opts_or_digest, digest?)`.
function M.delete(host, name, opts_or_digest, digest)
  local fn = profile_fn(host, "delete")
  if fn == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no profiles.delete surface")
  end
  local opts, token = split_opts_and_digest(opts_or_digest, digest)
  local raw, err
  if opts ~= nil then
    raw, err = invoke(fn, name, opts, token)
  else
    raw, err = invoke(fn, name, token)
  end
  if raw == nil then
    return nil, err
  end
  return {
    name = text.field(raw.name ~= nil and raw.name or name, M.MAX_NAME_BYTES),
    deleted = raw.deleted == nil and true or boolean(raw.deleted),
    changed = raw.changed == nil and true or boolean(raw.changed),
    backed_up = boolean(raw.backed_up),
    was_active = boolean(raw.was_active),
    reload = text.field(raw.reload, 16),
  }
end

local function previous_rows(previous)
  local index = {}
  if previous == nil or type(previous.settings) ~= "table" then
    return index
  end
  for row_index = 1, #previous.settings.rows do
    local item = previous.settings.rows[row_index]
    index[item.key] = item
  end
  return index
end

-- Read the managed sections in one bounded pass.
--
-- Returns `managed, error`. `managed` is non-nil when at least the editable
-- setting list is readable; a list section is fetched only when `sections`
-- asks for it, so opening the panel costs one `sources` call plus one `get`
-- per curated key. A failed list section is left `nil` so that tab keeps its
-- `runtime.inspect()` rendering. A `E_CAPABILITY_DENIED` reply is returned as
-- the error and the caller degrades to the read-only panel.
function M.collect(host, previous, sections)
  sections = sections or {}
  if not M.readable(host) then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no config.manage surface")
  end
  local sources, err = M.sources(host)
  if sources == nil then
    return nil, err
  end
  local attribution = {}
  for index = 1, #sources.rows do
    attribution[sources.rows[index].key] = sources.rows[index].source
  end
  local known = previous_rows(previous)

  -- `sources()` carries no value: the panel reads one selected row at a time
  -- with `config.get`, and reuses the cached value while the row is visible.
  local settings = { rows = {}, truncated = sources.truncated }
  for index = 1, #M.KEYS do
    local meta = M.KEYS[index]
    local source = attribution[meta.key]
    if source ~= nil then
      local cached = known[meta.key]
      settings.rows[#settings.rows + 1] = {
        key = meta.key,
        kind = (cached and cached.kind) or meta.kind,
        source = source,
        value = cached and cached.value or nil,
        found = cached ~= nil and cached.found == true,
        redacted = cached ~= nil and cached.redacted == true,
        loaded = cached ~= nil and cached.loaded == true,
      }
    end
  end

  local managed = { settings = settings }

  if sections.plugins == true and M.toggleable(host) then
    local plugins, plugin_err = M.plugins(host)
    if plugins ~= nil then
      managed.plugins = plugins
    elseif M.is_blocked(plugin_err) then
      return nil, plugin_err
    end
  end

  if sections.profiles == true and M.switchable(host) then
    local profiles, profile_err = M.profiles(host)
    if profiles ~= nil then
      managed.profiles = profiles
    elseif M.is_blocked(profile_err) then
      return nil, profile_err
    end
  end

  return managed, nil
end

return M
