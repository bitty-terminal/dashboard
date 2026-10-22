-- Read-only adapter over `bitty.runtime.inspect()` (bitty#2396, merged in
-- bitty#2410).
--
-- The host returns one table with five sections. Every section is either a
-- typed payload or `{ unavailable = <reason> }`; a failed source is never
-- rendered as an empty list, and this module preserves that distinction all
-- the way to the scene.
--
-- Normalization is deny-by-default: only the documented fields are copied,
-- every string is bounded and path-redacted by `dashboard.text`, and a
-- malformed row is dropped rather than trusted. No call in this module opens
-- a file, spawns a process, or touches the network.

local text = require("dashboard.text")

local M = {}

-- Per-section row ceilings, mirroring the host bounds
-- (`RUNTIME_INSPECT_MAX_*_ROWS`) as defense in depth for a malformed payload.
M.ROW_LIMITS = {
  plugins = 128,
  settings = 256,
  extensions = 64,
  profiles = 64,
}

M.KIND_ROWS = "rows"
M.KIND_UNAVAILABLE = "unavailable"

M.CODE_UNAVAILABLE = "E_INSPECT_UNAVAILABLE"
M.CODE_MALFORMED = "E_INSPECT_MALFORMED"

-- Typed failure for the whole snapshot. The message is a fixed, host-free
-- string: a Lua error table from the host may carry arbitrary detail, and the
-- dashboard never renders raw host text outside `field()`.
function M.error(code, message)
  return {
    code = text.field(code or M.CODE_MALFORMED, 64),
    message = text.field(message or "runtime inspect failed", 96),
  }
end

-- Normalize a thrown host value into a typed error without leaking it.
function M.error_from(value)
  if type(value) == "table" and type(value.code) == "string" and value.code ~= "" then
    return M.error(value.code, value.message)
  end
  return M.error(M.CODE_MALFORMED, "runtime.inspect failed")
end

-- One bounded, path-redacted string field.
local function field(value)
  return text.field(value, text.MAX_FIELD_BYTES)
end

local function boolean(value)
  return value == true
end

local function number(value)
  if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return nil
end

-- Read the snapshot through the host surface. Returns `snapshot, error`.
-- `host` defaults to the `bitty` global so tests can inject a mock.
function M.read(host)
  host = host or bitty
  if type(host) ~= "table" then
    return nil, M.error(M.CODE_UNAVAILABLE, "no plugin host is available")
  end
  if host.runtime == nil then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no runtime.inspect surface")
  end
  if type(host.runtime.inspect) ~= "function" then
    return nil, M.error(M.CODE_UNAVAILABLE, "host has no runtime.inspect surface")
  end
  local ok, value = pcall(host.runtime.inspect)
  if not ok then
    return nil, M.error_from(value)
  end
  if type(value) ~= "table" then
    return nil, M.error(M.CODE_MALFORMED, "runtime.inspect returned no snapshot")
  end
  return value, nil
end

-- Whether one raw section carries an explicit failure marker.
local function unavailable(raw, fallback)
  if type(raw) ~= "table" then
    return { kind = M.KIND_UNAVAILABLE, reason = fallback }
  end
  if raw.unavailable ~= nil then
    return { kind = M.KIND_UNAVAILABLE, reason = field(raw.unavailable) }
  end
  return nil
end

-- Bounded row container shared by the four list sections.
local function rows_container(raw, limit, normalize_row)
  local failure = unavailable(raw, "section unavailable")
  if failure ~= nil then
    return failure
  end
  if type(raw.rows) ~= "table" then
    return { kind = M.KIND_UNAVAILABLE, reason = "section payload malformed" }
  end
  local rows = {}
  local truncated = raw.truncated == true
  local count = 0
  for index = 1, #raw.rows do
    if count >= limit then
      truncated = true
      break
    end
    local row = normalize_row(raw.rows[index])
    if row ~= nil then
      count = count + 1
      rows[count] = row
    end
  end
  return { kind = M.KIND_ROWS, rows = rows, truncated = truncated }
end

local function normalize_plugin_row(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local id = field(raw.id)
  if id == "" then
    return nil
  end
  return {
    id = id,
    name = field(raw.name),
    version = field(raw.version),
    source = field(raw.source),
    enabled = boolean(raw.enabled),
    recorded = boolean(raw.recorded),
  }
end

local function normalize_extension_row(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local name = field(raw.name)
  if name == "" then
    return nil
  end
  return {
    name = name,
    version = field(raw.version),
    tier = field(raw.tier),
    abi_compatible = boolean(raw.abi_compatible),
    digest = field(raw.sha256),
    executable = text.basename(raw.executable_path),
    activation = field(raw.activation),
    trust = field(raw.trust),
  }
end

local function normalize_setting_row(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local key = field(raw.key)
  if key == "" then
    return nil
  end
  return {
    plugin_id = field(raw.plugin_id),
    key = key,
    current = field(raw.current),
    default = field(raw.default),
    source = field(raw.source),
  }
end

local function normalize_profile_row(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local name = field(raw.name)
  if name == "" then
    return nil
  end
  return {
    name = name,
    active = boolean(raw.active),
  }
end

-- Diagnostics: a fixed field set. Paths are reduced to presence plus basename;
-- the dashboard never renders a host directory layout.
function M.diagnostics(raw)
  local failure = unavailable(raw, "diagnostics unavailable")
  if failure ~= nil then
    return failure
  end
  local decoration = type(raw.decoration) == "table" and raw.decoration or {}
  local paths = {}
  local function path_entry(name)
    local label = text.basename(raw[name])
    paths[name] = {
      present = label ~= nil,
      label = label or "",
    }
  end
  path_entry("config_file")
  path_entry("config_dir")
  path_entry("plugin_ledger")
  path_entry("plugin_store")
  path_entry("extension_user_root")
  path_entry("extension_system_root")
  path_entry("extension_state_root")
  return {
    kind = M.KIND_ROWS,
    value = {
      app_version = field(raw.app_version),
      profile = raw.profile == nil and nil or field(raw.profile),
      profile_source = field(raw.profile_source),
      theme = field(raw.theme),
      theme_source = field(raw.theme_source),
      font_family = field(raw.font_family),
      font_size = number(raw.font_size),
      decoration = {
        gaps_in = number(decoration.gaps_in),
        gaps_out = number(decoration.gaps_out),
        border = number(decoration.border),
        radius = number(decoration.radius),
        content_inset = number(decoration.content_inset),
      },
      paths = paths,
    },
  }
end

-- Normalize one full snapshot. Unknown keys are ignored; every section keeps
-- its typed failure marker.
function M.normalize(snapshot)
  if type(snapshot) ~= "table" then
    local failure = { kind = M.KIND_UNAVAILABLE, reason = "no snapshot" }
    return {
      diagnostics = failure,
      plugins = failure,
      extensions = failure,
      settings = failure,
      profiles = failure,
    }
  end
  return {
    diagnostics = M.diagnostics(snapshot.diagnostics),
    plugins = rows_container(snapshot.plugins, M.ROW_LIMITS.plugins, normalize_plugin_row),
    settings = rows_container(snapshot.settings, M.ROW_LIMITS.settings, normalize_setting_row),
    extensions = rows_container(snapshot.extensions, M.ROW_LIMITS.extensions, normalize_extension_row),
    profiles = rows_container(snapshot.profiles, M.ROW_LIMITS.profiles, normalize_profile_row),
  }
end

-- Convenience: read and normalize in one guarded step.
function M.collect(host)
  local snapshot, err = M.read(host)
  if snapshot == nil then
    return nil, err
  end
  return M.normalize(snapshot), nil
end

return M
