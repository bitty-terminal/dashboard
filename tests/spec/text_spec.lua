-- Bounded display-string helpers: truncation, sanitization, path handling.

local text = require("dashboard.text")

local M = {}

function M.truncate_short_values()
  local value, truncated = text.truncate("Palette", 16)
  if value ~= "Palette" or truncated ~= false then
    error("short string must not be truncated")
  end

  local long = string.rep("x", 50)
  value, truncated = text.truncate(long, 10)
  if truncated ~= true then
    error("long string must report truncation")
  end
  if #value ~= 10 or string.sub(value, -3) ~= "…" then
    error("truncated string must be exactly the bound plus ellipsis")
  end
end

function M.truncate_respects_utf8_boundaries()
  -- 4 code points, 12 bytes. A 6-byte cut would split the second character.
  local value = text.truncate("日本語x", 8)
  if #value > 8 then
    error("truncated value exceeded the byte bound: " .. #value)
  end
  if string.find(value, "\xE6\x97", 1, true) ~= nil and string.find(value, "\xE6\x97\xA5", 1, true) == nil then
    error("truncation split a multibyte character")
  end
end

function M.single_line_replaces_controls()
  local value = text.single_line("alpha\nbeta\tgamma\r\0delta\x7f")
  if value ~= "alpha beta gamma delta" then
    error("unexpected single-line result: " .. string.format("%q", value))
  end
end

function M.field_bounds_and_types()
  if text.field({}) ~= "" then
    error("table values must render empty")
  end
  if text.field(nil) ~= "" then
    error("nil values must render empty")
  end
  if text.field(true) ~= "yes" or text.field(false) ~= "no" then
    error("booleans must render yes/no")
  end
  if text.field(12) ~= "12" then
    error("integers must render without a decimal point")
  end
  if text.field(12.5) ~= "12.50" then
    error("fractions must render with two decimals")
  end
  local long = text.field(string.rep("a", 400))
  if #long > text.MAX_FIELD_BYTES then
    error("field exceeded the display bound")
  end
end

function M.basename_reduces_paths()
  if text.basename("/home/tester/.config/bitty/init.lua") ~= "init.lua" then
    error("unix basename failed")
  end
  if text.basename("/home/tester/.config/bitty/") ~= "bitty" then
    error("trailing separator must be ignored")
  end
  if text.basename("C:\\Users\\tester\\bitty.toml") ~= "bitty.toml" then
    error("windows basename failed")
  end
  if text.basename("") ~= nil or text.basename(nil) ~= nil or text.basename("/") ~= nil then
    error("empty paths must have no basename")
  end
end

function M.path_tokens_are_redacted()
  if text.is_path_token("bitty.toml") then
    error("a plain file name is not a path token")
  end
  for _, token in ipairs({ "/etc/bitty", "~/x", "./x", "../x", "C:\\bitty" }) do
    if not text.is_path_token(token) then
      error("expected a path token: " .. token)
    end
  end
  local value = text.redact_paths("root=/home/tester/.config and name=work")
  if string.find(value, "/home/tester", 1, true) ~= nil then
    error("absolute path survived redaction: " .. value)
  end
  if string.find(value, "name=work", 1, true) == nil then
    error("non-path token was modified: " .. value)
  end
end

function M.quoted_uri_and_relative_paths_are_redacted()
  local json = text.redact_paths('{"path":"/home/tester/.config/bitty.toml"}')
  if json ~= '{"path":"…"}' then
    error("a quoted JSON path must keep the object shape: " .. json)
  end
  for _, case in ipairs({
    { '{"path":"/home/tester/My Config/init.lua"}', "My Config" },
    { "file:///home/tester/.config/bitty.toml", "/home/tester" },
    { "file:/home/tester/.config/bitty.toml", "/home/tester" },
    { "source=./config/bitty.toml", "config/bitty.toml" },
    { "source=../config/bitty.toml", "config/bitty.toml" },
  }) do
    local value = text.redact_paths(case[1])
    if string.find(value, case[2], 1, true) ~= nil then
      error("path survived redaction: " .. value)
    end
    if string.find(value, "…", 1, true) == nil then
      error("path was not replaced with an ellipsis: " .. value)
    end
  end
  local relative = text.redact_paths("source=./config/bitty.toml")
  if relative ~= "source=…" then
    error("a relative path must be fully redacted: " .. relative)
  end
  -- Ordinary URIs and plain names stay readable.
  local url = text.redact_paths("homepage=https://example.com/docs")
  if url ~= "homepage=https://example.com/docs" then
    error("an ordinary URL must stay readable: " .. url)
  end
  if text.redact_paths("name=work") ~= "name=work" then
    error("a non-path token was modified")
  end
end

function M.clamp_int_bounds()
  if text.clamp_int(nil, 24, 12, 100) ~= 24 then
    error("nil must fall back to the default")
  end
  if text.clamp_int(3, 24, 12, 100) ~= 12 then
    error("below-minimum must clamp")
  end
  if text.clamp_int(400, 24, 12, 100) ~= 100 then
    error("above-maximum must clamp")
  end
  if text.clamp_int("80", 24, 12, 100) ~= 80 then
    error("numeric strings must parse")
  end
  if text.clamp_int(0 / 0, 24, 12, 100) ~= 24 then
    error("NaN must fall back to the default")
  end
end

function M.fill_is_bounded()
  if text.fill("─", 3) ~= "───" then
    error("fill must repeat the glyph")
  end
  if text.fill("─", -1) ~= "" then
    error("negative fill must be empty")
  end
  if #text.fill("─", 10000) > text.MAX_WIDTH * 4 then
    error("fill must respect the layout bound")
  end
end

function M.slice_bytes_never_splits_a_character()
  local value = text.slice_bytes("日本語", 4)
  if #value > 4 then
    error("slice exceeded the bound")
  end
  if value ~= "日" then
    error("unexpected slice: " .. string.format("%q", value))
  end
end

return M
