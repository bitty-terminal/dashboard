-- Plain-Lua runner for the Dashboard behavior suite.
--
-- Each `spec/*.lua` file returns a table of `name = function(tap_support)`.
-- Run with `lua5.4 tests/run.lua` (or `just test-lua`). Exits non-zero on the
-- first failing spec file so CI cannot report a green gate over failures.

package.path = table.concat({
  "./lua/?.lua",
  "./tests/?.lua",
  "./tests/support/?.lua",
  "./?.lua",
  package.path,
}, ";")

local tap = require("support.tap")

local SPECS = {
  "spec.text_spec",
  "spec.inspect_spec",
  "spec.model_spec",
  "spec.render_spec",
  "spec.init_spec",
}

-- Drop every cached dashboard module and the mock host global so each spec
-- loads the plugin from source against its own host stub.
local function fresh()
  for name in pairs(package.loaded) do
    if name == "dashboard" or string.sub(name, 1, 10) == "dashboard." then
      package.loaded[name] = nil
    end
  end
  package.loaded["support.mock_host"] = nil
  _G.bitty = nil
end

local failed_files = 0
local total = 0

for _, name in ipairs(SPECS) do
  fresh()
  local ok, spec = pcall(require, name)
  if not ok then
    io.write(string.format("FAIL %s (load error: %s)\n", name, tostring(spec)))
    failed_files = failed_files + 1
  else
    local passed_before = tap.passed
    local failed_before = tap.failed
    for test_name, test in pairs(spec) do
      total = total + 1
      fresh()
      local ran, err = pcall(test, tap)
      if not ran then
        tap.failed = tap.failed + 1
        io.write(string.format("    FAIL %s > %s — %s\n", name, test_name, tostring(err)))
      else
        tap.passed = tap.passed + 1
      end
    end
    local file_failures = tap.failed - failed_before
    if file_failures > 0 then
      failed_files = failed_files + 1
      io.write(string.format(
        "FAIL %s (%d assertion(s) failed, %d passed)\n",
        name,
        file_failures,
        tap.passed - passed_before
      ))
    else
      io.write(string.format("ok   %s (%d assertions)\n", name, tap.passed - passed_before))
    end
  end
end

io.write(string.format(
  "\n%d spec(s), %d assertion(s): %d passed, %d failed\n",
  total,
  tap.passed + tap.failed,
  tap.passed,
  tap.failed
))

if tap.failed > 0 or failed_files > 0 then
  os.exit(1)
end
