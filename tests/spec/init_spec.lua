-- Entry-point behavior against the in-process host stub: command/event
-- registration, overlay lifecycle, captured navigation, and keep-alive.

local MockHost = require("support.mock_host")
local snapshot = require("support.snapshot")

local M = {}

local function load(options)
  options = options or {}
  options.snapshot = options.snapshot or snapshot.full()
  local host = MockHost.new(options)
  _G.bitty = host.bitty
  -- Each load must evaluate `init.lua` again: the plugin keeps generation
  -- state (open flag, capture handle, navigation) at module scope.
  package.loaded["dashboard.init"] = nil
  local plugin = require("dashboard.init")
  return host, plugin
end

local function lines(component)
  local out = {}
  local function walk(node)
    if node == nil then
      return
    end
    if node.kind == "Text" then
      out[#out + 1] = node.text
      return
    end
    for index = 1, #(node.children or {}) do
      walk(node.children[index])
    end
  end
  walk(component)
  return table.concat(out, "\n")
end

function M.registers_the_lazy_command_and_events()
  local host = load()
  if host.commands["bitty-terminal.dashboard:toggle_dashboard"] == nil then
    error("toggle_dashboard was not registered")
  end
  local kinds = {}
  for index = 1, #host.subscriptions do
    kinds[host.subscriptions[index].kind] = true
  end
  for _, kind in ipairs({ "overlay.input.available", "focus.changed", "overlay.released" }) do
    if not kinds[kind] then
      error("missing subscription: " .. kind)
    end
  end
end

function M.toggle_opens_paints_and_arms_one_timer()
  local host, plugin = load()
  if host:run("toggle_dashboard") ~= true then
    error("the first toggle must open the dashboard")
  end
  if host.session == nil or not host.session.active then
    error("no live overlay session")
  end
  if host.session.updates < 1 then
    error("the panel was not painted")
  end
  if host.inspect_calls < 1 then
    error("runtime.inspect was not read")
  end
  if #host.timers ~= 1 then
    error("exactly one keep-alive timer must be armed")
  end
  local status = plugin.status()
  if not status.open or status.section ~= "overview" then
    error("unexpected status after open")
  end
  if host.session.component.kind ~= "Column" then
    error("the panel root must be a Column")
  end
end

function M.second_toggle_closes_and_releases()
  local host, plugin = load()
  host:run("toggle_dashboard")
  if host:run("toggle_dashboard") ~= false then
    error("the second toggle must close the dashboard")
  end
  if host.session.active then
    error("the capture session must end")
  end
  if #host.releases ~= 1 or host.releases[1].reason ~= "cancelled" then
    error("release must be recorded as cancelled")
  end
  if #host.timers ~= 0 then
    error("the keep-alive timer must be cancelled")
  end
  if plugin.status().open then
    error("status must report closed")
  end
end

function M.open_fails_closed_without_the_focus_grant()
  local host, plugin = load({ grants = { "runtime.inspect" } })
  if host:run("toggle_dashboard") ~= false then
    error("a denied focus grant must not open")
  end
  if host.session ~= nil then
    error("no session may be created without the grant")
  end
  if plugin.status().error ~= "E_CAPABILITY_DENIED" then
    error("the denial must be reported, got " .. tostring(plugin.status().error))
  end
end

function M.open_fails_closed_in_safe_mode()
  local host, plugin = load({ safe_mode = true })
  if host:run("toggle_dashboard") ~= false then
    error("safe mode must not present the panel")
  end
  if plugin.status().error ~= "E_UI_UNAVAILABLE" then
    error("safe mode must report E_UI_UNAVAILABLE")
  end
end

function M.denied_inspect_still_presents_unavailable_sections()
  local host = load({
    inspect_error = { class = "runtime", code = "E_CAPABILITY_DENIED", message = "denied /home/tester/x" },
  })
  if host:run("toggle_dashboard") ~= true then
    error("the panel must open even when the snapshot is denied")
  end
  local rendered = lines(host:component())
  if string.find(rendered, "unavailable", 1, true) == nil then
    error("a denied snapshot must render an unavailable marker")
  end
  if string.find(rendered, "/home/tester", 1, true) ~= nil then
    error("a denied snapshot leaked a host path")
  end
end

function M.captured_keys_navigate_sections_and_rows()
  local host, plugin = load()
  host:run("toggle_dashboard", { height = 12 })
  host:push({ type = "key", text = "j" })
  host:deliver("overlay.input.available", { owner = "bitty-terminal.dashboard", queued = 1 })
  if plugin.status().offset ~= 1 then
    error("j did not move the row window")
  end
  host:push({ type = "key", text = "key:Tab" })
  host:deliver("overlay.input.available", {})
  if plugin.status().section ~= "plugins" then
    error("Tab did not change the section")
  end
  if plugin.status().offset ~= 0 then
    error("changing section must reset the offset")
  end
  local rendered = lines(host:component())
  if string.find(rendered, "2/6 Plugins", 1, true) == nil then
    error("the painted footer did not follow navigation")
  end
end

function M.wheel_events_scroll()
  local host, plugin = load()
  host:run("toggle_dashboard", { height = 12 })
  host:push({ type = "wheel", text = "wheel:LineDelta(0.0, 1.0)" })
  host:deliver("overlay.input.available", {})
  if plugin.status().offset ~= 3 then
    error("wheel did not scroll the section, got " .. plugin.status().offset)
  end
end

function M.q_and_escape_close_the_panel()
  local first_host, first_plugin = load()
  first_host:run("toggle_dashboard")
  first_host:push({ type = "key", text = "q" })
  first_host:deliver("overlay.input.available", {})
  if first_host.session.active then
    error("q must end the capture session")
  end
  if first_plugin.status().open then
    error("q must clear local state")
  end

  local second_host = load()
  second_host:run("toggle_dashboard")
  second_host:push({ type = "key", text = "key:Escape" })
  second_host:deliver("overlay.input.available", {})
  if second_host.session.active then
    error("Escape must end the capture session")
  end
end

function M.refresh_re_reads_the_snapshot()
  local host = load()
  host:run("toggle_dashboard")
  local before = host.inspect_calls
  host:push({ type = "key", text = "r" })
  host:deliver("overlay.input.available", {})
  if host.inspect_calls <= before then
    error("r must re-read runtime.inspect")
  end
end

function M.unbound_keys_do_not_repaint()
  local host = load()
  host:run("toggle_dashboard")
  local before = host.session.updates
  host:push({ type = "key", text = "z" })
  host:deliver("overlay.input.available", {})
  if host.session.updates ~= before then
    error("an unbound key must not repaint")
  end
end

function M.involuntary_release_clears_state()
  local host, plugin = load()
  host:run("toggle_dashboard")
  host:release_from_host("timeout")
  host:deliver("overlay.released", { owner = "bitty-terminal.dashboard", reason = "timeout" })
  if plugin.status().open then
    error("overlay.released must clear local state")
  end
  if #host.timers ~= 0 then
    error("the keep-alive timer must be cancelled")
  end
end

function M.foreign_release_is_ignored()
  local host, plugin = load()
  host:run("toggle_dashboard")
  host:deliver("overlay.released", { owner = "bitty-terminal.palette", reason = "cancelled" })
  if not plugin.status().open then
    error("another plugin's release must not close the dashboard")
  end
end

function M.poll_reports_a_released_session()
  local host, plugin = load()
  host:run("toggle_dashboard")
  host:release_from_host("focus_switched")
  host:deliver("overlay.input.available", {})
  if plugin.status().open then
    error("a released poll result must clear local state")
  end
end

function M.keepalive_polls_and_rearms()
  local host, plugin = load()
  host:run("toggle_dashboard")
  local polls_before = host.polls
  if host:advance(10000) < 1 then
    error("the keep-alive timer did not fire")
  end
  if host.polls <= polls_before then
    error("the keep-alive must poll to refresh the capture deadline")
  end
  if #host.timers ~= 1 then
    error("the keep-alive must re-arm itself")
  end
  plugin.close("cancelled")
  if #host.timers ~= 0 then
    error("closing must cancel the keep-alive")
  end
end

function M.layout_arguments_are_bounded()
  local host, plugin = load()
  host:run("toggle_dashboard", { width = 5000, height = -3 })
  local status = plugin.status()
  if status.width ~= 240 or status.height ~= 12 then
    error(string.format("layout was not clamped: %dx%d", status.width, status.height))
  end
end

function M.no_configuration_surface_is_touched()
  local host = load()
  host:run("toggle_dashboard")
  if host.bitty.settings ~= nil or host.bitty.config ~= nil then
    error("the mock host must not expose a configuration surface")
  end
  local rendered = lines(host:component())
  if string.find(rendered, "config.manage", 1, true) == nil then
    error("the read-only deferral must be visible in the UI")
  end
end

return M
