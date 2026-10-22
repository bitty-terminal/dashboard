-- Entry point for the Dashboard (bitty-terminal.dashboard).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls (`bitty.commands.register`, `bitty.events.subscribe`) are valid only
-- while this file executes.
--
-- Surface: the read-only `bitty.runtime.inspect()` snapshot (bitty#2396,
-- merged in bitty#2410) plus the accepted W-01 focusable-overlay and
-- transient-input-capture contract (`ui.overlay.focus`,
-- `bitty.ui.overlay.*`). The overlay is the only host surface that presents a
-- multi-row block to a plugin, and the host paints an `overlay`-slot block
-- only for the capture owner, so the dashboard acquires a session in one
-- Core-owned switch and releases it on close. No other authority is requested:
-- no `config.manage`, no filesystem, process, network, clipboard, or terminal
-- input.
--
-- Navigation is captured input, bounded to the documented keys, plus a
-- bounded wheel step. `drain` is the only place that polls; the host nudges
-- `overlay.input.available` when bytes are queued, and a generation-owned
-- one-shot timer re-arms itself while the panel is open so the 30 s idle
-- capture timeout does not close a panel the user is reading.
--
-- Settings are read-only. Writing them is deferred until the typed
-- `config.manage` API lands (bitty#2393); the UI and README say so explicitly
-- and no code path here writes configuration.

local inspect = require("dashboard.inspect")
local model = require("dashboard.model")
local render = require("dashboard.render")
local text = require("dashboard.text")

local M = {}

M.PLUGIN_ID = "bitty-terminal.dashboard"
M.UPDATE_TITLE = "Dashboard"
M.UPDATE_PLACEHOLDER = "Reading runtime state…"

-- Poll ceiling per drain call, mirroring the host's bounded capture poll.
M.POLL_MAX = 32

-- Re-arm cadence for the session keep-alive. Must stay well below the host's
-- 30 s idle capture timeout (`OVERLAY_CAPTURE_TIMEOUT_MS`); a poll refreshes
-- the deadline even when it drains nothing.
M.KEEPALIVE_MS = 10000

-- Presentation hints from an optional command argument. The Plugin API v1 has
-- no viewport-size surface, so the declared layout drives truncation and page
-- size while the host clips the painted block to the live window.
M.DEFAULT_WIDTH = text.DEFAULT_WIDTH
M.DEFAULT_HEIGHT = text.DEFAULT_HEIGHT

local state = {
  open = false,
  handle = nil,
  nav = model.new_state(),
  data = nil,
  error = nil,
  width = M.DEFAULT_WIDTH,
  height = M.DEFAULT_HEIGHT,
  timer = nil,
}

local function overlay_table()
  if bitty == nil or type(bitty) ~= "table" then
    return nil
  end
  if type(bitty.ui) ~= "table" then
    return nil
  end
  if type(bitty.ui.overlay) ~= "table" then
    return nil
  end
  return bitty.ui.overlay
end

local function unavailable_all(reason)
  local failure = { kind = inspect.KIND_UNAVAILABLE, reason = reason }
  return {
    diagnostics = failure,
    plugins = failure,
    extensions = failure,
    settings = failure,
    profiles = failure,
  }
end

-- Re-read the snapshot. A denied or missing `runtime.inspect` grant is a
-- first-class state: every section renders `unavailable: <reason>` instead of
-- an empty list.
local function collect()
  local data, err = inspect.collect(bitty)
  if data ~= nil then
    state.data = data
    state.error = nil
    return true
  end
  state.data = unavailable_all(err.message)
  state.error = err
  return false
end

local function layout()
  local view = model.build(state.data, state.nav, { height = state.height })
  view.offset = state.nav.offset
  local component = render.scene(view, { width = state.width, height = state.height })
  return component, view
end

local function cancel_keepalive()
  local handle = state.timer
  state.timer = nil
  if handle == nil then
    return
  end
  if bitty == nil or type(bitty) ~= "table" or type(bitty.timers) ~= "table" then
    return
  end
  if type(bitty.timers.cancel) ~= "function" then
    return
  end
  pcall(bitty.timers.cancel, handle)
end

local function arm_keepalive()
  if not state.open or state.timer ~= nil then
    return
  end
  if bitty == nil or type(bitty) ~= "table" or type(bitty.timers) ~= "table" then
    return
  end
  if type(bitty.timers.create) ~= "function" then
    return
  end
  local ok, handle = pcall(bitty.timers.create, M.KEEPALIVE_MS, function()
    state.timer = nil
    if not state.open then
      return
    end
    -- Polling refreshes the capture deadline; the drain only repaints when a
    -- key actually changed something.
    M.drain()
    arm_keepalive()
  end)
  if ok and type(handle) == "number" then
    state.timer = handle
  end
end

local function reset()
  cancel_keepalive()
  state.open = false
  state.handle = nil
  state.nav = model.new_state()
  state.data = nil
  state.error = nil
end

-- Paint the current view on the held session. A rejected update keeps the
-- previous scene and never throws at the command caller.
local function paint()
  if not state.open or state.handle == nil then
    return false
  end
  local overlay = overlay_table()
  if overlay == nil or type(overlay.update) ~= "function" then
    return false
  end
  local component = layout()
  local ok, updated = pcall(overlay.update, state.handle, component)
  if not ok or updated == false then
    return false
  end
  return true
end

-- Open the panel: acquire the focusable overlay and its capture session, then
-- paint the first scene. Returns `true` on success and `false` plus a typed
-- error when the host denies the surface.
function M.open(args)
  args = args or {}
  if state.open then
    return true, nil
  end
  state.width = text.clamp_int(args.width, M.DEFAULT_WIDTH, text.MIN_WIDTH, text.MAX_WIDTH)
  state.height = text.clamp_int(args.height, M.DEFAULT_HEIGHT, text.MIN_HEIGHT, text.MAX_HEIGHT)
  state.nav = model.new_state()
  collect()

  local overlay = overlay_table()
  if overlay == nil or type(overlay.acquire) ~= "function" then
    reset()
    local err = inspect.error(inspect.CODE_UNAVAILABLE, "focusable overlay is not available")
    state.error = err
    return false, err
  end
  local ok, handle = pcall(overlay.acquire, {
    title = M.UPDATE_TITLE,
    placeholder = M.UPDATE_PLACEHOLDER,
  })
  if not ok or type(handle) ~= "number" then
    reset()
    local err = inspect.error_from(handle)
    state.error = err
    return false, err
  end
  state.open = true
  state.handle = handle
  if not paint() then
    pcall(overlay.release, handle, "cancelled")
    reset()
    local err = inspect.error(inspect.CODE_UNAVAILABLE, "overlay update failed")
    state.error = err
    return false, err
  end
  arm_keepalive()
  return true, nil
end

-- Close the panel and end the capture session. Release is host-idempotent and
-- deliberately ungated, so a revoked grant still clears local state.
function M.close(reason)
  local handle = state.handle
  if handle ~= nil then
    local overlay = overlay_table()
    if overlay ~= nil and type(overlay.release) == "function" then
      pcall(overlay.release, handle, reason or "cancelled")
    end
  end
  reset()
  return true
end

-- Drain queued capture input and apply it to navigation. Bounded by
-- `POLL_MAX` per call; stops as soon as the session ends.
function M.drain()
  if not state.open or state.handle == nil then
    return false
  end
  local overlay = overlay_table()
  if overlay == nil or type(overlay.poll) ~= "function" then
    return false
  end
  local ok, poll = pcall(overlay.poll, state.handle, M.POLL_MAX)
  if not ok or type(poll) ~= "table" then
    reset()
    return false
  end
  if poll.status == "released" then
    -- Involuntary end (timeout, focus switch, unload): the surface is already
    -- gone, so only local state is cleared.
    reset()
    return false
  end

  local view = model.build(state.data, state.nav, { height = state.height })
  local opts = { row_count = #view.rows, page = view.page }
  local events = type(poll.events) == "table" and poll.events or {}
  local changed = false
  for index = 1, #events do
    local event = events[index]
    local next_nav, action, moved = model.apply_key(state.nav, event, opts)
    state.nav = next_nav
    changed = changed or moved
    if action == model.ACTION_CLOSE then
      M.close("cancelled")
      return true
    end
    if action == model.ACTION_REFRESH then
      collect()
      changed = true
    end
  end
  if changed then
    paint()
  end
  return true
end

-- Toggle command: open when closed, close when open. Returns whether the
-- dashboard is open after the call.
function M.toggle(args)
  if state.open then
    M.close("cancelled")
    return false
  end
  local opened = M.open(args or {})
  return opened == true
end

-- Read-only status for tests and operators.
function M.status()
  local section = model.section(state.nav.index)
  return {
    open = state.open,
    section = section.id,
    offset = state.nav.offset,
    error = state.error and state.error.code or nil,
    handle = state.handle,
    timer = state.timer ~= nil,
    width = state.width,
    height = state.height,
  }
end

-- Pure hook used by the behavior tests: render one frame without a host.
function M.render_frame(data, nav, opts)
  local view = model.build(data, nav, opts or {})
  return render.scene(view, opts or {})
end

M.render = render
M.model = model
M.inspect = inspect

if bitty == nil or type(bitty) ~= "table" then
  return M
end

bitty.commands.register({
  id = "toggle_dashboard",
  title = "Dashboard: toggle",
  description = "Open or close the read-only configuration and status dashboard.",
  args_schema = {
    type = "object",
    properties = {
      width = { type = "integer", minimum = text.MIN_WIDTH, maximum = text.MAX_WIDTH },
      height = { type = "integer", minimum = text.MIN_HEIGHT, maximum = text.MAX_HEIGHT },
    },
    additionalProperties = false,
  },
  result_schema = { type = "boolean" },
  run = function(args)
    return M.toggle(args)
  end,
})

-- The host nudges the capture owner when bytes are queued (bitty#1972), so
-- navigation never needs a Core-driven callback on the input hot path.
bitty.events.subscribe("overlay.input.available", function(_event)
  M.drain()
end)

-- Cold-path drain: a focus transition is where input is most likely to be
-- stranded, and it also refreshes the snapshot before the next paint.
bitty.events.subscribe("focus.changed", function(_event)
  M.drain()
end)

-- The host ends a capture on timeout, focus switch, unload, or crash. The
-- surface is already gone; clear local state so the next toggle reopens.
bitty.events.subscribe("overlay.released", function(event)
  if not state.open then
    return
  end
  local payload = type(event) == "table" and event.payload or nil
  if type(payload) == "table" and type(payload.owner) == "string" and payload.owner ~= M.PLUGIN_ID then
    return
  end
  reset()
end)

return M
