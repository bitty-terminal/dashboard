-- Entry point for the Dashboard (bitty-terminal.dashboard).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls (`bitty.commands.register`, `bitty.events.subscribe`) are valid only
-- while this file executes.
--
-- Surface: the read-only `bitty.runtime.inspect()` snapshot (bitty#2396,
-- merged in bitty#2410), the accepted W-01 focusable-overlay and
-- transient-input-capture contract (`ui.overlay.focus`, `bitty.ui.overlay.*`),
-- and the typed `config.manage` surface (CTX-1613/CTX-1647, bitty#2393) when
-- the host grants it. The overlay is the only host surface that presents a
-- multi-row block to a plugin, and the host paints an `overlay`-slot block
-- only for the capture owner, so the dashboard acquires a session in one
-- Core-owned switch and releases it on close.
--
-- Navigation is captured input, bounded to the documented keys, plus a
-- bounded wheel step. `drain` is the only place that polls; the host nudges
-- `overlay.input.available` when bytes are queued, and a generation-owned
-- one-shot timer re-arms itself while the panel is open so the 30 s idle
-- capture timeout does not close a panel the user is reading. The re-arm
-- budget is finite: an abandoned panel releases its capture at
-- `MAX_SESSION_MS` instead of refreshing the deadline forever.
--
-- Edits follow a two-press contract: the first Enter previews one exact
-- change and shows the host's rendered diff plus its changed keys; the second
-- Enter applies it with the one-shot preview digest. Esc cancels. Without the
-- `config.manage` grant (or on a host that predates it) every tab keeps the
-- read-only `runtime.inspect()` rendering and no write is attempted.

local config = require("dashboard.config")
local edit = require("dashboard.edit")
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

-- Hard lifetime ceiling for one capture session. The keep-alive exists so a
-- reader is not interrupted by the 30 s idle timeout, but an open-and-forgotten
-- panel must not refresh Core's capture forever. Keep this a whole number of
-- re-arms so the budget is deterministic without a clock surface.
M.MAX_SESSION_MS = 600000
M.MAX_KEEPALIVE_REARMS = math.floor(M.MAX_SESSION_MS / M.KEEPALIVE_MS)

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
  rearms = 0,
  edit = edit.new(),
  manage = nil,
  config_blocked = false,
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

-- Clamp the selected row against the row set that is actually on screen.
local function clamp_selection()
  local view = model.build(state.data, state.nav, { height = state.height })
  state.nav.cursor = text.clamp_int(state.nav.cursor, state.nav.offset, 0, model.max_cursor(#view.rows))
  state.nav.offset = model.clamp_offset(state.nav.cursor, #view.rows, view.page)
end

-- Drop the managed data after a refusal that makes the write surface unusable
-- (missing grant, unwired backend, unsafe user layer).
local function block_manage()
  state.config_blocked = true
  state.manage = nil
  if state.data ~= nil then
    state.data.manage = nil
  end
end

-- Forward declaration: `collect` reloads the selected row's value after the
-- section rows are rebuilt.
local load_selected_value

-- Which managed list the active tab needs. Settings are always read; the
-- plugin and profile lists are fetched only for the tab that shows them.
local function active_lists()
  local active = model.section(state.nav.index).id
  return { plugins = active == "plugins", profiles = active == "profiles" }
end

-- Re-read the snapshot and, when the grant allows it, the managed sections.
-- A denied or missing `runtime.inspect` grant is a first-class state: every
-- section renders `unavailable: <reason>` instead of an empty list. A blocked
-- `config.manage` surface leaves `data.manage` nil, which keeps the read-only
-- rendering on every tab.
local function collect()
  local data, err = inspect.collect(bitty)
  if data ~= nil then
    state.data = data
    state.error = nil
  else
    state.data = unavailable_all(err.message)
    state.error = err
    state.manage = nil
    clamp_selection()
    return false
  end
  if not state.config_blocked then
    local managed, manage_err = config.collect(bitty, state.manage, active_lists())
    if managed ~= nil then
      state.data.manage = managed
      state.manage = managed
    elseif config.is_blocked(manage_err) then
      block_manage()
    elseif state.manage ~= nil then
      -- A rate or read refusal keeps the last good managed snapshot instead
      -- of dropping a granted panel back to read-only.
      state.data.manage = state.manage
    else
      state.data.manage = nil
    end
  end
  clamp_selection()
  load_selected_value()
  return true
end

-- Fetch one managed list the first time its tab becomes active. One call,
-- so a tab switch cannot spend the generation's `config.manage` budget.
local function collect_list(section_id)
  local managed = state.data and state.data.manage
  if managed == nil or state.config_blocked then
    return
  end
  if section_id == "plugins" and managed.plugins == nil then
    local plugins, err = config.plugins(bitty)
    if plugins ~= nil then
      managed.plugins = plugins
    elseif config.is_blocked(err) then
      block_manage()
    end
  elseif section_id == "profiles" and managed.profiles == nil then
    local profiles, err = config.profiles(bitty)
    if profiles ~= nil then
      managed.profiles = profiles
    elseif config.is_blocked(err) then
      block_manage()
    end
  end
end

-- Read one row's value with `config.get`. `sources()` never carries a value,
-- so this is the only read that touches a setting.
local function load_row_value(row)
  if row == nil or row.loaded then
    return
  end
  local value, err = config.get(bitty, row.key)
  if value == nil then
    if config.is_blocked(err) then
      block_manage()
    end
    return
  end
  row.value = value.value
  row.found = value.found
  row.kind = value.kind
  row.redacted = value.redacted
  row.source = value.source ~= "" and value.source or row.source
  row.loaded = true
end

-- Read the selected Settings row when its value is not cached yet.
load_selected_value = function()
  if model.section(state.nav.index).id ~= "settings" then
    return
  end
  local managed = state.data and state.data.manage
  if managed == nil or managed.settings == nil then
    return
  end
  load_row_value(managed.settings.rows[state.nav.cursor + 1])
end

local function layout()
  local view = model.build(state.data, state.nav, { height = state.height, edit = state.edit })
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
    state.rearms = state.rearms + 1
    if state.rearms >= M.MAX_KEEPALIVE_REARMS then
      -- Budget spent: release the capture explicitly instead of keeping an
      -- abandoned panel alive indefinitely.
      M.close("cancelled")
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
  state.rearms = 0
  state.edit = edit.new()
  state.manage = nil
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
  state.rearms = 0
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

-- Captured key helpers. Core labels most named keys `key:<Name>` and a
-- character as bare text when the layout supplies it. Enter, Tab, Backspace,
-- and Escape arrive as their control literal when the platform provides one
-- (`\r`, `\t`, `\b`, `\x1b`), so both spellings normalize to one name.
local NAMED_LITERALS = {
  ["\r"] = "enter",
  ["\n"] = "enter",
  ["\t"] = "tab",
  ["\b"] = "backspace",
  ["\27"] = "escape",
}

local function key_named(event)
  if type(event) ~= "table" or event.type ~= "key" or type(event.text) ~= "string" then
    return nil, nil
  end
  local raw = event.text
  if NAMED_LITERALS[raw] ~= nil then
    return NAMED_LITERALS[raw], nil
  end
  if string.sub(raw, 1, 4) == "key:" then
    return string.lower(string.sub(raw, 5)), nil
  end
  return nil, raw
end

-- Normalize a control-literal key into the `key:<Name>` spelling the pure
-- navigation model understands.
local function model_event(event)
  if type(event) == "table" and event.type == "key" and NAMED_LITERALS[event.text] ~= nil then
    return { type = "key", text = "key:" .. NAMED_LITERALS[event.text], data = event.data }
  end
  return event
end

-- One printable character from a captured key event, or nil.
local function key_char(event)
  if type(event) ~= "table" or event.type ~= "key" or type(event.text) ~= "string" then
    return nil
  end
  local raw = event.text
  if string.sub(raw, 1, 4) == "key:" then
    local named = string.sub(raw, 5)
    if named == " " then
      return " "
    end
    if #named == 1 and string.match(named, "%c") == nil then
      return named
    end
    return nil
  end
  if raw ~= "" and string.match(raw, "%c") == nil then
    return raw
  end
  return nil
end

-- The managed row under the selection, or nil when that tab is read-only.
local function selected_managed_row(section_id)
  local managed = state.data and state.data.manage
  local section = managed and managed[section_id] or nil
  if section == nil then
    return nil
  end
  return section.rows[state.nav.cursor + 1]
end

-- Turn one refused call into a bounded notice. A denial is terminal for the
-- generation: the panel drops back to the read-only rendering and never
-- retries the write.
local function write_failure(err)
  if err == nil then
    state.edit = edit.notice(state.edit, "config.manage call failed")
    return
  end
  if config.is_blocked(err) then
    block_manage()
    collect()
    state.edit = edit.notice(edit.new(), config.blocked_notice(err))
    return
  end
  state.edit = edit.notice(state.edit, err.code .. ": " .. err.message)
end

local function preview_config(key, value, notice)
  local preview, err = config.preview(bitty, key, value)
  if preview == nil then
    write_failure(err)
    return false
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_CONFIG,
    subject = key,
    kind = config.kind_of(key) or config.KIND_TEXT,
    value = value,
    preview = preview,
    notice = notice,
  })
  return true
end

-- Enter on one editable setting: bools toggle, enums cycle, and everything
-- else opens the one-line input.
local function begin_setting_edit(item)
  if item == nil then
    return
  end
  if not item.loaded then
    load_row_value(item)
  end
  if not item.loaded then
    state.edit = edit.notice(state.edit, "value unavailable; press r to retry")
    return
  end
  local kind = config.kind_of(item.key) or item.kind or config.KIND_TEXT
  local values = config.ENUMS[item.key]
  if kind == config.KIND_BOOL then
    preview_config(item.key, not (item.value == true))
  elseif values ~= nil then
    local current = item.found and item.value or nil
    preview_config(item.key, edit.next_enum(current, values))
  else
    state.edit = edit.start_input(state.edit, {
      target = edit.TARGET_CONFIG,
      subject = item.key,
      kind = kind,
      seed = item.found and edit.seed_value(item.value, kind) or "",
      prompt = item.key .. " = ",
    })
  end
end

local function begin_plugin_toggle(item)
  if item == nil then
    return
  end
  local enabled = not item.enabled
  local preview, err = config.preview_enabled(bitty, item.id, enabled)
  if preview == nil then
    write_failure(err)
    return
  end
  if preview.changed == false then
    state.edit = edit.notice(
      state.edit,
      item.id .. " is already " .. (item.enabled and "enabled" or "disabled")
    )
    return
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PLUGIN,
    subject = item.id,
    kind = config.KIND_BOOL,
    value = enabled,
    preview = preview,
  })
end

local function begin_profile_use(item)
  if item == nil then
    return
  end
  if item.active then
    state.edit = edit.notice(state.edit, item.name .. " is already active")
    return
  end
  local preview, err = config.preview_use(bitty, item.name)
  if preview == nil then
    write_failure(err)
    return
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PROFILE,
    subject = item.name,
    kind = config.KIND_TEXT,
    value = nil,
    preview = preview,
  })
