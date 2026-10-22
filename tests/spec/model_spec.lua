-- Section order, row shaping, layout paging, and bounded navigation.

local inspect = require("dashboard.inspect")
local model = require("dashboard.model")
local snapshot = require("support.snapshot")

local M = {}

local function key(text_value, data)
  return { type = "key", text = text_value, data = data }
end

function M.sections_are_ordered_and_named()
  local expected = { "overview", "plugins", "extensions", "settings", "profiles", "diagnostics" }
  if #model.SECTIONS ~= #expected then
    error("unexpected section count")
  end
  for index = 1, #expected do
    if model.SECTIONS[index].id ~= expected[index] then
      error("section " .. index .. " is " .. model.SECTIONS[index].id)
    end
  end
  if model.section_index("settings") ~= 4 then
    error("section ids must resolve to their index")
  end
end

function M.page_size_tracks_layout()
  if model.page_size(24) ~= 18 then
    error("80x24 must show 18 rows, got " .. model.page_size(24))
  end
  if model.page_size(40) ~= 20 then
    error("120x40 must cap at 20 rows, got " .. model.page_size(40))
  end
  if model.page_size(12) ~= 6 then
    error("the minimum layout must still show rows, got " .. model.page_size(12))
  end
end

function M.window_clamps_to_last_page()
  local first, last = model.window(5, 99, 10)
  if first ~= 1 or last ~= 5 then
    error("a short list must render one page")
  end
  first, last = model.window(40, 99, 10)
  if first ~= 31 or last ~= 40 then
    error("the last page must end on the last row: " .. first .. "-" .. last)
  end
end

function M.builds_every_section()
  local data = inspect.normalize(snapshot.full())
  for index = 1, #model.SECTIONS do
    local view = model.build(data, { index = index, offset = 0 }, { height = 24 })
    if #view.rows == 0 then
      error(view.section.id .. " produced no rows")
    end
    if view.unavailable ~= nil then
      error(view.section.id .. " unexpectedly unavailable")
    end
    if view.page ~= 18 then
      error(view.section.id .. " has the wrong page size")
    end
  end
end

function M.overview_counts_sections()
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = 1, offset = 0 }, { height = 24 })
  local plain = {}
  for index = 1, #view.rows do
    plain[#plain + 1] = view.rows[index].text
  end
  local joined = table.concat(plain, "\n")
  for _, needle in ipairs({
    "Runtime: 0.0.26",
    "Profile: work (env)",
    "Theme: default",
    "Plugins: 3",
    "2 enabled",
    "Extensions: 2",
    "1 ABI compatible",
    "Profiles: 2",
    "active work",
    "Read-only",
  }) do
    if string.find(joined, needle, 1, true) == nil then
      error("overview is missing: " .. needle .. "\n" .. joined)
    end
  end
end

function M.unavailable_sections_render_a_marker()
  local data = inspect.normalize(snapshot.unavailable())
  for index = 2, #model.SECTIONS do
    local view = model.build(data, { index = index, offset = 0 }, { height = 24 })
    if view.unavailable ~= "source unavailable" then
      error("section " .. index .. " lost its reason")
    end
    if view.rows[1].text ~= "unavailable: source unavailable" then
      error("section " .. index .. " must render unavailable: <reason>")
    end
  end
end

function M.empty_sections_render_empty_states()
  local data = inspect.normalize(snapshot.empty())
  local expectations = {
    [2] = "No plugins reported by the host.",
    [3] = "No extensions installed.",
    [4] = "No declared settings rows.",
    [5] = "No profiles defined.",
  }
  for index, expected in pairs(expectations) do
    local view = model.build(data, { index = index, offset = 0 }, { height = 24 })
    if view.empty ~= true then
      error("section " .. index .. " must report an empty state")
    end
    if view.rows[1].text ~= expected then
      error("section " .. index .. " empty text: " .. view.rows[1].text)
    end
  end
end

function M.settings_carry_the_read_only_note()
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = model.section_index("settings"), offset = 0 }, { height = 24 })
  if view.note ~= model.READ_ONLY_NOTE then
    error("settings must state that editing is deferred")
  end
  if string.find(view.note, "config.manage", 1, true) == nil then
    error("the note must name the blocking capability")
  end
