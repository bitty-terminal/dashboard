-- In-process `bitty` host stub for the Dashboard behavior tests.
--
-- Models only the accepted surface the plugin uses: the lazy command and event
-- registration gates, `bitty.runtime.inspect()`, the W-01 focusable-overlay
-- session (`bitty.ui.overlay.*`), generation-owned one-shot timers, and — when
-- `options.config` is set — the typed `config.manage` read/write surface
-- (bitty#2393). Every capability is deny-by-default and every payload is
-- recorded so specs can assert the exact host call shape.
--
-- It performs no I/O, spawns nothing, and never touches the network or the
-- filesystem. Events, snapshots, and captured input are staged explicitly.

local MockHost = {}
MockHost.__index = MockHost

local PLUGIN_ID = "bitty-terminal.dashboard"

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
end

-- Staged effective configuration for the editable subset.
local DEFAULT_SETTINGS = {
  ["appearance.theme"] = { value = "default", kind = "text", source = "default" },
  ["appearance.animations.enabled"] = { value = true, kind = "bool", source = "default" },
  ["font.family"] = { value = "JetBrains Mono", kind = "text", source = "user" },
  ["font.size"] = { value = 12.5, kind = "number", source = "user" },
  ["window.opacity"] = { value = 0.95, kind = "number", source = "default" },
  ["window.padding"] = { value = 8, kind = "integer", source = "default" },
  ["terminal.scrollback"] = { value = 10000, kind = "integer", source = "default" },
  ["terminal.cursor_style"] = { value = "steady_bar", kind = "text", source = "default" },
  ["terminal.bell"] = { value = "visual", kind = "text", source = "default" },
  ["selection.auto_copy"] = { value = false, kind = "bool", source = "default" },
  ["close_confirm"] = { value = "when_busy", kind = "text", source = "default" },
  ["scrollbar.mode"] = { value = "auto", kind = "text", source = "default" },
}

local DEFAULT_PLUGINS = {
  { id = "bitty-terminal.bar", enabled = true, managed = true, source = "bundled", version = "0.0.1" },
  { id = "bitty-terminal.dashboard", enabled = true, managed = true, source = "registry", version = "0.2.0" },
  { id = "bitty-terminal.palette", enabled = false, managed = false, source = "git", version = "0.1.0" },
}

local DEFAULT_PROFILES = {
  { name = "default", active = false },
  { name = "work", active = true },
}

local function copy_settings(source)
  local out = {}
  for key, entry in pairs(source or {}) do
    out[key] = { value = entry.value, kind = entry.kind, source = entry.source }
  end
  return out
end

local function copy_rows(rows)
  local out = {}
  for index = 1, #(rows or {}) do
    local row = {}
    for key, value in pairs(rows[index]) do
      row[key] = value
    end
    out[#out + 1] = row
  end
  return out
end

local function literal(value, kind)
  if kind == "text" then
    return '"' .. tostring(value) .. '"'
  end
  if kind == "bool" then
    return value == true and "true" or "false"
  end
  return tostring(value)
end

local function check_value(kind, value)
  if kind == "text" then
    return type(value) == "string"
  end
  if kind == "bool" then
    return type(value) == "boolean"
  end
  return type(value) == "number"
end

local function is_component(value)
  if type(value) ~= "table" then
    return false
  end
  local kind = value.kind
  if kind == "Text" then
    return type(value.text) == "string"
  end
  if kind == "Row" or kind == "Column" or kind == "List" then
    if type(value.children) ~= "table" then
      return false
    end
    for index = 1, #value.children do
      if not is_component(value.children[index]) then
        return false
      end
    end
    return true
  end
  return false
end

function MockHost.new(options)
  options = options or {}
  local self = setmetatable({}, MockHost)
  self.plugin_id = options.plugin_id or PLUGIN_ID
  self.grants = {}
  local grants = options.grants
  if grants == nil then
    grants = { "runtime.inspect", "ui.overlay.focus" }
    if options.config then
      grants[#grants + 1] = "config.manage"
    end
  end
  for _, name in ipairs(grants) do
    self.grants[name] = true
  end
  self.declared_commands = {}
  for _, name in ipairs(options.commands or { self.plugin_id .. ":toggle_dashboard" }) do
    self.declared_commands[name] = true
  end
  self.declared_events = {}
  for _, name in ipairs(options.events or { "overlay.input.available", "focus.changed", "overlay.released" }) do
    self.declared_events[name] = true
  end
  self.snapshot = options.snapshot
  self.inspect_error = options.inspect_error
  self.poll_error = options.poll_error
  self.update_error = options.update_error
  self.inspect_calls = 0
  self.safe_mode = options.safe_mode == true
  self.commands = {}
  self.subscriptions = {}
  self.mounts = {}
  self.session = nil
  self.next_handle = 0
  self.polls = 0
  self.releases = {}
  self.timers = {}
  self.next_timer = 0
  self.clock = 0

  -- `config.manage` state. The surface is absent unless the spec opts in, so
  -- the default mock models a host that predates the API.
  self.config_enabled = options.config == true
  self.config_values = copy_settings(DEFAULT_SETTINGS)
  for key, entry in pairs(options.config_values or {}) do
    self.config_values[key] = {
      value = entry.value,
      kind = entry.kind or (DEFAULT_SETTINGS[key] and DEFAULT_SETTINGS[key].kind) or "text",
      source = entry.source or "default",
    }
  end
  self.plugin_rows = copy_rows(options.plugin_rows or DEFAULT_PLUGINS)
  self.profile_rows = copy_rows(options.profile_rows or DEFAULT_PROFILES)
  self.config_calls = {}
  self.approvals = {}
  self.issued_log = {}
  self.next_digest = 0
  self.stale_once = options.stale_once == true
  self.config_error = options.config_error
  self.pending_restart = options.pending_restart == true
  self.bitty = self:build()
  return self
end

function MockHost:grant(name)
  self.grants[name] = true
end

function MockHost:revoke(name)
  self.grants[name] = nil
end

function MockHost:has(capability)
  return self.grants[capability] == true
end

function MockHost:require(capability)
  if not self:has(capability) then
    fail("runtime", "E_CAPABILITY_DENIED", "requires capability " .. capability)
  end
end

-- Raise the staged backend failure, if any. The call is recorded first so a
-- spec can still assert what the plugin attempted.
function MockHost:config_fail()
  if self.config_error ~= nil then
    error(self.config_error, 0)
  end
end

-- Record one `config.manage` call and its arguments.
function MockHost:record(method, ...)
  self.config_calls[#self.config_calls + 1] = { method = method, args = { ... } }
end

-- Every recorded call name, in order.
function MockHost:call_names()
  local names = {}
  for index = 1, #self.config_calls do
    names[#names + 1] = self.config_calls[index].method
  end
  return names
end

function MockHost:count_calls(method)
  local count = 0
  for index = 1, #self.config_calls do
    if self.config_calls[index].method == method then
      count = count + 1
    end
  end
  return count
end

function MockHost:last_call(method)
  for index = #self.config_calls, 1, -1 do
    if self.config_calls[index].method == method then
      return self.config_calls[index]
    end
  end
  return nil
end

-- Issue one one-shot approval digest for an exact intent.
function MockHost:issue(target)
  self.next_digest = self.next_digest + 1
  local digest = string.format("%064x", self.next_digest)
  self.approvals[digest] = target
  self.issued_log[#self.issued_log + 1] = { digest = digest, target = target }
  return digest
end

function MockHost:last_issued()
  return self.issued_log[#self.issued_log]
end

-- Consume the approval for exactly this intent. A missing or mismatched
-- token fails closed like the host does.
function MockHost:consume(digest, target)
  local stored = self.approvals[digest]
  if stored == nil then
    fail("runtime", "E_CONFIG_APPROVAL_REQUIRED", "no fresh preview token for this change")
  end
  if stored.kind ~= target.kind or stored.key ~= target.key or stored.value ~= target.value then
    fail("runtime", "E_CONFIG_APPROVAL_MISMATCH", "approval does not match this exact change")
  end
  self.approvals[digest] = nil
end

function MockHost:find_plugin(id)
  for index = 1, #self.plugin_rows do
    if self.plugin_rows[index].id == id then
      return self.plugin_rows[index]
    end
  end
  return nil
end

function MockHost:active_profile()
  for index = 1, #self.profile_rows do
    if self.profile_rows[index].active then
      return self.profile_rows[index].name
    end
  end
  return nil
end

function MockHost:build_config()
  local self = self
  local config = {}

  config.get = function(key)
    self:require("config.manage")
    self:record("config.get", key)
    self:config_fail()
    local entry = self.config_values[key]
    if entry == nil then
      fail("validation", "E_CONFIG_KEY", "config path is not in the config.manage allowlist")
    end
    return {
      key = key,
      found = true,
      value = entry.value,
      kind = entry.kind,
      source = entry.source,
      redacted = false,
    }
  end

  config.sources = function()
    self:require("config.manage")
    self:record("config.sources")
    self:config_fail()
    local keys = {}
    for key in pairs(self.config_values) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    local rows = {}
    for index = 1, #keys do
      rows[index] = { key = keys[index], source = self.config_values[keys[index]].source }
    end
    return { rows = rows, count = #rows, truncated = false }
  end

  config.preview = function(key, value)
    self:require("config.manage")
    self:record("config.preview", key, value)
    self:config_fail()
    local entry = self.config_values[key]
    if entry == nil then
      fail("validation", "E_CONFIG_KEY", "config path is not in the config.manage allowlist")
    end
    if not check_value(entry.kind, value) then
      fail("validation", "E_CONFIG_VALUE", "config value has the wrong type for this setting")
    end
    local digest = self:issue({ kind = "setting", key = key, value = value })
    return {
      digest = digest,
      rendered = "-" .. key .. " = " .. literal(entry.value, entry.kind)
        .. "\n+" .. key .. " = " .. literal(value, entry.kind),
      keys = { key },
    }
  end

  config.set = function(key, value, digest)
    self:require("config.manage")
    self:record("config.set", key, value, digest)
    self:config_fail()
    local entry = self.config_values[key]
    if entry == nil then
      fail("validation", "E_CONFIG_KEY", "config path is not in the config.manage allowlist")
    end
    self:consume(digest, { kind = "setting", key = key, value = value })
    if self.stale_once then
      self.stale_once = false
      fail("runtime", "E_CONFIG_STALE", "the configuration candidate changed since it was previewed")
    end
    entry.value = value
    entry.source = "user"
    return { applied = true, reload = "auto" }
  end

  config.preview_enabled = function(id, enabled)
    self:require("config.manage")
    self:record("config.preview_enabled", id, enabled)
    self:config_fail()
    local row = self:find_plugin(id)
    if row == nil then
      fail("validation", "E_CONFIG_INVALID", "plugin id is not in the managed ledger")
    end
    local digest = self:issue({ kind = "plugin", key = id, value = enabled })
    return {
      digest = digest,
      rendered = "-" .. id .. " = " .. literal(row.enabled, "bool")
        .. "\n+" .. id .. " = " .. literal(enabled, "bool"),
      keys = { id },
      changed = row.enabled ~= enabled,
    }
  end

  config.set_enabled = function(id, enabled, digest)
    self:require("config.manage")
    self:record("config.set_enabled", id, enabled, digest)
    self:config_fail()
    local row = self:find_plugin(id)
    if row == nil then
      fail("validation", "E_CONFIG_INVALID", "plugin id is not in the managed ledger")
    end
    self:consume(digest, { kind = "plugin", key = id, value = enabled })
    row.enabled = enabled
    return { changed = true, reload = "auto" }
  end

  return config
end

function MockHost:build_plugins()
  local self = self
  return {
    list = function()
      self:require("config.manage")
      self:record("plugins.list")
      self:config_fail()
      local rows = {}
      for index = 1, #self.plugin_rows do
        local row = self.plugin_rows[index]
        rows[index] = {
          id = row.id,
          enabled = row.enabled,
          managed = row.managed,
          source = row.source,
          version = row.version,
        }
      end
      return { rows = rows, count = #rows, truncated = false }
    end,
  }
end

function MockHost:build_profiles()
  local self = self
  local profiles = {}

  profiles.list = function()
    self:require("config.manage")
    self:record("profiles.list")
    self:config_fail()
    local rows = {}
    for index = 1, #self.profile_rows do
      rows[index] = { name = self.profile_rows[index].name, active = self.profile_rows[index].active }
    end
    return { rows = rows, active = self:active_profile(), count = #rows, truncated = false }
  end

  profiles.preview_use = function(name)
    self:require("config.manage")
    self:record("profiles.preview_use", name)
    self:config_fail()
    local found = false
    for index = 1, #self.profile_rows do
      if self.profile_rows[index].name == name then
        found = true
      end
    end
    if not found then
      fail("validation", "E_CONFIG_INVALID", "profile name is invalid")
    end
    local active = self:active_profile()
    local digest = self:issue({ kind = "profile", key = name, value = name })
    return {
      digest = digest,
      rendered = "-profile = " .. literal(active or "", "text")
        .. "\n+profile = " .. literal(name, "text"),
      keys = { "profile" },
      changed = active ~= name,
    }
  end

  profiles.use = function(name, digest)
    self:require("config.manage")
    self:record("profiles.use", name, digest)
    self:config_fail()
    self:consume(digest, { kind = "profile", key = name, value = name })
    for index = 1, #self.profile_rows do
      self.profile_rows[index].active = self.profile_rows[index].name == name
    end
    return {
      active = name,
      changed = true,
      reload = "auto",
      pending_restart = self.pending_restart,
    }
  end

  return profiles
end

function MockHost:build()
  local self = self
  local bitty = {
    api_version = "1.0.0",
    commands = {
      register = function(def)
        if type(def) ~= "table" or type(def.id) ~= "string" then
          fail("validation", "E_DEF_INVALID", "command definition is invalid")
        end
        if type(def.title) ~= "string" or type(def.run) ~= "function" then
          fail("validation", "E_DEF_INVALID", "command requires title and run")
        end
        local qualified = self.plugin_id .. ":" .. def.id
        if not self.declared_commands[qualified] then
          fail("validation", "E_COMMAND_UNDECLARED", "command is not reserved: " .. qualified)
        end
        if self.commands[qualified] ~= nil then
          fail("validation", "E_COMMAND_DUPLICATE", "duplicate command: " .. qualified)
        end
        self.commands[qualified] = def
        return true
      end,
    },
    events = {
      subscribe = function(kind, handler)
        if type(kind) ~= "string" or type(handler) ~= "function" then
          fail("validation", "E_DEF_INVALID", "event subscription is invalid")
        end
        if not self.declared_events[kind] then
          fail("validation", "E_EVENT_UNDECLARED", "event is not declared: " .. kind)
        end
        self.subscriptions[#self.subscriptions + 1] = { kind = kind, handler = handler }
        return true
      end,
    },
    runtime = {
      inspect = function()
        self:require("runtime.inspect")
        self.inspect_calls = self.inspect_calls + 1
        if self.inspect_error ~= nil then
          error(self.inspect_error, 0)
        end
        return self.snapshot
      end,
    },
    timers = {
      create = function(delay, callback)
        if type(delay) ~= "number" or type(callback) ~= "function" then
          fail("validation", "E_DEF_INVALID", "timer requires delay and callback")
        end
        if #self.timers >= 32 then
          fail("budget", "E_BUDGET_TIMER", "too many live timers")
        end
        self.next_timer = self.next_timer + 1
        local handle = self.next_timer
        self.timers[#self.timers + 1] = {
          handle = handle,
          deadline = self.clock + delay,
          callback = callback,
        }
        return handle
      end,
      cancel = function(handle)
        for index = 1, #self.timers do
          if self.timers[index].handle == handle then
            table.remove(self.timers, index)
            return true
          end
        end
        return false
      end,
    },
  }

  local overlay = {}
  overlay.acquire = function(spec)
    self:require("ui.overlay.focus")
    if self.safe_mode then
      fail("runtime", "E_UI_UNAVAILABLE", "focusable overlay is unavailable in safe mode")
    end
    if self.session ~= nil and self.session.active then
      fail("runtime", "E_UI_ALREADY_CAPTURED", "capture already held")
    end
    self.next_handle = self.next_handle + 1
    self.session = {
      handle = self.next_handle,
      active = true,
      spec = spec,
      component = nil,
      events = {},
      updates = 0,
      reason = nil,
    }
    return self.session.handle
  end
  overlay.update = function(handle, component)
    if self.update_error ~= nil then
      error(self.update_error, 0)
    end
    self:require("ui.overlay.focus")
    if self.session == nil or not self.session.active then
      fail("runtime", "E_UI_NOT_OWNER", "no live capture session")
    end
    if self.session.handle ~= handle then
      fail("runtime", "E_UI_NOT_OWNER", "handle does not own the session")
    end
    if not is_component(component) then
      fail("validation", "E_UI_COMPONENT_INVALID", "component is not a declarative node")
    end
    self.session.component = component
    self.session.updates = self.session.updates + 1
    return true
  end
  overlay.poll = function(handle, max)
    if self.poll_error ~= nil then
      error(self.poll_error, 0)
    end
    self:require("ui.overlay.focus")
    if self.session == nil then
      fail("runtime", "E_UI_NOT_OWNER", "no session")
    end
    if self.session.handle ~= handle then
      fail("runtime", "E_UI_NOT_OWNER", "handle does not own the session")
    end
    self.polls = self.polls + 1
    if not self.session.active then
      return {
        status = "released",
        seq = 0,
        events = {},
        overflowed = false,
        reason = self.session.reason or "released",
      }
    end
    local limit = type(max) == "number" and max or 32
    local drained = {}
    while #self.session.events > 0 and #drained < limit do
      drained[#drained + 1] = table.remove(self.session.events, 1)
    end
    return { status = "active", seq = #drained, events = drained, overflowed = false }
  end
  overlay.release = function(handle, reason)
    if self.session == nil or self.session.handle ~= handle then
      return false
    end
    if not self.session.active then
      return false
    end
    self.session.active = false
    self.session.reason = reason or "released"
    self.releases[#self.releases + 1] = { handle = handle, reason = self.session.reason }
    return true
  end
  bitty.ui = { overlay = overlay }

  if self.config_enabled then
    bitty.config = self:build_config()
    bitty.plugins = self:build_plugins()
    bitty.profiles = self:build_profiles()
  end

  return bitty
end

-- Queue one captured input event for the live session.
function MockHost:push(event)
  if self.session == nil or not self.session.active then
    return false
  end
  self.session.events[#self.session.events + 1] = event
  return true
end

function MockHost:release_from_host(reason)
  if self.session == nil then
    return false
  end
  self.session.active = false
  self.session.reason = reason or "timeout"
  return true
end

function MockHost:component()
  return self.session and self.session.component or nil
end

-- Fault injection for the release-on-error paths. A failed call raises a
-- typed table exactly like the bridge does, so the plugin's `pcall` wrapper
-- sees the same shape it sees in production.
function MockHost:fail_poll(error_value)
  self.poll_error = error_value or { class = "runtime", code = "E_UI_POLL", message = "poll failed" }
end

function MockHost:fail_update(error_value)
  self.update_error = error_value or { class = "runtime", code = "E_UI_UPDATE", message = "update failed" }
end

function MockHost:clear_faults()
  self.poll_error = nil
  self.update_error = nil
end

function MockHost:deliver(kind, payload)
  local delivered = 0
  for index = 1, #self.subscriptions do
    local subscription = self.subscriptions[index]
    if subscription.kind == kind then
      delivered = delivered + 1
      subscription.handler({ kind = kind, payload = payload or {} })
    end
  end
  return delivered
end

function MockHost:run(id, args)
  local qualified = self.plugin_id .. ":" .. id
  local def = self.commands[qualified]
  if def == nil then
    fail("validation", "E_COMMAND_UNDECLARED", "command is not registered: " .. qualified)
  end
  return def.run(args or {})
end

-- Advance the mock clock and fire every due one-shot timer. Returns the number
-- of callbacks fired.
function MockHost:advance(ms)
  self.clock = self.clock + ms
  local due = {}
  local remaining = {}
  for index = 1, #self.timers do
    local timer = self.timers[index]
    if timer.deadline <= self.clock then
      due[#due + 1] = timer
    else
      remaining[#remaining + 1] = timer
    end
  end
  self.timers = remaining
  for index = 1, #due do
    due[index].callback()
  end
  return #due
end

return MockHost
