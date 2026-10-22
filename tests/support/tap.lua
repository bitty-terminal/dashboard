-- Minimal assertion helper for the Dashboard behavior suite.
--
-- No external test framework: `just test-lua` runs `lua5.4 tests/run.lua`,
-- which collects failures and exits non-zero. Assertions report the call site
-- so a failure names the spec line, not just the value.

local tap = {}

tap.passed = 0
tap.failed = 0

local function location()
  local info = debug.getinfo(3, "Sl")
  if info == nil then
    return "?"
  end
  return string.format("%s:%d", info.short_src or "?", info.currentline or 0)
end

local function fail(message)
  tap.failed = tap.failed + 1
  io.write(string.format("    FAIL %s — %s\n", location(), message))
end

function tap.ok(value, label)
  if value then
    tap.passed = tap.passed + 1
    return true
  end
  fail((label or "expected truthy") .. " (got " .. tostring(value) .. ")")
  return false
end

function tap.equal(actual, expected, label)
  if actual == expected then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)))
  return false
end

function tap.not_equal(actual, unexpected, label)
  if actual ~= unexpected then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: did not expect %s", label or "value", tostring(unexpected)))
  return false
end

function tap.contains(haystack, needle, label)
  if type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: %q does not contain %q", label or "string", tostring(haystack), tostring(needle)))
  return false
end

function tap.not_contains(haystack, needle, label)
  if type(haystack) == "string" and string.find(haystack, needle, 1, true) == nil then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: %q must not contain %q", label or "string", tostring(haystack), tostring(needle)))
  return false
end

function tap.matches(value, pattern, label)
  if type(value) == "string" and string.match(value, pattern) ~= nil then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: %q does not match %q", label or "string", tostring(value), tostring(pattern)))
  return false
end

function tap.less_or_equal(actual, maximum, label)
  if type(actual) == "number" and actual <= maximum then
    tap.passed = tap.passed + 1
    return true
  end
  fail(string.format("%s: expected <= %s, got %s", label or "value", tostring(maximum), tostring(actual)))
  return false
end

return tap
