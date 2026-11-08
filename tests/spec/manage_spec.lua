-- End-to-end `config.manage` behavior against the in-process host stub:
-- preview/confirm/apply, stale digests, denied grants, plugin toggles, and
-- profile switches.

local MockHost = require("support.mock_host")
local snapshot = require("support.snapshot")

local M = {}

local function load(options)
  options = options or {}
  options.snapshot = options.snapshot or snapshot.full()
  if options.config == nil then
    options.config = true
  end
  local host = MockHost.new(options)
  _G.bitty = host.bitty
  package.loaded["dashboard.init"] = nil
  local plugin = require("dashboard.init")
  return host, plugin
end

local function press(host, text, data)
  host:push({ type = "key", text = text, data = data })
  host:deliver("overlay.input.available", {})
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

local function contains(haystack, needle)
  return string.find(haystack, needle, 1, true) ~= nil
end

-- Settings rows follow `config.KEYS`: 1 theme, 2 animations, 3 font.family,
-- 4 font.size, 5 opacity, 6 padding, 7 scrollback, 8 cursor_style, ...
local function select_setting(host, index)
  press(host, "4")
  for _ = 2, index do
    press(host, "j")
  end
end

function M.list_sections_load_lazily_on_their_tab()
  local host = load()
  host:run("toggle_dashboard")
  if host:count_calls("plugins.list") ~= 0 or host:count_calls("profiles.list") ~= 0 then
    error("opening the panel must not fetch list sections")
  end
  press(host, "2")
  if host:count_calls("plugins.list") ~= 1 then
    error("the plugins tab must fetch its list once")
  end
  if host:count_calls("profiles.list") ~= 0 then
    error("the plugins tab must not fetch profiles")
  end
  press(host, "5")
  if host:count_calls("profiles.list") ~= 1 then
    error("the profiles tab must fetch its list once")
  end
end

function M.setting_values_load_when_a_row_is_selected()
  local host = load()
  host:run("toggle_dashboard")
  press(host, "4")
  if host:count_calls("config.get") ~= 1 then
    error("opening Settings must read only the selected row")
  end
  if host:count_calls("config.sources") ~= 1 then
    error("the key list must come from one sources call")
  end
  press(host, "j")
  if host:count_calls("config.get") ~= 2 then
    error("moving the selection must read the new row")
  end
  press(host, "k")
  if host:count_calls("config.get") ~= 2 then
    error("a cached row must not be read twice")
  end
end

function M.an_unavailable_backend_keeps_the_read_only_panel()
  for _, code in ipairs({ "E_CONFIG_UNAVAILABLE", "E_CONFIG_UNSAFE" }) do
    local host, plugin = load({
      config_error = { class = "runtime", code = code, message = "no writable user layer" },
    })
    host:run("toggle_dashboard")
    press(host, "4")
    if plugin.status().manage then
      error(code .. " must not leave managed data")
    end
    if not plugin.status().blocked then
      error(code .. " must block the write surface")
    end
    if not contains(lines(host:component()), "Read-only") then
      error(code .. " must keep the read-only note")
    end
    if host:count_calls("config.set") ~= 0 then
      error(code .. " must not allow a write")
    end
  end
end

function M.settings_tab_renders_values_and_sources()
  local host, plugin = load()
  host:run("toggle_dashboard")
  select_setting(host, 1)
  if not plugin.status().manage then
    error("the managed settings tab did not load")
  end
  local rendered = lines(host:component())
  if not contains(rendered, 'appearance.theme = "default"') then
    error("the current value was not rendered")
  end
  if not contains(rendered, "font.family") or not contains(rendered, "user") then
    error("a source label was not rendered")
  end
  if not contains(rendered, "Enter edit") then
    error("the footer must advertise the edit key")
  end
  if contains(rendered, "read-only") then
    error("a granted panel must not claim to be read-only")
  end
end