end

local function preview_profile_create(name, opts, notice)
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return false
  end
  local preview, err = config.preview_create(bitty, name, opts)
  if preview == nil then
    write_failure(err)
    return false
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PROFILE_CREATE,
    subject = name,
    kind = config.KIND_TEXT,
    value = name,
    opts = opts,
    preview = preview,
    notice = notice,
  })
  return true
end

local function preview_profile_clone(src, dst, opts, notice)
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return false
  end
  local preview, err = config.preview_clone(bitty, src, dst, opts)
  if preview == nil then
    write_failure(err)
    return false
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PROFILE_CLONE,
    subject = src,
    kind = config.KIND_TEXT,
    value = dst,
    opts = opts,
    preview = preview,
    notice = notice,
  })
  return true
end

local function preview_profile_rename(old_name, new_name, opts, notice)
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return false
  end
  local preview, err = config.preview_rename(bitty, old_name, new_name, opts)
  if preview == nil then
    write_failure(err)
    return false
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PROFILE_RENAME,
    subject = old_name,
    kind = config.KIND_TEXT,
    value = new_name,
    opts = opts,
    preview = preview,
    notice = notice,
  })
  return true
end

local function preview_profile_delete(name, opts, notice)
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return false
  end
  local preview, err = config.preview_delete(bitty, name, opts)
  if preview == nil then
    write_failure(err)
    return false
  end
  state.edit = edit.start_confirm(state.edit, {
    target = edit.TARGET_PROFILE_DELETE,
    subject = name,
    kind = config.KIND_TEXT,
    value = nil,
    opts = opts,
    preview = preview,
    notice = notice,
  })
  return true
