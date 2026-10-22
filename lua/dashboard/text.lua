-- Bounded display-string helpers for the Dashboard (bitty-terminal.dashboard).
--
-- Pure Lua: no host access, no I/O. Every user-visible string that comes from
-- the runtime snapshot passes through this module before it reaches a scene
-- node, so the mounted component can never carry an unbounded field, a
-- control byte, or an absolute host path.
--
-- Bounds are expressed in bytes and mirror the host's own display bounds
-- (`RUNTIME_INSPECT_MAX_STRING_BYTES` = 96, `RUNTIME_INSPECT_MAX_PATH_BYTES` =
-- 240) so a malformed or hostile snapshot stays bounded even when the host
-- bound was not applied.

local M = {}

M.ELLIPSIS = "…"
M.MAX_FIELD_BYTES = 96
M.MAX_CELL_BYTES = 240

-- Layout defaults. The Plugin API v1 has no viewport-size surface, so the
-- dashboard renders against declared bounds; the host clips the block to the
-- live window. Both values are policy bounds, not magic numbers.
M.DEFAULT_WIDTH = 80
M.DEFAULT_HEIGHT = 24
M.MIN_WIDTH = 40
M.MIN_HEIGHT = 12
M.MAX_WIDTH = 240
M.MAX_HEIGHT = 100

local function byte_at(value, index)
  return string.byte(value, index)
end

-- Whether `index` starts a UTF-8 continuation byte (0x80..0xBF).
local function is_continuation(index_byte)
  return index_byte ~= nil and index_byte >= 128 and index_byte < 192
end

-- Slice at a UTF-8 boundary without requiring the `utf8` library: the plugin
-- VM is a restricted Lua build, so the byte-level rule is the portable one.
function M.slice_bytes(value, max_bytes)
  if type(value) ~= "string" or max_bytes == nil or max_bytes <= 0 then
    return ""
  end
  if #value <= max_bytes then
    return value
  end
  local cut = max_bytes
  while cut > 0 and is_continuation(byte_at(value, cut + 1)) do
    cut = cut - 1
  end
  return string.sub(value, 1, cut)
end

