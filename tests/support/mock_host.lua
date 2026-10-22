-- In-process `bitty` host stub for the Dashboard behavior tests.
--
-- Models only the accepted surface the plugin uses: the lazy command and event
-- registration gates, `bitty.runtime.inspect()`, the W-01 focusable-overlay
-- session (`bitty.ui.overlay.*`), and generation-owned one-shot timers. Every
-- capability is deny-by-default and every payload is recorded so specs can
-- assert the exact host call shape.
--
-- It performs no I/O, spawns nothing, and never touches the network or the
-- filesystem. Events, snapshots, and captured input are staged explicitly.

local MockHost = {}
MockHost.__index = MockHost

local PLUGIN_ID = "bitty-terminal.dashboard"

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
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
  for _, name in ipairs(options.grants or { "runtime.inspect", "ui.overlay.focus" }) do
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
