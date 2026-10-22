-- Declarative scene builder for the Dashboard (bitty-terminal.dashboard).
--
-- Accepted Plugin API v1 UI surface: `Text`, `Row`, `Column`, and `List`
-- nodes only, mounted through the focusable-overlay session
-- (`bitty.ui.overlay.update`). This module is pure: it shapes the bounded
-- view model into nodes and never calls the host.
--
-- Layout contract: the root is a `List` whose direct children are exactly one
-- painted row each, because Core's `overlay_scene_rows` expands only the root's
-- direct children and flattens any nested group into a single line. Every
-- rendered line is truncated to the declared width, the page size is derived
-- from the declared height, and the component always carries at least one
-- content row (empty and unavailable states included).

local model = require("dashboard.model")
local text = require("dashboard.text")

local M = {}

M.TITLE = "Dashboard"
M.SEPARATOR = " │ "
M.ACTIVE_FG = "accent"
-- The host token table is closed (`foreground`, `background`, `cursor`,
-- `selection`, `accent`); `foreground` is the dimmest available choice.
M.DIM_FG = "foreground"
M.RULE_GLYPH = "-"

local function node(kind, content)
  return { kind = kind, text = content }
end

local function truncate(value, width)
  return text.truncate(value, width)
end

-- Tab strip. When the full strip cannot fit, only the active tab is shown as
-- `index/count title`, so the strip never wraps or overflows.
function M.tabs(active_index, width)
  local cells = {}
  local total = 0
  local full = {}
  for index = 1, #model.SECTIONS do
    local section = model.SECTIONS[index]
    full[#full + 1] = section.title
    total = total + #section.title
    if index > 1 then
      total = total + #M.SEPARATOR
    end
  end
  if total > width then
    local section = model.SECTIONS[active_index] or model.SECTIONS[1]
    return {
      {
        kind = "Row",
        children = {
          node("Text", string.format("%d/%d %s", active_index, #model.SECTIONS, section.title)),
        },
      },
    }
  end
  for index = 1, #model.SECTIONS do
    local section = model.SECTIONS[index]
    local active = index == active_index
    if index > 1 then
      cells[#cells + 1] = node("Text", M.SEPARATOR)
    end
    local cell = node("Text", section.title)
    if active then
      cell.bold = true
      cell.fg = M.ACTIVE_FG
    end
    cells[#cells + 1] = cell
  end
  return { { kind = "Row", children = cells } }
end

function M.footer(view)
  local rows_word = view.empty and "no rows" or string.format(
    "rows %d-%d/%d",
    view.first or 0,
    view.last or 0,
    view.row_count or 0
  )
  if view.truncated then
    rows_word = rows_word .. " (host-truncated)"
  end
  return string.format(
    "%d/%d %s · %s · j/k row · h/l section · r refresh · q close",
    view.index,
    #model.SECTIONS,
    view.section.title,
    rows_word
  )
end

-- Build the declarative component for one built view.
--
-- `view` is the output of `model.build` plus the window (`first`, `last`,
-- `row_count`); `opts` carries `{ width, height }`.
function M.scene(view, opts)
  opts = opts or {}
  local width = text.clamp_int(opts.width, text.DEFAULT_WIDTH, text.MIN_WIDTH, text.MAX_WIDTH)
  local height = text.clamp_int(opts.height, text.DEFAULT_HEIGHT, text.MIN_HEIGHT, text.MAX_HEIGHT)
  local page = model.page_size(height)

  local first, last = model.window(#view.rows, view.offset or 0, page)
  local windowed = {
    index = view.index,
    section = view.section,
    rows = view.rows,
    offset = view.offset or 0,
    page = page,
    first = first,
    last = last,
    row_count = #view.rows,
    empty = view.empty,
    truncated = view.truncated,
  }

  -- Direct children of the root are the painted rows. A nested `List` here
  -- would collapse every content row into one line, because Core flattens a
  -- non-root group horizontally instead of stacking it.
  local children = {
    node("Text", truncate(M.TITLE .. " · read-only", width)),
  }
  children[1].bold = true

  local tabs = M.tabs(view.index, width)
  children[#children + 1] = tabs[1]
  children[#children + 1] = node("Text", text.fill(M.RULE_GLYPH, width))

  local content_rows = 0
  for index = first, last do
    local item = view.rows[index]
    local content = truncate(item.text, width)
    local child = node("Text", content)
    if item.dim then
      child.fg = M.DIM_FG
    end
    children[#children + 1] = child
    content_rows = content_rows + 1
  end
  if content_rows == 0 then
    children[#children + 1] = node("Text", truncate("No rows.", width))
  end

  if view.note ~= nil and view.note ~= "" then
    local note = node("Text", truncate(view.note, width))
    note.fg = M.DIM_FG
    children[#children + 1] = note
  end

  local footer = node("Text", truncate(M.footer(windowed), width))
  footer.fg = M.DIM_FG
  children[#children + 1] = footer

  return { kind = "List", children = children }
end

-- Plain lines as Core paints them (`overlay_scene_rows`): a `Column`/`List`
-- root yields one line per direct child, each child flattened horizontally
-- (Text leaves in walk order). Nested groups never add a line, so this mirrors
-- the host instead of assuming vertical stacking.
function M.lines(component)
  if type(component) ~= "table" then
    return {}
  end
  local lines = {}
  local function flatten(item, parts)
    if type(item) ~= "table" then
      return
    end
    if item.kind == "Text" then
      parts[#parts + 1] = item.text or ""
      return
    end
    for index = 1, #(item.children or {}) do
      flatten(item.children[index], parts)
    end
  end
  if component.kind == "Column" or component.kind == "List" then
    for index = 1, #(component.children or {}) do
      local parts = {}
      flatten(component.children[index], parts)
      lines[#lines + 1] = table.concat(parts)
    end
    if #lines == 0 then
      lines[1] = ""
    end
    return lines
  end
  local parts = {}
  flatten(component, parts)
  lines[1] = table.concat(parts)
  return lines
end

return M