function M.preview_then_confirm_applies_the_digest_bound_change()
  local host, plugin = load()
  host:run("toggle_dashboard")
  select_setting(host, 2)
  press(host, "key:Enter")

  local preview = host:last_call("config.preview")
  if preview == nil then
    error("the first Enter did not preview")
  end
  if preview.args[1] ~= "appearance.animations.enabled" or preview.args[2] ~= false then
    error("the preview intent is wrong")
  end
  if plugin.status().mode ~= "confirm" then
    error("the first Enter must wait for confirmation")
  end
  if host:count_calls("config.set") ~= 0 then
    error("the first Enter must not write")
  end
  if not contains(lines(host:component()), "Apply appearance.animations.enabled = false") then
    error("the confirm step did not render its intent")
  end

  press(host, "key:Enter")
  local applied = host:last_call("config.set")
  if applied == nil then
    error("the second Enter did not apply")
  end
  if applied.args[1] ~= "appearance.animations.enabled" or applied.args[2] ~= false then
    error("the applied change is wrong")
  end
  if applied.args[3] ~= host:last_issued().digest then
    error("the preview digest was not passed through")
  end
  if host.config_values["appearance.animations.enabled"].value ~= false then
    error("the staged value did not change")
  end
  local status = plugin.status()
  if status.mode ~= "browse" then
    error("apply must return to browsing")
  end
  if not contains(status.notice, "applied") then
    error("the applied notice is missing")
  end
  if host.config_values["appearance.animations.enabled"].source ~= "user" then
    error("the source did not move to the user layer")
  end
  if not contains(lines(host:component()), 'appearance.animations.enabled = false') then
    error("the panel did not re-render the applied value")
  end
end

function M.a_stale_digest_re_previews_before_the_second_apply()
  local host, plugin = load({ stale_once = true })
  host:run("toggle_dashboard")
  select_setting(host, 2)
  press(host, "key:Enter")
  press(host, "key:Enter")

  if host:count_calls("config.preview") ~= 2 then
    error("a stale apply must issue a fresh preview")
  end
  if plugin.status().mode ~= "confirm" then
    error("a stale apply must keep the confirm step")
  end
  if not contains(plugin.status().notice, "changed") then
    error("a stale apply must say the value changed")
  end

  press(host, "key:Enter")
  if host.config_values["appearance.animations.enabled"].value ~= false then
    error("the re-previewed change was not applied")
  end
  if host:last_call("config.set").args[3] ~= host:last_issued().digest then
    error("the fresh digest was not passed through")
  end
end

function M.a_denied_grant_keeps_the_read_only_panel()
  local host, plugin = load({ grants = { "runtime.inspect", "ui.overlay.focus" } })
  host:run("toggle_dashboard")
  local status = plugin.status()
  if status.manage then
    error("a denied grant must not produce managed data")
  end
  if not status.blocked then
    error("the denial must be recorded")
  end
  local rendered = lines(host:component())
  if not contains(rendered, "read-only") then
    error("the read-only title is missing")
  end
  if not contains(rendered, "config.manage") then
    error("the read-only note is missing")
  end

  select_setting(host, 2)
  press(host, "key:Enter")
  if #host.config_calls ~= 0 then
    error("no config.manage call may reach a denied host")
  end
  if not host.session.active then
    error("a denied grant must not close the panel")
  end
end

function M.a_mid_session_denial_drops_to_read_only()
  local host, plugin = load()
  host:run("toggle_dashboard")
  select_setting(host, 2)
  host:revoke("config.manage")
  press(host, "key:Enter")

  if plugin.status().manage then
    error("a denied write must drop the managed rendering")
  end
  if not plugin.status().blocked then
    error("the denial must be recorded")
  end
  if host:count_calls("config.set") ~= 0 then
    error("no write may be attempted after the denial")
  end
  if not contains(plugin.status().notice, "denied") then
    error("the denial notice is missing")
  end
end