end

function M.extension_rows_use_extension_terminology()
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = model.section_index("extensions"), offset = 0 }, { height = 24 })
  if view.section.title ~= "Extensions" then
    error("the section must be named Extensions")
  end
  local joined = table.concat({ view.rows[1].text, view.rows[2].text }, "\n")
  if string.find(joined, "kitty-graphics", 1, true) == nil then
    error("extension name missing")
  end
  if string.find(joined, "ABI compatible", 1, true) == nil then
    error("ABI state missing")
  end
  -- The host records an activation refusal class verbatim; everything the
  -- dashboard writes itself must say "extensions", never "components".
  for index = 1, model.section_count() do
    local section = model.build(data, { index = index, offset = 0 }, { height = 24 })
    for row_index = 1, #section.rows do
      local line = string.lower(section.rows[row_index].text)
      if string.find(line, "component", 1, true) ~= nil and string.find(line, "component_untrusted", 1, true) == nil then
        error("dashboard prose used 'component': " .. section.rows[row_index].text)
      end
    end
  end
end

function M.key_navigation_is_bounded()
  local state = model.new_state()
  local opts = { row_count = 40, page = 10 }

  state = model.apply_key(state, key("j"), opts)
  if state.offset ~= 1 then
    error("j must move one row")
  end
  state = model.apply_key(state, key("k"), opts)
  if state.offset ~= 0 then
    error("k must move back")
  end
  state = model.apply_key(state, key("k"), opts)
  if state.offset ~= 0 then
    error("k must clamp at the first row")
  end
  state = model.apply_key(state, key("key:End"), opts)
  if state.offset ~= 30 then
    error("End must land on the last page, got " .. state.offset)
  end
  state = model.apply_key(state, key("j"), opts)
  if state.offset ~= 30 then
    error("j must clamp at the last page")
  end
  state = model.apply_key(state, key("g"), opts)
  if state.offset ~= 0 then
    error("g must return to the first row")
  end
  state = model.apply_key(state, key("key:PageDown"), opts)
  if state.offset ~= 10 then
    error("PageDown must move one page")
  end
end

function M.section_navigation_wraps()
  local state = model.new_state()
  local opts = { row_count = 5, page = 5 }

  state = model.apply_key(state, key("key:Tab"), opts)
  if state.index ~= 2 then
    error("Tab must move to the next section")
  end
  state = model.apply_key(state, key("l"), opts)
  if state.index ~= 3 then
    error("l must move to the next section")
  end
  state = model.apply_key(state, key("h"), opts)
  if state.index ~= 2 then
    error("h must move to the previous section")
  end
  state = model.apply_key(state, key("key:Tab", { shift = true }), opts)
  if state.index ~= 1 then
    error("Shift+Tab must move to the previous section")
  end
  state = model.apply_key(state, key("key:Tab", { shift = true }), opts)
  if state.index ~= model.section_count() then
    error("previous from the first section must wrap to the last")
  end
  state = model.apply_key(state, key("4"), opts)
  if state.index ~= 4 then
    error("a digit must select its section")
  end
  state = model.apply_key(state, key("9"), opts)
  if state.index ~= 4 then
    error("an out-of-range digit must be ignored")
  end
end

function M.section_change_resets_the_offset()
  local state = { index = 1, offset = 10 }
  state = model.apply_key(state, key("key:Tab"), { row_count = 40, page = 10 })
  if state.offset ~= 0 then
    error("changing section must reset the row offset")
  end
end

