-- Declarative scene construction at the two supported layouts.

local inspect = require("dashboard.inspect")
local model = require("dashboard.model")
local render = require("dashboard.render")
local snapshot = require("support.snapshot")

local M = {}

local ALLOWED = { Text = true, Row = true, Column = true, List = true }

local function walk(component, visit)
  visit(component)
  for index = 1, #(component.children or {}) do
    walk(component.children[index], visit)
  end
end

local function assert_component(component)
  walk(component, function(node)
    if ALLOWED[node.kind] ~= true then
      error("unexpected node kind: " .. tostring(node.kind))
    end
    if node.kind == "Text" and type(node.text) ~= "string" then
      error("Text nodes must carry a string")
    end
  end)
end

local function frame(index, opts)
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = index, offset = 0 }, opts or { height = 24 })
  view.offset = 0
  return render.scene(view, opts or { width = 80, height = 24 })
end

local function assert_width(component, width)
  walk(component, function(node)
    if node.kind == "Text" and #node.text > width then
      error(string.format("text exceeds %d columns (%d): %q", width, #node.text, node.text))
    end
  end)
end

-- Mirrors Core's `overlay_scene_rows`: a `Column`/`List` root paints one row
-- per DIRECT child and flattens each child horizontally. Nested groups never
-- add a row — the exact behavior a recursive walk would hide.
local function flatten_child(node)
  local parts = {}
  local function collect(item)
    if item.kind == "Text" then
      parts[#parts + 1] = item.text
      return
    end
    for index = 1, #(item.children or {}) do
      collect(item.children[index])
    end
  end
  collect(node)
  return table.concat(parts)
end

local function core_rows(component)
  local rows = {}
  for index = 1, #(component.children or {}) do
    rows[#rows + 1] = flatten_child(component.children[index])
  end
  return rows
end

function M.every_section_renders_at_80x24()
  for index = 1, model.section_count() do
    local component = frame(index, { width = 80, height = 24 })
    assert_component(component)
    assert_width(component, 80)
    if component.kind ~= "List" then
      error("the overlay root must be a List, got " .. tostring(component.kind))
    end
    local rows = core_rows(component)
    -- title + tabs + rule + at least one content row + footer.
    if #rows < 5 then
      error("section " .. index .. " rendered no content rows")
    end
    if #rows > 3 + model.page_size(24) + 2 then
      error("section " .. index .. " overflows the 24-line layout")
    end
    local lines = render.lines(component)
    if string.find(lines[1], "Dashboard", 1, true) == nil then
      error("missing title row")
    end
    if string.find(lines[1], "read-only", 1, true) == nil then
      error("title must state that the dashboard is read-only")
    end
  end
end

function M.every_section_renders_at_120x40()
  for index = 1, model.section_count() do
    local component = frame(index, { width = 120, height = 40 })
    assert_component(component)
    assert_width(component, 120)
    local rows = core_rows(component)
    if #rows < 5 or #rows > 3 + model.page_size(40) + 2 then
      error("section " .. index .. " row count is out of bounds at 120x40")
    end
  end
end

function M.overlay_direct_children_are_separate_rows()
  -- Core stacks only a root List/Column's direct children. A nested List would
  -- collapse every content row into one line, so this mirrors the host's
  -- flattening (not a recursive line walk) and checks the rows individually.
  local index = model.section_index("plugins")
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = index, offset = 0 }, { height = 24 })
  view.offset = 0
  local component = render.scene(view, { width = 80, height = 24 })
  local rows = core_rows(component)
  local expected = 3 + #view.rows + 1 -- title, tabs, rule, content, footer
  if #rows ~= expected then
    error(string.format("expected %d painted rows, got %d", expected, #rows))
  end
  if string.find(rows[2], "Overview", 1, true) == nil or string.find(rows[2], "Diagnostics", 1, true) == nil then
    error("the tabs Row must flatten onto exactly one painted row: " .. rows[2])
  end
  if string.find(rows[2], "│", 1, true) == nil then
    error("the tab separator must join cells on the same row")
  end
  if rows[3] ~= string.rep(render.RULE_GLYPH, 80) then
    error("the rule must be its own row")
  end
  -- The first plugin content row is addressable on its own, not fused with
  -- its neighbours or with the footer.
  if string.find(rows[4], "v0.0.1", 1, true) == nil then
    error("the first content row is not separately addressable: " .. rows[4])
  end
  if string.find(rows[4], "Unified Bar", 1, true) ~= nil then
    error("multiple content rows collapsed into one painted row")
  end
  if string.find(rows[#rows], "q close", 1, true) == nil then
    error("the footer must be its own final row")
  end
end

function M.tab_strip_names_all_sections()
  local lines = render.lines(frame(1))
  local joined = table.concat(lines, "\n")
  for _, section in ipairs(model.SECTIONS) do
    if string.find(joined, section.title, 1, true) == nil then
      error("tab strip is missing " .. section.title)
    end
  end
end

function M.narrow_layout_collapses_the_tab_strip()
  local component = frame(1, { width = 40, height = 12 })
  local lines = render.lines(component)
  if string.find(lines[1], "Dashboard", 1, true) == nil then
    error("narrow layout lost the title")
  end
  local collapsed = false
  for _, line in ipairs(lines) do
    if string.find(line, "1/6 Overview", 1, true) ~= nil then
      collapsed = true
    end
  end
  if not collapsed then
    error("narrow layout must collapse the tab strip to the active section")
  end
  assert_width(component, 40)
end

function M.unavailable_sections_are_explicit()
  local data = inspect.normalize(snapshot.unavailable())
  for index = 2, model.section_count() do
    local view = model.build(data, { index = index, offset = 0 }, { height = 24 })
    view.offset = 0
    local component = render.scene(view, { width = 80, height = 24 })
    local joined = table.concat(render.lines(component), "\n")
    if string.find(joined, "unavailable: source unavailable", 1, true) == nil then
      error("section " .. index .. " must render the unavailable marker")
    end
  end
end

function M.empty_sections_render_an_explicit_state()
  local data = inspect.normalize(snapshot.empty())
  local view = model.build(data, { index = model.section_index("plugins"), offset = 0 }, { height = 24 })
  view.offset = 0
  local component = render.scene(view, { width = 80, height = 24 })
  local joined = table.concat(render.lines(component), "\n")
  if string.find(joined, "No plugins reported", 1, true) == nil then
    error("empty state must be explicit")
  end
end

function M.settings_section_states_read_only()
  local component = frame(model.section_index("settings"))
  local joined = table.concat(render.lines(component), "\n")
  if string.find(joined, "Read-only", 1, true) == nil then
    error("settings must render the read-only banner")
  end
  if string.find(joined, "config.manage", 1, true) == nil then
    error("settings must name config.manage as the blocker")
  end
end

function M.no_host_paths_or_commands_leak()
  -- The staged snapshot carries absolute paths in diagnostics, extension
  -- executables, and setting values; none may reach a rendered Text node.
  local component = frame(model.section_index("diagnostics"))
  local joined = table.concat(render.lines(component), "\n")
  for _, needle in ipairs({ "/home/", "tester", "/usr/", ".local", "\\" }) do
    if string.find(joined, needle, 1, true) ~= nil then
      error("diagnostics leaked: " .. needle)
    end
  end
  for _, section in ipairs({ "extensions", "settings", "plugins" }) do
    local other = table.concat(render.lines(frame(model.section_index(section))), "\n")
    for _, needle in ipairs({ "/home/", "/usr/", "bitty-terminal.dashboard:toggle_dashboard" }) do
      if string.find(other, needle, 1, true) ~= nil then
        error(section .. " leaked: " .. needle)
      end
    end
  end
end

function M.overlong_rows_truncate_to_the_declared_width()
  local data = inspect.normalize(snapshot.overlong())
  local view = model.build(data, { index = model.section_index("plugins"), offset = 0 }, { height = 24 })
  view.offset = 0
  local component = render.scene(view, { width = 80, height = 24 })
  assert_width(component, 80)
  local longest = 0
  walk(component, function(node)
    if node.kind == "Text" then
      longest = math.max(longest, #node.text)
    end
  end)
  if longest ~= 80 then
    error("the overlong row must fill and truncate at the declared width, got " .. longest)
  end
end

function M.footer_reports_the_window()
  local data = inspect.normalize(snapshot.full())
  local view = model.build(data, { index = model.section_index("plugins"), offset = 1 }, { height = 24 })
  view.offset = 1
  local component = render.scene(view, { width = 80, height = 24 })
  local lines = render.lines(component)
  local footer = lines[#lines]
  if string.find(footer, "2/6 Plugins", 1, true) == nil then
    error("footer must name the active section: " .. footer)
  end
  if string.find(footer, "q close", 1, true) == nil then
    error("footer must advertise the close key")
  end
end

function M.node_budget_is_small()
  local component = frame(1, { width = 120, height = 40 })
  local count = 0
  walk(component, function()
    count = count + 1
  end)
  if count > 60 then
    error("component is larger than expected: " .. count)
  end
end

return M