function M.space_toggles_a_plugin_through_its_preview()
  local host, plugin = load()
  host:run("toggle_dashboard")
  press(host, "2")

  press(host, "key: ")
  local preview = host:last_call("config.preview_enabled")
  if preview == nil then
    error("space did not preview the toggle")
  end
  if preview.args[1] ~= "bitty-terminal.bar" or preview.args[2] ~= false then
    error("the toggle intent is wrong")
  end
  if plugin.status().mode ~= "confirm" then
    error("the toggle must wait for confirmation")
  end

  press(host, "key:Enter")
  local applied = host:last_call("config.set_enabled")
  if applied == nil then
    error("the confirm did not toggle the plugin")
  end
  if applied.args[3] ~= host:last_issued().digest then
    error("the toggle digest was not passed through")
  end
  if host:find_plugin("bitty-terminal.bar").enabled ~= false then
    error("the plugin was not disabled")
  end
  if not contains(plugin.status().notice, "disabled") then
    error("the toggle notice is missing")
  end
  if not contains(lines(host:component()), "bitty-terminal.bar") then
    error("the plugin row disappeared")
  end
end

function M.profile_use_reports_pending_restart()
  local host, plugin = load({ pending_restart = true })
  host:run("toggle_dashboard")
  press(host, "5")

  press(host, "key:Enter")
  local preview = host:last_call("profiles.preview_use")
  if preview == nil or preview.args[1] ~= "default" then
    error("the profile preview is wrong")
  end
  if plugin.status().mode ~= "confirm" then
    error("the profile switch must wait for confirmation")
  end

  press(host, "key:Enter")
  local applied = host:last_call("profiles.use")
  if applied == nil or applied.args[1] ~= "default" then
    error("the profile switch was not applied")
  end
  if applied.args[2] ~= host:last_issued().digest then
    error("the profile digest was not passed through")
  end
  if host:active_profile() ~= "default" then
    error("the active profile did not change")
  end
  if not contains(plugin.status().notice, "restart required") then
    error("pending_restart was not reported")
  end
  if not contains(lines(host:component()), "default (active)") then
    error("the profile rows did not re-render")
  end
end

function M.no_write_happens_without_a_prior_preview()
  local host, plugin = load()
  host:run("toggle_dashboard")

  -- Navigate every section and every row without pressing Enter.
  for section = 1, 6 do
    press(host, tostring(section))
    for _ = 1, 3 do
      press(host, "j")
    end
  end
  if host:count_calls("config.preview") ~= 0 or host:count_calls("config.set") ~= 0 then
    error("navigation must not preview or write")
  end

  -- Cancel a previewed change: the write is never attempted.
  select_setting(host, 2)
  press(host, "key:Enter")
  press(host, "key:Escape")
  if host:count_calls("config.set") ~= 0 then
    error("a cancelled preview must not write")
  end
  if plugin.status().mode ~= "browse" then
    error("Escape must return to browsing")
  end

  -- Every write in the call log follows its preview.
  local names = host:call_names()
  local last_preview = nil
  for index = 1, #names do
    if names[index] == "config.preview" then
      last_preview = index
    end
    if names[index] == "config.set" and (last_preview == nil or last_preview >= index) then
      error("a write ran without a prior preview")
    end
  end
end

function M.text_values_open_a_one_line_input()
  local host, plugin = load()
  host:run("toggle_dashboard")
  select_setting(host, 1)
  press(host, "key:Enter")
  if plugin.status().mode ~= "input" then
    error("Enter on a text setting must open the input")
  end
  if not contains(lines(host:component()), "appearance.theme = default") then
    error("the input was not seeded with the current value")
  end

  for _ = 1, #"default" do
    press(host, "key:Backspace")
  end
  local value = "dracula"
  for index = 1, #value do
    press(host, value:sub(index, index))
  end
  press(host, "key:Enter")
  local preview = host:last_call("config.preview")
  if preview == nil or preview.args[1] ~= "appearance.theme" or preview.args[2] ~= value then
    error("the typed value was not previewed")
  end
  press(host, "key:Enter")
  if host.config_values["appearance.theme"].value ~= value then
    error("the typed value was not applied")
  end
end