-- Truncate to `max_bytes` with a trailing ellipsis. Returns `text, truncated`.
function M.truncate(value, max_bytes)
  if type(value) ~= "string" then
    value = ""
  end
  if max_bytes == nil or max_bytes <= 0 then
    return "", value ~= ""
  end
  if #value <= max_bytes then
    return value, false
  end
  local ellipsis = M.ELLIPSIS
  if max_bytes <= #ellipsis then
    return M.slice_bytes(ellipsis, max_bytes), true
  end
  return M.slice_bytes(value, max_bytes - #ellipsis) .. ellipsis, true
end

-- Replace control bytes (including newlines and tabs) with a space and drop
-- the ones that would break a single-line row. A display string is always one
-- line: the host paints rows, it does not re-flow them.
function M.single_line(value)
  if type(value) ~= "string" then
    return ""
  end
  local out = {}
  local length = #value
  local index = 1
  while index <= length do
    local byte = byte_at(value, index)
    if byte == 9 or byte == 10 or byte == 13 then
      out[#out + 1] = " "
    elseif byte >= 32 and byte ~= 127 then
      out[#out + 1] = string.sub(value, index, index)
    end
    index = index + 1
  end
  return table.concat(out)
end

-- Absolute-path shaped token: `/…`, `~/…`, `./…`, `../…`, or `C:\…`.
-- Relative names and identifiers never match.
function M.is_path_token(token)
  if type(token) ~= "string" or token == "" then
    return false
  end
  local first = string.sub(token, 1, 1)
  if first == "/" then
    return true
  end
  if string.sub(token, 1, 2) == "~/" then
    return true
  end
  if string.sub(token, 1, 2) == "./" or string.sub(token, 1, 3) == "../" then
    return true
  end
  local drive = string.match(token, "^(%a):[/\\]")
  return drive ~= nil
end

-- Characters that separate one free-text value from the next: whitespace,
-- `key=value` separators, JSON punctuation, and shell-ish delimiters. A path
-- may start right after any of them.
local PATH_BOUNDARY = {
  [" "] = true,
  ["\t"] = true,
  ["\n"] = true,
  ["\r"] = true,
  ["="] = true,
  ["("] = true,
  [","] = true,
  [";"] = true,
  [":"] = true,
  ['"'] = true,
  ["'"] = true,
  ["{"] = true,
  ["}"] = true,
  ["["] = true,
  ["]"] = true,
  ["<"] = true,
  [">"] = true,
}

-- Characters that end an unquoted path token. A quoted path ends at its own
-- closing quote instead, so a host path containing spaces stays covered.
local PATH_STOP = {
  [" "] = true,
  ["\t"] = true,
  ["\n"] = true,
  ["\r"] = true,
  ['"'] = true,
  ["'"] = true,
  ["}"] = true,
  ["]"] = true,
  [")"] = true,
  [","] = true,
  [";"] = true,
  [">"] = true,
}

-- Candidate token at `index`, up to the next whitespace. Shape detection only;
-- the redaction scan owns the real end position.
local function path_candidate(value, index)
  return string.match(string.sub(value, index), "^[^%s]+") or ""
end

-- Whether a path-shaped token starts at `index`. The accepted token forms live
-- in `is_path_token`; this adds quoted/JSON boundaries, `./`/`../` relatives,
-- and the `file:` URI wrapper.
local function starts_path(value, index)
  local candidate = path_candidate(value, index)
  if M.is_path_token(candidate) then
    -- Keep an ordinary URL readable: `https://` is a URI, not a local path.
    local before = string.sub(value, 1, index - 1)
    if string.sub(candidate, 1, 2) == "//" and string.match(before, "%a+:$") ~= nil then
      return false
    end
    return true
  end
  if string.sub(candidate, 1, 5) == "file:" then
    local target = string.sub(candidate, 6)
    if string.sub(target, 1, 2) == "//" then
      target = string.sub(target, 3)
    end
    return M.is_path_token(target) or string.sub(candidate, 1, 7) == "file://"
  end
  return false
end

-- Replace path-shaped substrings with `…`. Setting values and host detail
-- strings are free text, so the dashboard never assumes a field is path-free
-- just because it is not named like a path. A path starts at the beginning of
-- the value or after a boundary (whitespace, `=`, `,`, `:`, quotes, braces),
-- and runs to the next boundary; a quoted path runs to its closing quote.
function M.redact_paths(value)
  if type(value) ~= "string" then
    return ""
  end
  local out = {}
  local length = #value
  local index = 1
  local at_start = true
  local quote = nil
  while index <= length do
    local char = string.sub(value, index, index)
    if at_start and starts_path(value, index) then
      out[#out + 1] = "…"
      if quote ~= nil then
        while index <= length and string.sub(value, index, index) ~= quote do
          index = index + 1
        end
      else
        while index <= length and not PATH_STOP[string.sub(value, index, index)] do
          index = index + 1
        end
      end
      at_start = false
    else
      out[#out + 1] = char
      if char == '"' or char == "'" then
        if quote == nil then
          if at_start then
            quote = char
          end
        elseif quote == char then
          quote = nil
        end
        at_start = true
      elseif PATH_BOUNDARY[char] then
        at_start = true
      else
        at_start = false
      end
      index = index + 1
    end
  end
  return table.concat(out)
end

-- Basename of a host path, or nil for an empty/absent value. Scanning from the
-- end avoids a potentially backtracking pattern on the plugin VM.
function M.basename(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local last = #path
  while last > 0 do
    local char = string.sub(path, last, last)
    if char ~= "/" and char ~= "\\" then
      break
    end
    last = last - 1
  end
  if last == 0 then
    return nil
  end
  local start = last
  while start > 1 do
    local char = string.sub(path, start - 1, start - 1)
    if char == "/" or char == "\\" then
      break
    end
    start = start - 1
  end
  return string.sub(path, start, last)
end

-- One bounded display field from an untrusted snapshot value.
function M.field(value, max_bytes)
  local limit = max_bytes or M.MAX_FIELD_BYTES
  if type(value) == "string" then
    local text = M.truncate(M.redact_paths(M.single_line(value)), limit)
    return text
  end
  if type(value) == "number" then
    local text
    if value == math.floor(value) and math.abs(value) < 1e15 then
      text = string.format("%d", value)
    else
      text = string.format("%.2f", value)
    end
    return text
  end
  if type(value) == "boolean" then
    return value and "yes" or "no"
  end
  return ""
end

-- Clamp an integer-ish value into `[minimum, maximum]`, falling back to
-- `default` for nil or non-finite input.
function M.clamp_int(value, default, minimum, maximum)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    number = default
  end
  number = math.floor(number)
  if number < minimum then
    return minimum
  end
  if number > maximum then
    return maximum
  end
  return number
end

-- Repeat a glyph up to `count` times, bounded by the layout width.
function M.fill(glyph, count)
  count = M.clamp_int(count, 0, 0, M.MAX_WIDTH)
  if count <= 0 then
    return ""
  end
  local parts = {}
  for index = 1, count do
    parts[index] = glyph
  end
  return table.concat(parts)
end

return M