end

local function begin_profile_create(opts)
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return
  end
  state.edit = edit.start_input(state.edit, {
    target = edit.TARGET_PROFILE_CREATE,
    subject = "",
    kind = config.KIND_TEXT,
    opts = opts,
    seed = "",
    prompt = "new profile = ",
  })
end

local function begin_profile_clone(item, opts)
  if item == nil then
    return
  end
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return
  end
  state.edit = edit.start_input(state.edit, {
    target = edit.TARGET_PROFILE_CLONE,
    subject = item.name,
    kind = config.KIND_TEXT,
    opts = opts,
    seed = item.name .. "-copy",
    prompt = "clone " .. item.name .. " as = ",
  })
end

local function begin_profile_rename(item, opts)
  if item == nil then
    return
  end
  if not config.profile_lifecycle(bitty) then
    state.edit = edit.notice(state.edit, "profile lifecycle unavailable on this host")
    return
  end
  state.edit = edit.start_input(state.edit, {
    target = edit.TARGET_PROFILE_RENAME,
    subject = item.name,
    kind = config.KIND_TEXT,
    opts = opts,
    seed = item.name,
    prompt = "rename " .. item.name .. " to = ",
  })
end

local function begin_profile_delete(item, opts)
  if item == nil then
    return
  end
  preview_profile_delete(item.name, opts)