function M.a_bad_number_keeps_the_input_open()
  local host, plugin = load()
  host:run("toggle_dashboard")
  select_setting(host, 4)
  press(host, "key:Enter")
  for _ = 1, #"12.5" do
    press(host, "key:Backspace")
  end
  press(host, "n")
  press(host, "key:Enter")
  if plugin.status().mode ~= "input" then
    error("a bad number must keep the input open")
  end
  if not contains(plugin.status().notice, "finite number") then
    error("the parse problem was not shown")
  end
  if host:count_calls("config.preview") ~= 0 then
    error("a bad value must not be previewed")
  end
end

function M.enums_cycle_to_the_next_value()
  local host = load()
  host:run("toggle_dashboard")
  select_setting(host, 8)
  press(host, "key:Enter")
  local preview = host:last_call("config.preview")
  if preview == nil or preview.args[1] ~= "terminal.cursor_style" then
    error("the enum row did not preview")
  end
  if preview.args[2] ~= "default" then
    error("steady_bar must cycle to default, got " .. tostring(preview.args[2]))
  end
end

function M.refresh_re_reads_the_managed_values()
  local host = load()
  host:run("toggle_dashboard")
  select_setting(host, 1)
  local before = host:count_calls("config.get")
  press(host, "r")
  if host:count_calls("config.get") <= before then
    error("refresh must re-read the managed values")
  end
end

function M.enter_may_arrive_as_a_carriage_return()
  local host = load()
  host:run("toggle_dashboard")
  press(host, "4")
  press(host, "j")
  press(host, "\r")
  if host:count_calls("config.preview") ~= 1 then
    error("a CR-delivered Enter must preview")
  end
  press(host, "\r")
  if host:count_calls("config.set") ~= 1 then
    error("a CR-delivered Enter must apply")
  end
end

function M.an_older_host_keeps_the_original_read_only_rendering()
  local host, plugin = load({ config = false })
  host:run("toggle_dashboard")
  press(host, "4")
  local rendered = lines(host:component())
  if plugin.status().manage then
    error("a host without the surface must not report managed data")
  end
  if not contains(rendered, "Read-only") then
    error("the read-only note is missing")
  end
  if contains(rendered, "Enter edit") then
    error("an older host must not advertise editing")
  end
  if not contains(rendered, "j/k row · h/l section · r refresh · q close") then
    error("the original footer text changed")
  end
  press(host, "key:Enter")
  if #host.config_calls ~= 0 then
    error("no write may be attempted without the surface")
  end
end