function M.close_and_refresh_actions()
  local state = model.new_state()
  local _, action = model.apply_key(state, key("q"), { row_count = 5, page = 5 })
  if action ~= model.ACTION_CLOSE then
    error("q must close")
  end
  _, action = model.apply_key(state, key("key:Escape"), { row_count = 5, page = 5 })
  if action ~= model.ACTION_CLOSE then
    error("Escape must close")
  end
  _, action = model.apply_key(state, key("r"), { row_count = 5, page = 5 })
  if action ~= model.ACTION_REFRESH then
    error("r must refresh")
  end
  local next_state, action2, changed = model.apply_key(state, key("z"), { row_count = 5, page = 5 })
  if action2 ~= model.ACTION_NONE or changed or next_state.index ~= state.index then
    error("an unbound key must be swallowed")
  end
end

function M.unknown_events_are_ignored()
  local state = model.new_state()
  local next_state, action, changed = model.apply_key(state, { type = "pointer", text = "Left:Pressed" }, {})
  if next_state ~= state or action ~= model.ACTION_NONE or changed then
    error("pointer events must be ignored")
  end
  next_state, action, changed = model.apply_key(state, nil, {})
  if next_state ~= state or action ~= model.ACTION_NONE or changed then
    error("nil events must be ignored")
  end
end

function M.wheel_uses_the_signed_y_component()
  local opts = { row_count = 40, page = 10 }
  local function at(offset, text_value)
    return model.apply_wheel({ index = 1, offset = offset }, { type = "wheel", text = text_value }, opts).offset
  end
  -- Core sends the platform delta as `wheel:Lines(x, y)`; positive y is wheel
  -- up, so the window moves toward row 1 (a negative offset movement).
  if at(5, "wheel:Lines(0,1)") ~= 4 then
    error("Lines(0,1) must scroll up one row, got " .. at(5, "wheel:Lines(0,1)"))
  end
  if at(5, "wheel:Lines(0.0, 1.0)") ~= 4 then
    error("the Debug-formatted Lines payload must parse identically")
  end
  if at(5, "wheel:Lines(0,-1)") ~= 6 then
    error("Lines(0,-1) must scroll down one row")
  end
  -- A pixel delta carries direction only; y=2 is still wheel up.
  if at(5, "wheel:Pixels(-1,2)") ~= 2 then
    error("Pixels(-1,2) must scroll up one bounded step")
  end
  if at(5, "wheel:Pixels(0.0, -42.5)") ~= 8 then
    error("a negative pixel delta must scroll down one bounded step")
  end
  -- A line magnitude is honoured inside the bounded step (positive y = up).
  if at(10, "wheel:Lines(0,4)") ~= 6 then
    error("Lines(0,4) must scroll up four rows, got " .. at(10, "wheel:Lines(0,4)"))
  end
  if at(20, "wheel:Lines(0,9)") ~= 15 then
    error("a line magnitude must clamp to five rows, got " .. at(20, "wheel:Lines(0,9)"))
  end
  -- Zero and malformed payloads never move the window.
  for _, raw in ipairs({ "wheel:Lines(0,0)", "wheel:garbage", "wheel:LineDelta(0.0, 1.0)" }) do
    if at(5, raw) ~= 5 then
      error("malformed or zero wheel payload moved the offset: " .. raw)
    end
  end
end

function M.overlong_rows_stay_bounded()
  local data = inspect.normalize(snapshot.overlong())
  local view = model.build(data, { index = model.section_index("plugins"), offset = 0 }, { height = 24 })
  if #view.rows[1].text > 400 then
    error("an overlong plugin row was not bounded: " .. #view.rows[1].text)
  end
  local settings = model.build(data, { index = model.section_index("settings"), offset = 0 }, { height = 24 })
  if string.find(settings.rows[1].text, string.rep("value value", 40), 1, true) ~= nil then
    error("an overlong setting value was not bounded")
  end
end

return M