end

-- Re-run the preview for one pending intent. Used after a stale digest or an
-- expired approval: the user reviews the fresh rendering before the second
-- Enter.
local function repreview(pending, notice)
  local preview, err
  if pending.target == edit.TARGET_CONFIG then
    preview, err = config.preview(bitty, pending.subject, pending.value)
  elseif pending.target == edit.TARGET_PLUGIN then
    preview, err = config.preview_enabled(bitty, pending.subject, pending.value)
  elseif pending.target == edit.TARGET_PROFILE_CREATE then
    preview, err = config.preview_create(bitty, pending.subject, pending.opts)
  elseif pending.target == edit.TARGET_PROFILE_CLONE then
    preview, err = config.preview_clone(bitty, pending.subject, pending.value, pending.opts)
  elseif pending.target == edit.TARGET_PROFILE_RENAME then
    preview, err = config.preview_rename(bitty, pending.subject, pending.value, pending.opts)
  elseif pending.target == edit.TARGET_PROFILE_DELETE then
    preview, err = config.preview_delete(bitty, pending.subject, pending.opts)
  else
    preview, err = config.preview_use(bitty, pending.subject)
  end
  if preview == nil then
    write_failure(err)
    return
  end
  state.edit = edit.start_confirm(edit.new(), {
    target = pending.target,
    subject = pending.subject,
    kind = pending.kind,
    value = pending.value,
    opts = pending.opts,
    preview = preview,
    notice = notice,
  })
end

local function reload_note(reload)
  return reload ~= nil and reload ~= "" and reload or "auto"
end

-- Refresh the runtime snapshot without spending a `config.manage` call. The
-- managed rows are reattached so the panel keeps its editable data.
local function refresh_snapshot()
  local data = inspect.collect(bitty)
  if data == nil then
    return
  end
  state.data = data
  state.data.manage = state.manage
  clamp_selection()
end

-- Apply one accepted setting write to the cached row. The write result is
-- authoritative for the changed key, so no extra read is spent on it.
local function update_setting_row(key, value, applied)
  local managed = state.manage
  if managed == nil or managed.settings == nil or not applied then
    return
  end
  for index = 1, #managed.settings.rows do
    local row = managed.settings.rows[index]
    if row.key == key then
      row.value = value
      row.found = true
      row.kind = config.kind_of(key) or row.kind
      row.source = "user"
      row.redacted = false
      row.loaded = true
      return
    end
  end
end

local function update_plugin_row(id, enabled)
  local managed = state.manage
  if managed == nil or managed.plugins == nil then
    return
  end
  for index = 1, #managed.plugins.rows do
    if managed.plugins.rows[index].id == id then
      managed.plugins.rows[index].enabled = enabled
      return
    end
  end
end

