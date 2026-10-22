-- Pure view model for the Dashboard (bitty-terminal.dashboard).
--
-- `build` turns one normalized `runtime.inspect()` snapshot into the bounded
-- rows of one section; `apply_key` and `apply_wheel` own navigation. Nothing
-- here touches the host: key handling and row shaping are unit-testable
-- without a plugin VM.
--
-- Section order is the user-visible contract: Overview, Plugins, Extensions,
-- Settings, Profiles, Diagnostics. "Extensions" names the installable
-- artifacts; the word "components" never appears in user-facing text.

local text = require("dashboard.text")

local M = {}

M.SECTIONS = {
  { id = "overview", title = "Overview" },
  { id = "plugins", title = "Plugins" },
  { id = "extensions", title = "Extensions" },
  { id = "settings", title = "Settings" },
  { id = "profiles", title = "Profiles" },
  { id = "diagnostics", title = "Diagnostics" },
}

M.DEFAULT_PAGE = 10
M.MAX_PAGE = 20
M.MIN_PAGE = 3

M.READ_ONLY_NOTE = "Read-only: settings editing is deferred until config.manage (bitty#2393)."
M.OVERVIEW_NOTE = "Read-only. Settings editing is deferred until config.manage (bitty#2393)."

M.ACTION_NONE = "none"
M.ACTION_CLOSE = "close"
M.ACTION_REFRESH = "refresh"

-- Wheel policy: a line-delta tick moves up to `WHEEL_MAX_STEP` rows, and a
-- pixel delta (which carries no row unit) moves the bounded default step.
M.WHEEL_STEP = 3
M.WHEEL_MAX_STEP = 5

-- One empty navigation state, anchored on the first section.
function M.new_state()
  return { index = 1, offset = 0 }
end

function M.section_count()
  return #M.SECTIONS
end

