-- Interaction state machine for the Dashboard (bitty-terminal.dashboard).
--
-- Three modes drive the panel:
--
--   browse  - navigation and section activation (the read-only default)
--   input   - one-line capture for a text/integer/number value
--   confirm - a previewed change waiting for its second Enter
--
-- The machine is pure: it shapes state and display rows, and never calls the
-- host. `init.lua` owns the `preview`/`set` calls and feeds the results back,
-- which keeps the two-press contract (preview, then confirm) testable without
-- a plugin VM. Every write still needs the one-shot digest produced by the
-- matching preview; this module only carries it.

local text = require("dashboard.text")

local M = {}

M.MODE_BROWSE = "browse"
M.MODE_INPUT = "input"
M.MODE_CONFIRM = "confirm"

M.TARGET_CONFIG = "config"
M.TARGET_PLUGIN = "plugin"
M.TARGET_PROFILE = "profile"

M.MAX_INPUT_BYTES = 256
M.MAX_NOTICE_BYTES = 96
M.MAX_VALUE_BYTES = 256

-- One empty browse state.
function M.new()
  return { mode = M.MODE_BROWSE, notice = nil }
end

local function copy(state)
  return {
    mode = state.mode or M.MODE_BROWSE,
    target = state.target,
    subject = state.subject,
    kind = state.kind,
    value = state.value,
    buffer = state.buffer,
    prompt = state.prompt,
    digest = state.digest,
    lines = state.lines,
    keys = state.keys,
    changed = state.changed,
    notice = state.notice,
  }
end

-- Enter the one-line input for a free-text or numeric value.
function M.start_input(state, opts)
  local next_state = copy(state)
  next_state.mode = M.MODE_INPUT
  next_state.target = opts.target
  next_state.subject = opts.subject
  next_state.kind = opts.kind
  next_state.buffer = text.single_line(opts.seed or "")
  next_state.prompt = opts.prompt
  next_state.digest = nil
  next_state.lines = nil
  next_state.keys = nil
  next_state.notice = opts.notice
  return next_state
end

-- Enter the confirm step for one previewed change.
function M.start_confirm(state, opts)
  local next_state = copy(state)
  next_state.mode = M.MODE_CONFIRM
  next_state.target = opts.target
  next_state.subject = opts.subject
  next_state.kind = opts.kind
  next_state.value = opts.value
  next_state.buffer = nil
  next_state.prompt = nil
  next_state.digest = opts.preview.digest
  next_state.lines = opts.preview.lines or {}
  next_state.keys = opts.preview.keys or {}
  next_state.changed = opts.preview.changed ~= false
  next_state.notice = opts.notice
  return next_state
end

-- Return to browsing with one bounded outcome line.
function M.notice(state, message)
  local next_state = copy(state)
  next_state.mode = M.MODE_BROWSE
  next_state.target = nil
  next_state.subject = nil
  next_state.kind = nil
  next_state.value = nil
  next_state.buffer = nil
  next_state.prompt = nil
  next_state.digest = nil
  next_state.lines = nil
  next_state.keys = nil
  next_state.changed = nil
  next_state.notice = text.field(message, M.MAX_NOTICE_BYTES)
  return next_state
end

-- Keep the current step and show a bounded input problem (for example an
-- integer that does not parse) without dropping the typed buffer.
function M.invalid(state, message)
  local next_state = copy(state)
  next_state.notice = text.field(message, M.MAX_NOTICE_BYTES)
  return next_state
end

-- Cancel the current step without writing.
function M.cancel(state)
  return M.notice(state, "cancelled")
end

-- Append one captured character to the input buffer.
function M.append(state, char)
  if state.mode ~= M.MODE_INPUT or type(char) ~= "string" or char == "" then
    return state
  end
  local next_state = copy(state)
  local candidate = (next_state.buffer or "") .. char
  if #candidate > M.MAX_INPUT_BYTES then
    return state
  end
  next_state.buffer = candidate
  return next_state
end

-- Drop one trailing UTF-8 sequence from the input buffer.
function M.backspace(state)
  if state.mode ~= M.MODE_INPUT then
    return state
  end
  local buffer = state.buffer or ""
  local index = #buffer
  while index > 0 do
    local byte = string.byte(buffer, index)
    if byte == nil or byte < 128 or byte >= 192 then
      break
    end
    index = index - 1
  end
  if index > 0 then
    index = index - 1
  end
  local next_state = copy(state)
  next_state.buffer = string.sub(buffer, 1, index)
  return next_state
end

-- Parse one input line into the typed scalar the host expects.
--
-- Returns `value, nil` or `nil, message`. A message is a short, value-free
-- explanation so the panel never echoes a rejected input.
function M.parse_value(kind, raw)
  if kind == "integer" then
    local number = tonumber(raw)
    if number == nil or number ~= math.floor(number) or number < 0 or number > 4294967295 then
      return nil, "enter a non-negative integer"
    end
    return math.floor(number), nil
  end
  if kind == "number" then
    local number = tonumber(raw)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
      return nil, "enter a finite number"
    end
    return number, nil
  end
  local value = text.single_line(raw)
  if value == "" then
    return nil, "enter a value"
  end
  if #value > M.MAX_VALUE_BYTES then
    return nil, "value is too long"
  end
  return value, nil
end

-- Next value in a closed enum cycle. An unknown current value starts the
-- cycle at its first entry.
function M.next_enum(current, values)
  if type(values) ~= "table" or #values == 0 then
    return nil
  end
  for index = 1, #values do
    if values[index] == current then
      return values[(index % #values) + 1]
    end
  end
  return values[1]
end

-- Unquoted seed for the one-line input.
function M.seed_value(value, kind)
  if value == nil then
    return ""
  end
  if kind == "bool" then
    return value == true and "true" or "false"
  end
  if type(value) == "number" then
    return text.number_text(value)
  end
  return text.field(value, M.MAX_VALUE_BYTES)
end

-- Quoted display form for one typed value.
function M.describe_value(value, kind)
  if kind == "bool" or type(value) == "boolean" then
    return value == true and "true" or "false"
  end
  if type(value) == "number" then
    return text.number_text(value)
  end
  return '"' .. text.field(value, M.MAX_VALUE_BYTES) .. '"'
end

-- The single input line: prompt plus buffer.
function M.input_row(state)
  return (state.prompt or "") .. (state.buffer or "")
end

-- Confirm-step rows: intent, changed keys, and the host's exact diff.
function M.confirm_rows(state)
  local rows = {}
  local title
  if state.target == M.TARGET_CONFIG then
    title = "Apply " .. tostring(state.subject) .. " = " .. M.describe_value(state.value, state.kind)
  elseif state.target == M.TARGET_PLUGIN then
    title = (state.value == true and "Enable " or "Disable ") .. tostring(state.subject)
  elseif state.target == M.TARGET_PROFILE then
    title = "Switch profile to " .. tostring(state.subject)
  else
    title = "Apply change"
  end
  rows[#rows + 1] = title
  if type(state.keys) == "table" and #state.keys > 0 then
    rows[#rows + 1] = "Changed: " .. table.concat(state.keys, ", ")
  end
  if type(state.lines) == "table" then
    for index = 1, #state.lines do
      rows[#rows + 1] = state.lines[index]
    end
  end
  if #rows == 1 then
    rows[#rows + 1] = "(no rendered change)"
  end
  return rows
end

return M
