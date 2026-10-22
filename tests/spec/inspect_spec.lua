-- `runtime.inspect()` adapter: snapshot reading, normalization, and typed
-- per-section failure markers.

local inspect = require("dashboard.inspect")
local snapshot = require("support.snapshot")

local M = {}

function M.reads_full_snapshot()
  local data, err = inspect.collect({
    runtime = {
      inspect = function()
        return snapshot.full()
      end,
    },
  })
  if data == nil then
    error("expected a snapshot, got error " .. tostring(err and err.code))
  end
  if data.diagnostics.kind ~= "rows" then
    error("diagnostics must be available")
  end
  if #data.plugins.rows ~= 3 or #data.extensions.rows ~= 2 or #data.profiles.rows ~= 2 then
    error("unexpected row counts")
  end
  if data.settings.rows[1].key ~= "width" or data.settings.rows[1].source ~= "default" then
    error("setting rows were not normalized")
  end
end

function M.missing_surface_is_typed()
  local data, err = inspect.collect({})
  if data ~= nil then
    error("a host without runtime.inspect must not produce a snapshot")
  end
  if err.code ~= inspect.CODE_UNAVAILABLE then
    error("unexpected code: " .. tostring(err.code))
  end
end

function M.denied_grant_is_typed_and_bounded()
  local data, err = inspect.collect({
    runtime = {
      inspect = function()
        error({
          class = "runtime",
          code = "E_CAPABILITY_DENIED",
          message = "denied while reading /home/tester/.config/bitty/init.lua",
        }, 0)
      end,
    },
  })
  if data ~= nil then
    error("a denied grant must not produce a snapshot")
  end
  if err.code ~= "E_CAPABILITY_DENIED" then
    error("unexpected code: " .. tostring(err.code))
  end
  if string.find(err.message, "/home/tester", 1, true) ~= nil then
    error("host error text leaked a path: " .. err.message)
  end
end

function M.malformed_snapshot_is_typed()
  local data, err = inspect.collect({
    runtime = {
      inspect = function()
        return "not a table"
      end,
    },
  })
  if data ~= nil or err.code ~= inspect.CODE_MALFORMED then
    error("a non-table snapshot must be rejected")
  end
end

function M.unavailable_sections_are_preserved()
  local data = inspect.normalize(snapshot.unavailable())
  for _, name in ipairs({ "diagnostics", "plugins", "settings", "extensions", "profiles" }) do
    local section = data[name]
    if section.kind ~= inspect.KIND_UNAVAILABLE then
      error(name .. " must stay unavailable, not become an empty list")
    end
    if section.reason ~= "source unavailable" then
      error(name .. " lost its typed reason")
    end
  end
end

function M.missing_section_is_unavailable()
  local data = inspect.normalize({})
  if data.plugins.kind ~= inspect.KIND_UNAVAILABLE or data.plugins.reason ~= "section unavailable" then
    error("an absent section must render as unavailable")
  end
end

function M.malformed_rows_are_dropped()
  local data = inspect.normalize({
    plugins = { rows = { "nope", { id = "" }, { id = "ok.id", name = "Ok" } } },
  })
  if #data.plugins.rows ~= 1 or data.plugins.rows[1].id ~= "ok.id" then
    error("malformed rows must be dropped, not rendered")
  end
end

function M.row_caps_are_enforced()
  local rows = {}
  for index = 1, 300 do
    rows[index] = { key = "k" .. index, plugin_id = "bitty-terminal.dashboard" }
  end
  local data = inspect.normalize({ settings = { rows = rows, truncated = false } })
  if #data.settings.rows ~= inspect.ROW_LIMITS.settings then
    error("settings rows were not capped")
  end
  if data.settings.truncated ~= true then
    error("a capped section must report truncation")
  end
end

function M.diagnostic_paths_are_reduced()
  local data = inspect.normalize(snapshot.full())
  local paths = data.diagnostics.value.paths
  if paths.config_file.label ~= "init.lua" or not paths.config_file.present then
    error("config file must be present with a basename only")
  end
  if paths.config_dir.label ~= "bitty" then
    error("config dir must be reduced to its basename")
  end
  if paths.extension_system_root.label ~= "extensions" then
    error("extension root must be reduced to its basename")
  end
  if paths.plugin_ledger.present ~= true then
    error("plugin ledger must report presence")
  end
end

function M.absent_diagnostic_paths_are_missing()
  local data = inspect.normalize({ diagnostics = { app_version = "0.0.26" } })
  if data.diagnostics.value.paths.config_file.present ~= false then
    error("an absent path must report not present")
  end
end

function M.extension_paths_are_not_retained()
  local data = inspect.normalize(snapshot.full())
  local extension = data.extensions.rows[1]
  if extension.executable ~= "kitty-graphics" then
    error("executable must be reduced to a basename")
  end
  local serialized = string.format("%s", extension.executable)
  if string.find(serialized, "/", 1, true) ~= nil then
    error("extension path leaked a directory separator")
  end
end

function M.normalize_rejects_non_tables()
  local data = inspect.normalize(nil)
  if data.plugins.kind ~= inspect.KIND_UNAVAILABLE then
    error("nil snapshot must normalize to unavailable sections")
  end
end

return M