function M.section(index)
  local position = text.clamp_int(index, 1, 1, #M.SECTIONS)
  return M.SECTIONS[position]
end

-- Resolve a section id to its index; nil for an unknown id.
function M.section_index(id)
  for index = 1, #M.SECTIONS do
    if M.SECTIONS[index].id == id then
      return index
    end
  end
  return nil
end

local function row(text_value, dim)
  return { text = text_value, dim = dim == true }
end

-- Visible page size for a declared layout height. Chrome rows: title, tabs,
-- rule, footer, and the optional read-only note. Kept in one place so the
-- renderer and the navigation clamp agree exactly.
M.CHROME_ROWS = 6

function M.page_size(height)
  local bounded = text.clamp_int(height, text.DEFAULT_HEIGHT, text.MIN_HEIGHT, text.MAX_HEIGHT)
  return text.clamp_int(bounded - M.CHROME_ROWS, M.DEFAULT_PAGE, M.MIN_PAGE, M.MAX_PAGE)
end

-- Clamp an offset so the last page ends exactly on the last row.
function M.clamp_offset(offset, row_count, page)
  local bounded_page = text.clamp_int(page, M.DEFAULT_PAGE, 1, M.MAX_PAGE)
  local maximum = row_count - bounded_page
  if maximum < 0 then
    maximum = 0
  end
  return text.clamp_int(offset, 0, 0, maximum)
end

-- 1-based inclusive window `first, last` for one page.
function M.window(row_count, offset, page)
  if row_count <= 0 then
    return 1, 0
  end
  local bounded_page = text.clamp_int(page, M.DEFAULT_PAGE, 1, M.MAX_PAGE)
  local first = M.clamp_offset(offset, row_count, bounded_page) + 1
  local last = first + bounded_page - 1
  if last > row_count then
    last = row_count
  end
  return first, last
end

local function availability_word(section)
  if section == nil then
    return "missing"
  end
  if section.kind == "unavailable" then
    return "unavailable"
  end
  return "available"
end

local function join(parts)
  local kept = {}
  for index = 1, #parts do
    local part = parts[index]
    if type(part) == "string" and part ~= "" then
      kept[#kept + 1] = part
    end
  end
  return table.concat(kept, " · ")
end

local function path_row(label, entry)
  if entry == nil or entry.present ~= true then
    return row(label .. ": missing", true)
  end
  return row(label .. ": present · " .. entry.label)
end

local function decoration_label(decoration)
  if type(decoration) ~= "table" then
    return ""
  end
  return join({
    "gaps " .. text.field(decoration.gaps_in) .. "/" .. text.field(decoration.gaps_out),
    "border " .. text.field(decoration.border),
    "radius " .. text.field(decoration.radius),
    "inset " .. text.field(decoration.content_inset),
  })
end

local function profile_label(diagnostics)
  local name = diagnostics.profile
  local source = diagnostics.profile_source
  if name == nil or name == "" then
    return "none" .. (source ~= "" and (" (" .. source .. ")") or "")
  end
  return name .. (source ~= "" and (" (" .. source .. ")") or "")
end

local function overview_rows(data)
  local rows = {}
  local diagnostics = data.diagnostics
  if diagnostics.kind == "unavailable" then
    rows[#rows + 1] = row("unavailable: " .. diagnostics.reason, true)
  else
    local value = diagnostics.value
    rows[#rows + 1] = row("Runtime: " .. (value.app_version ~= "" and value.app_version or "unknown"))
    rows[#rows + 1] = row("Profile: " .. profile_label(value))
    rows[#rows + 1] = row(join({ "Theme: " .. (value.theme ~= "" and value.theme or "unknown"), value.theme_source }))
    rows[#rows + 1] = row(join({
      "Font: " .. (value.font_family ~= "" and value.font_family or "unknown"),
      value.font_size ~= nil and (text.field(value.font_size) .. " pt") or "",
    }))
    rows[#rows + 1] = row("Decoration: " .. decoration_label(value.decoration))
  end

  local function count_row(label, section, suffix)
    if section == nil or section.kind == "unavailable" then
      rows[#rows + 1] = row(label .. ": " .. availability_word(section), true)
      return
    end
    local total = #section.rows
    local extra = suffix ~= nil and suffix(section.rows) or ""
    local line = label .. ": " .. string.format("%d", total)
    if extra ~= "" then
      line = line .. " · " .. extra
    end
    if section.truncated then
      line = line .. " · truncated"
    end
    rows[#rows + 1] = row(line)
  end

  count_row("Plugins", data.plugins, function(rows_in)
    local enabled = 0
    for index = 1, #rows_in do
      if rows_in[index].enabled then
        enabled = enabled + 1
      end
    end
    return string.format("%d enabled", enabled)
  end)
  count_row("Extensions", data.extensions, function(rows_in)
    local compatible = 0
    for index = 1, #rows_in do
      if rows_in[index].abi_compatible then
        compatible = compatible + 1
      end
    end
    return string.format("%d ABI compatible", compatible)
  end)
  count_row("Settings rows", data.settings)
  count_row("Profiles", data.profiles, function(rows_in)
    for index = 1, #rows_in do
      if rows_in[index].active then
        return "active " .. rows_in[index].name
      end
    end
    return ""
  end)

  rows[#rows + 1] = row(M.OVERVIEW_NOTE, true)
  return rows
end

local function plugin_rows(section)
  local rows = {}
  for index = 1, #section.rows do
    local item = section.rows[index]
    local name = item.name ~= "" and item.name or item.id
    rows[#rows + 1] = row(join({
      name,
      item.version ~= "" and ("v" .. item.version) or "",
      item.source,
      item.enabled and "enabled" or "disabled",
      not item.recorded and "unrecorded" or "",
    }))
  end
  return rows
end

local function extension_rows(section)
  local rows = {}
  for index = 1, #section.rows do
    local item = section.rows[index]
    local digest = item.digest
    if #digest > 24 then
      digest = string.sub(digest, 1, 24) .. text.ELLIPSIS
    end
    rows[#rows + 1] = row(join({
      item.name,
      item.version ~= "" and ("v" .. item.version) or "",
      item.tier,
      item.abi_compatible and "ABI compatible" or "ABI mismatch",
      item.activation,
      item.trust,
      digest ~= "" and digest or "",
      item.executable ~= nil and ("exe " .. item.executable) or "",
    }))
  end
  return rows
end

local function setting_rows(section)
  local rows = {}
  for index = 1, #section.rows do
    local item = section.rows[index]
    local key = item.plugin_id ~= "" and (item.plugin_id .. "." .. item.key) or item.key
    local value = item.current
    if value == "" then
      value = "(empty)"
    end
    rows[#rows + 1] = row(join({
      key .. " = " .. value,
      item.default ~= "" and ("default " .. item.default) or "",
      item.source,
    }))
  end
  return rows
end

local function profile_rows(section)
  local rows = {}
  for index = 1, #section.rows do
    local item = section.rows[index]
    rows[#rows + 1] = row(item.active and (item.name .. " (active)") or item.name)
  end
  return rows
end

local function diagnostics_rows(section)
  local rows = {}
  local value = section.value
  rows[#rows + 1] = row("App version: " .. (value.app_version ~= "" and value.app_version or "unknown"))
  rows[#rows + 1] = row("Profile: " .. profile_label(value))
  rows[#rows + 1] = row("Profile source: " .. (value.profile_source ~= "" and value.profile_source or "unknown"))
  rows[#rows + 1] = row(join({ "Theme: " .. (value.theme ~= "" and value.theme or "unknown"), value.theme_source }))
  local paths = value.paths
  rows[#rows + 1] = path_row("Config file", paths.config_file)
  rows[#rows + 1] = path_row("Config dir", paths.config_dir)
  rows[#rows + 1] = path_row("Plugin ledger", paths.plugin_ledger)
  rows[#rows + 1] = path_row("Plugin store", paths.plugin_store)
  rows[#rows + 1] = path_row("Extension user root", paths.extension_user_root)
  rows[#rows + 1] = path_row("Extension system root", paths.extension_system_root)
  rows[#rows + 1] = path_row("Extension state root", paths.extension_state_root)
  rows[#rows + 1] = row(join({
    "Font: " .. (value.font_family ~= "" and value.font_family or "unknown"),
    value.font_size ~= nil and (text.field(value.font_size) .. " pt") or "",
  }))
  rows[#rows + 1] = row("Decoration: " .. decoration_label(value.decoration))
  return rows
end

local EMPTY_TEXT = {
  plugins = "No plugins reported by the host.",
  extensions = "No extensions installed.",
  settings = "No declared settings rows.",
  profiles = "No profiles defined.",
  diagnostics = "No diagnostics reported by the host.",
  overview = "No overview data.",
}

-- Build the row set for the active section.
--
-- Returns `{ section, index, rows, page, note, unavailable, truncated, empty }`.
function M.build(data, state, opts)
  opts = opts or {}
  local index = text.clamp_int(state and state.index, 1, 1, #M.SECTIONS)
  local section = M.SECTIONS[index]
  local page = M.page_size(opts.height)
  local view = {
    section = section,
    index = index,
    page = page,
    rows = {},
    note = nil,
    unavailable = nil,
    truncated = false,
    empty = false,
  }
  if data == nil then
    view.unavailable = "no snapshot"
    view.rows = { row("unavailable: no snapshot", true) }
    view.offset = 0
    return view
  end

  local source = data[section.id]
  if section.id == "overview" then
    view.rows = overview_rows(data)
    view.note = nil
    view.offset = M.clamp_offset(state and state.offset, #view.rows, page)
    return view
  end

  if source == nil or source.kind == "unavailable" then
    view.unavailable = source and source.reason or "section unavailable"
    view.rows = { row("unavailable: " .. view.unavailable, true) }
    view.offset = 0
    return view
  end

  if section.id == "plugins" then
    view.rows = plugin_rows(source)
  elseif section.id == "extensions" then
    view.rows = extension_rows(source)
  elseif section.id == "settings" then
    view.rows = setting_rows(source)
    view.note = M.READ_ONLY_NOTE
  elseif section.id == "profiles" then
    view.rows = profile_rows(source)
  else
    view.rows = diagnostics_rows(source)
  end

  view.truncated = source.truncated == true
  if #view.rows == 0 then
    view.empty = true
    view.rows = { row(EMPTY_TEXT[section.id] or "No rows.", true) }
  end
  view.offset = M.clamp_offset(state and state.offset, #view.rows, page)
  return view
end

-- Apply one captured key event. Returns `state, action, changed`.
--
-- Navigation is bounded: section moves wrap, row moves clamp, and the offset
-- never exceeds `row_count - page`.
function M.apply_key(state, event, opts)
  opts = opts or {}
  local current = state or M.new_state()
  local row_count = text.clamp_int(opts.row_count, 0, 0, 100000)
  local page = text.clamp_int(opts.page, M.DEFAULT_PAGE, 1, M.MAX_PAGE)
  local index = text.clamp_int(current.index, 1, 1, #M.SECTIONS)
  local offset = M.clamp_offset(current.offset, row_count, page)

  local event_type = type(event) == "table" and event.type or nil
  if event_type == "wheel" then
    return M.apply_wheel(current, event, opts)
  end
  if event_type ~= "key" then
    return current, M.ACTION_NONE, false
  end

  local data = type(event.data) == "table" and event.data or nil
  local raw = event.text
  if type(raw) ~= "string" or raw == "" then
    return current, M.ACTION_NONE, false
  end
  local literal = raw
  local named = nil
  if string.sub(raw, 1, 4) == "key:" then
    literal = ""
    named = string.lower(string.sub(raw, 5))
  end

  local shift = data ~= nil and data.shift == true
  local function moved(new_index)
    if new_index ~= index then
      return { index = new_index, offset = 0 }, M.ACTION_NONE, true
    end
    return current, M.ACTION_NONE, false
  end
  local function scrolled(new_offset)
    local bounded = M.clamp_offset(new_offset, row_count, page)
    if bounded ~= offset then
      return { index = index, offset = bounded }, M.ACTION_NONE, true
    end
    return current, M.ACTION_NONE, false
  end

  if literal == "q" or named == "escape" then
    return current, M.ACTION_CLOSE, false
  end
  if literal == "r" then
    return current, M.ACTION_REFRESH, false
  end
  if named == "tab" then
    if shift then
      return moved((index - 2) % #M.SECTIONS + 1)
    end
    return moved(index % #M.SECTIONS + 1)
  end
  if literal == "l" or named == "arrowright" then
    return moved(index % #M.SECTIONS + 1)
  end
  if literal == "h" or named == "arrowleft" then
    return moved((index - 2) % #M.SECTIONS + 1)
  end
  if literal == "j" or named == "arrowdown" then
    return scrolled(offset + 1)
  end
  if literal == "k" or named == "arrowup" then
    return scrolled(offset - 1)
  end
  if named == "pagedown" then
    return scrolled(offset + page)
  end
  if named == "pageup" then
    return scrolled(offset - page)
  end
  if named == "home" or literal == "g" then
    return scrolled(0)
  end
  if named == "end" or literal == "G" then
    return scrolled(row_count)
  end
  local digit = tonumber(literal)
  if digit ~= nil and digit >= 1 and digit <= #M.SECTIONS then
    return moved(digit)
  end
  return current, M.ACTION_NONE, false
end

-- Parse one Core wheel payload: `wheel:Lines(x, y)` or `wheel:Pixels(x, y)`.
-- Both components are finite decimal values; returns `nil` for any other
-- shape so malformed input is ignored instead of guessed at.
function M.wheel_vector(text_value)
  if type(text_value) ~= "string" then
    return nil
  end
  local number = "([%-%+]?%d*%.?%d+)"
  local x_text, y_text = string.match(
    text_value,
    "^wheel:Lines%s*%(%s*" .. number .. "%s*,%s*" .. number .. "%s*%)$"
  )
  local pixels = false
  if x_text == nil then
    x_text, y_text = string.match(
      text_value,
      "^wheel:Pixels%s*%(%s*" .. number .. "%s*,%s*" .. number .. "%s*%)$"
    )
    pixels = true
  end
  if x_text == nil then
    return nil
  end
  local x = tonumber(x_text)
  local y = tonumber(y_text)
  if x == nil or y == nil then
    return nil
  end
  return { x = x, y = y, pixels = pixels }
end

-- Signed offset movement for one captured wheel event, clamped to a page.
--
-- Core sends the platform scroll delta as `wheel:Lines(x, y)` or
-- `wheel:Pixels(x, y)`; positive y is wheel up, so moving toward the first
-- row is a negative offset delta. A line count supplies the magnitude; a
-- pixel delta only supplies direction and uses the bounded default step.
function M.wheel_delta(event, page)
  local bounded_page = text.clamp_int(page, M.DEFAULT_PAGE, 1, M.MAX_PAGE)
  local raw = type(event) == "table" and event.text or nil
  local vector = M.wheel_vector(raw)
  if vector == nil or vector.y == 0 then
    return 0
  end
  local step = math.min(M.WHEEL_STEP, bounded_page)
  if not vector.pixels then
    step = text.clamp_int(
      math.abs(vector.y),
      M.WHEEL_STEP,
      1,
      math.min(M.WHEEL_MAX_STEP, bounded_page)
    )
  end
  if vector.y > 0 then
    return -step
  end
  return step
end

function M.apply_wheel(state, event, opts)
  opts = opts or {}
  local current = state or M.new_state()
  local page = text.clamp_int(opts.page, M.DEFAULT_PAGE, 1, M.MAX_PAGE)
  local row_count = text.clamp_int(opts.row_count, 0, 0, 100000)
  local offset = M.clamp_offset(current.offset, row_count, page)
  local bounded = M.clamp_offset(offset + M.wheel_delta(event, page), row_count, page)
  if bounded ~= offset then
    return { index = text.clamp_int(current.index, 1, 1, #M.SECTIONS), offset = bounded }, M.ACTION_NONE, true
  end
  return current, M.ACTION_NONE, false
end

return M