local function update_profile_rows(name)
  local managed = state.manage
  if managed == nil or managed.profiles == nil then
    return
  end
  for index = 1, #managed.profiles.rows do
    managed.profiles.rows[index].active = managed.profiles.rows[index].name == name
  end
  managed.profiles.active = name
end

local function insert_or_select_profile_row(name)
  local managed = state.manage
  if managed == nil or managed.profiles == nil then
    return
  end
  local rows = managed.profiles.rows
  for index = 1, #rows do
    if rows[index].name == name then
      state.nav.cursor = index - 1
      return
    end
  end
  rows[#rows + 1] = { name = name, active = (managed.profiles.active == name) }
  state.nav.cursor = #rows - 1
end

local function rename_profile_row(old_name, new_name, selector_updated)
  local managed = state.manage
  if managed == nil or managed.profiles == nil then
    return
  end
  local rows = managed.profiles.rows
  local kept = {}
  local selected = nil
  local was_active = (managed.profiles.active == old_name) or selector_updated == true
  for index = 1, #rows do
    local row = rows[index]
    if row.name == old_name then
      was_active = was_active or row.active == true
      kept[#kept + 1] = { name = new_name, active = was_active }
      selected = #kept - 1
    elseif row.name ~= new_name then
      kept[#kept + 1] = row
    end
  end
  if selected == nil then
    kept[#kept + 1] = { name = new_name, active = was_active }
    selected = #kept - 1
  end
  managed.profiles.rows = kept
  if was_active then
    managed.profiles.active = new_name
  end
  state.nav.cursor = selected
end

local function remove_profile_row(name, was_active)
  local managed = state.manage
  if managed == nil or managed.profiles == nil then
    return
  end
  local rows = managed.profiles.rows
  local kept = {}
  for index = 1, #rows do
    if rows[index].name ~= name then
      kept[#kept + 1] = rows[index]
    elseif rows[index].active then
      was_active = true
    end
  end
  managed.profiles.rows = kept
  if was_active or managed.profiles.active == name then
    managed.profiles.active = ""
  end
end

-- Re-read the settings after a profile switch: the selected chain can change
-- every effective value. The plugin/profile lists are kept as they were.
local function refresh_settings_after_profile()
  local managed = state.manage
  if managed == nil then
    return
  end
  local fresh, err = config.collect(bitty, managed, {})
  if fresh ~= nil then
    fresh.plugins = managed.plugins
    fresh.profiles = managed.profiles
    state.manage = fresh
  elseif config.is_blocked(err) then
    block_manage()
  end
end

-- Second Enter: apply the previewed change with its one-shot digest.
local function apply_pending()
  local pending = state.edit
  if pending.mode ~= edit.MODE_CONFIRM then
    return
  end

  if pending.target == edit.TARGET_CONFIG then
    local result, err = config.set(bitty, pending.subject, pending.value, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the value changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    update_setting_row(pending.subject, pending.value, result.applied)
    refresh_snapshot()
    local note = result.applied and ("applied · reload " .. reload_note(result.reload)) or "no change"
    state.edit = edit.notice(edit.new(), note)
    return
  end

  if pending.target == edit.TARGET_PLUGIN then
    local result, err = config.set_enabled(bitty, pending.subject, pending.value, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the ledger changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    update_plugin_row(pending.subject, pending.value)
    refresh_snapshot()
    local note
    if result.changed then
      note = (pending.value and "enabled " or "disabled ")
        .. pending.subject
        .. " · reload "
        .. reload_note(result.reload)
    else
      note = "no change"
    end
    state.edit = edit.notice(edit.new(), note)
    return
  end

  if pending.target == edit.TARGET_PROFILE_CREATE then
    local result, err = config.create(bitty, pending.subject, pending.opts, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the profile changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    local name = result.name ~= "" and result.name or pending.subject
    insert_or_select_profile_row(name)
    refresh_snapshot()
    local note = result.changed and ("created profile " .. name .. " · reload " .. reload_note(result.reload))
      or "no change"
    state.edit = edit.notice(edit.new(), note)
    return
  end

  if pending.target == edit.TARGET_PROFILE_CLONE then
    local result, err = config.clone(bitty, pending.subject, pending.value, pending.opts, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the profile changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    local name = result.name ~= "" and result.name or pending.value
    insert_or_select_profile_row(name)
    refresh_snapshot()
    local note = result.changed
        and ("cloned profile " .. pending.subject .. " to " .. name .. " · reload " .. reload_note(result.reload))
      or "no change"
    state.edit = edit.notice(edit.new(), note)
    return
  end

  if pending.target == edit.TARGET_PROFILE_RENAME then
    local result, err = config.rename(bitty, pending.subject, pending.value, pending.opts, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the profile changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    local old_name = result.old_name ~= "" and result.old_name or pending.subject
    local new_name = result.new_name ~= "" and result.new_name or pending.value
    rename_profile_row(old_name, new_name, result.selector_updated)
    if result.selector_updated then
      refresh_settings_after_profile()
    end
    refresh_snapshot()
    local note = result.changed
        and ("renamed profile " .. old_name .. " to " .. new_name .. " · reload " .. reload_note(result.reload))
      or "no change"
    state.edit = edit.notice(edit.new(), note)
    return
  end

  if pending.target == edit.TARGET_PROFILE_DELETE then
    local result, err = config.delete(bitty, pending.subject, pending.opts, pending.digest)
    if result == nil then
      if err.code == config.CODE_STALE then
        repreview(pending, "the profile changed, review again")
      elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
        repreview(pending, "approval expired, review again")
      else
        write_failure(err)
      end
      return
    end
    local name = result.name ~= "" and result.name or pending.subject
    remove_profile_row(name, result.was_active)
    refresh_snapshot()
    local note = result.changed and ("deleted profile " .. name .. " · reload " .. reload_note(result.reload))
      or "no change"
    state.edit = edit.notice(edit.new(), note)
    return
  end

  local result, err = config.use(bitty, pending.subject, pending.digest)
  if result == nil then
    if err.code == config.CODE_STALE then
      repreview(pending, "the profile selector changed, review again")
    elseif err.code == config.CODE_APPROVAL_REQUIRED or err.code == config.CODE_APPROVAL_MISMATCH then
      repreview(pending, "approval expired, review again")
    else
      write_failure(err)
    end
    return
  end
  local active = result.active ~= "" and result.active or pending.subject
  update_profile_rows(active)
  refresh_settings_after_profile()
  refresh_snapshot()
  local note
  if result.changed then
    note = "profile " .. active .. " active · reload " .. reload_note(result.reload)
  else
    note = "no change"
  end
  if result.pending_restart then
    note = note .. " · restart required"
  end
  state.edit = edit.notice(edit.new(), note)
end

-- Activate the selected row in browse mode. Returns whether the key was
-- consumed; a read-only tab consumes nothing and keeps the old navigation.
local function activate_selected(named, literal)
  local section = model.section(state.nav.index)
  local is_enter = named == "enter"
  local is_space = named == " " or literal == " "
  if section.id == "profiles" then
    local managed = state.data and state.data.manage
    if managed == nil or managed.profiles == nil then
      return false
    end
    local item = selected_managed_row("profiles")
    if is_enter then
      if item == nil then
        return false
      end
      begin_profile_use(item)
      return true
    end
    if literal == "n" or literal == "a" then
      begin_profile_create()
      return true
    end
    if literal == "c" then
      if item == nil then
        return false
      end
      begin_profile_clone(item)
      return true
    end
    if literal == "e" or literal == "R" then
      if item == nil then
        return false
      end
      begin_profile_rename(item)
      return true
    end
    if literal == "d" or literal == "x" or named == "delete" then
      if item == nil then
        return false
      end
      begin_profile_delete(item)
      return true
    end
    return false
  end
  if not is_enter and not is_space then
    return false
  end
  if section.id == "settings" then
    if not is_enter then
      return false
    end
    local item = selected_managed_row("settings")
    if item == nil then
      return false
    end
    begin_setting_edit(item)
    return true
  end
  if section.id == "plugins" then
    local item = selected_managed_row("plugins")
    if item == nil then
      return false
    end
    begin_plugin_toggle(item)
    return true
  end
  return false
end

-- Handle one captured key while an input or confirm step is active.
-- Returns `handled, changed`.
local function handle_edit_key(event)
  local named = key_named(event)
  if state.edit.mode == edit.MODE_INPUT then
    if named == "enter" then
      local value, message = edit.parse_value(state.edit.kind, state.edit.buffer or "")
      if value == nil then
        state.edit = edit.invalid(state.edit, message)
        return true, true
      end
      local target = state.edit.target
      local subject = state.edit.subject
      local opts = state.edit.opts
      if target == edit.TARGET_PROFILE_CREATE then
        preview_profile_create(value, opts)
      elseif target == edit.TARGET_PROFILE_CLONE then
        preview_profile_clone(subject, value, opts)
      elseif target == edit.TARGET_PROFILE_RENAME then
        preview_profile_rename(subject, value, opts)
      else
        preview_config(subject, value)
      end
      return true, true
    end
    if named == "escape" then
      state.edit = edit.cancel(state.edit)
      return true, true
    end
    if named == "backspace" then
      state.edit = edit.backspace(state.edit)
      return true, true
    end
    local char = key_char(event)
    if char ~= nil then
      state.edit = edit.append(state.edit, char)
      return true, true
    end
    return true, false
  end
  if state.edit.mode == edit.MODE_CONFIRM then
    if named == "enter" then
      apply_pending()
      return true, true
    end
    if named == "escape" then
      state.edit = edit.cancel(state.edit)
      return true, true
    end
    return true, false
  end
  return false, false
end

-- Drain queued capture input and apply it to navigation. Bounded by
-- `POLL_MAX` per call; stops as soon as the session ends.
function M.drain()
  if not state.open or state.handle == nil then
    return false
  end
  local overlay = overlay_table()
  if overlay == nil or type(overlay.poll) ~= "function" then
    -- The surface vanished underneath the panel. `close` releases the capture
    -- whenever a release surface exists and always clears local state, so Core
    -- never keeps capturing for a panel that is no longer there.
    M.close("cancelled")
    return false
  end
  local ok, poll = pcall(overlay.poll, state.handle, M.POLL_MAX)
  if not ok or type(poll) ~= "table" then
    M.close("cancelled")
    return false
  end
  if poll.status == "released" then
    -- Involuntary end (timeout, focus switch, unload): the surface is already
    -- gone, so only local state is cleared.
    reset()
    return false
  end

  local events = type(poll.events) == "table" and poll.events or {}
  local changed = false
  for index = 1, #events do
    local event = events[index]
    if state.edit.mode ~= edit.MODE_BROWSE then
      local handled, edit_changed = handle_edit_key(event)
      if handled then
        changed = changed or edit_changed
      end
    else
      local named, literal = key_named(event)
      if activate_selected(named, literal) then
        changed = true
      else
        local view = model.build(state.data, state.nav, { height = state.height })
        local opts = { row_count = #view.rows, page = view.page }
        local section_before = state.nav.index
        local cursor_before = state.nav.cursor
        local next_nav, action, moved = model.apply_key(state.nav, model_event(event), opts)
        state.nav = next_nav
        if state.nav.index ~= section_before then
          state.edit = edit.new()
          collect_list(model.section(state.nav.index).id)
          load_selected_value()
        elseif state.nav.cursor ~= cursor_before then
          load_selected_value()
        end
        changed = changed or moved
        if action == model.ACTION_CLOSE then
          M.close("cancelled")
          return true
        end
        if action == model.ACTION_REFRESH then
          -- A refresh drops the cached values so the selected row is read
          -- again from the host.
          state.manage = nil
          collect()
          changed = true
        end
      end
    end
  end
  if changed and not paint() then
    -- A failed repaint leaves the panel stale (or the host reports the
    -- session is gone). Release explicitly instead of keeping capture with
    -- nothing on screen.
    M.close("cancelled")
    return false
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
    cursor = state.nav.cursor,
    error = state.error and state.error.code or nil,
    handle = state.handle,
    timer = state.timer ~= nil,
    rearms = state.rearms,
    width = state.width,
    height = state.height,
    mode = state.edit.mode,
    notice = state.edit.notice,
    manage = state.data ~= nil and state.data.manage ~= nil,
    blocked = state.config_blocked,
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
M.config = config
M.edit = edit

if bitty == nil or type(bitty) ~= "table" then
  return M
end

if type(bitty.commands) == "table" and type(bitty.commands.register) == "function" then
  bitty.commands.register({
    id = "toggle_dashboard",
    title = "Dashboard: toggle",
    description = "Open or close the configuration and status dashboard.",
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
end

if type(bitty.events) == "table" and type(bitty.events.subscribe) == "function" then
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
end

return M