function M.profile_create_clone_rename_and_delete_flow()
  local host, plugin = load()
  host:run("toggle_dashboard")
  press(host, "5")

  -- 1. Create a new profile ("n" -> type "dev" -> Enter to preview -> Enter to create).
  press(host, "n")
  if plugin.status().mode ~= "input" then
    error("n on Profiles must open the create input")
  end
  for index = 1, #"dev" do
    press(host, ("dev"):sub(index, index))
  end
  press(host, "key:Enter")
  local create_preview = host:last_call("profiles.preview_create")
  if create_preview == nil or create_preview.args[1] ~= "dev" then
    error("create did not call profiles.preview_create")
  end
  if plugin.status().mode ~= "confirm" then
    error("create preview must enter confirm mode")
  end
  if not contains(lines(host:component()), "Create profile dev") then
    error("confirm view did not show Create profile dev")
  end
  press(host, "key:Enter")
  local created = host:last_call("profiles.create")
  if created == nil or created.args[1] ~= "dev" or created.args[2] ~= host:last_issued().digest then
    error("create did not pass the preview digest to profiles.create")
  end
  if host:find_profile("dev") == nil then
    error("dev profile was not added to host")
  end
  if not contains(plugin.status().notice or "", "created profile dev") then
    error("create notice missing: " .. tostring(plugin.status().notice))
  end

  -- 2. Clone the selected "dev" profile ("c" -> seeded "dev-copy" -> Enter -> Enter).
  press(host, "c")
  if plugin.status().mode ~= "input" then
    error("c on Profiles must open the clone input")
  end
  if not contains(lines(host:component()), "clone dev as = dev-copy") then
    error("clone input was not seeded with dev-copy")
  end
  press(host, "key:Enter")
  local clone_preview = host:last_call("profiles.preview_clone")
  if clone_preview == nil or clone_preview.args[1] ~= "dev" or clone_preview.args[2] ~= "dev-copy" then
    error("clone did not call profiles.preview_clone(dev, dev-copy)")
  end
  if plugin.status().mode ~= "confirm" then
    error("clone preview must enter confirm mode")
  end
  press(host, "key:Enter")
  local cloned = host:last_call("profiles.clone")
  if
    cloned == nil
    or cloned.args[1] ~= "dev"
    or cloned.args[2] ~= "dev-copy"
    or cloned.args[3] ~= host:last_issued().digest
  then
    error("clone did not pass the preview digest to profiles.clone")
  end
  if host:find_profile("dev-copy") == nil then
    error("dev-copy profile was not added to host")
  end

  -- 3. Rename "dev-copy" to "staging" ("e" -> replace seed -> Enter -> Enter).
  press(host, "e")
  if plugin.status().mode ~= "input" then
    error("e on Profiles must open the rename input")
  end
  for _ = 1, #"dev-copy" do
    press(host, "key:Backspace")
  end
  for index = 1, #"staging" do
    press(host, ("staging"):sub(index, index))
  end
  press(host, "key:Enter")
  local rename_preview = host:last_call("profiles.preview_rename")
  if rename_preview == nil or rename_preview.args[1] ~= "dev-copy" or rename_preview.args[2] ~= "staging" then
    error("rename did not call profiles.preview_rename(dev-copy, staging)")
  end
  press(host, "key:Enter")
  local renamed = host:last_call("profiles.rename")
  if
    renamed == nil
    or renamed.args[1] ~= "dev-copy"
    or renamed.args[2] ~= "staging"
    or renamed.args[3] ~= host:last_issued().digest
  then
    error("rename did not pass the preview digest to profiles.rename")
  end
  if host:find_profile("staging") == nil or host:find_profile("dev-copy") ~= nil then
    error("rename did not update host profile rows")
  end

  -- 4. Delete "staging" ("d" -> preview -> Enter to delete).
  press(host, "d")
  local delete_preview = host:last_call("profiles.preview_delete")
  if delete_preview == nil or delete_preview.args[1] ~= "staging" then
    error("d did not call profiles.preview_delete(staging)")
  end
  if plugin.status().mode ~= "confirm" then
    error("d must enter confirm mode")
  end
  if not contains(lines(host:component()), "Delete profile staging") then
    error("confirm view did not show Delete profile staging")
  end
  press(host, "key:Enter")
  local deleted = host:last_call("profiles.delete")
  if deleted == nil or deleted.args[1] ~= "staging" or deleted.args[2] ~= host:last_issued().digest then
    error("delete did not pass the preview digest to profiles.delete")
  end
  if host:find_profile("staging") ~= nil then
    error("staging profile was not removed from host")
  end
  if not contains(plugin.status().notice or "", "deleted profile staging") then
    error("delete notice missing: " .. tostring(plugin.status().notice))
  end
end

function M.profile_lifecycle_gracefully_degrades_on_switch_only_host()
  local host, plugin = load({ profile_lifecycle = false })
  host:run("toggle_dashboard")
  press(host, "5")

  -- A host with `profiles.list`/`preview_use`/`use` but without `preview_create`
  -- keeps the Profiles tab editable for switching and reports a non-blocking
  -- notice when lifecycle keys are pressed.
  for _, key_text in ipairs({ "n", "c", "e", "d" }) do
    press(host, key_text)
    if not plugin.status().manage or plugin.status().blocked then
      error("missing lifecycle verbs must not block config.manage")
    end
    if not contains(plugin.status().notice or "", "unavailable on this host") then
      error("missing lifecycle verb must report graceful fallback notice for " .. key_text)
    end
  end

  -- Switching active profile with Enter still works cleanly.
  press(host, "key:Enter")
  if plugin.status().mode ~= "confirm" then
    error("Enter must still preview profile switch on a switch-only host")
  end
  press(host, "key:Enter")
  if host:active_profile() ~= "default" then
    error("Enter must still apply profile switch on a switch-only host")
  end
end

return M
