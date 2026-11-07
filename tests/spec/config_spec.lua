-- `config.manage` adapter: normalization, bounded payloads, and typed errors.

local config = require("dashboard.config")

local M = {}

local function digest(seed)
  return string.rep(seed or "a", 64)
end

local function fake_host(options)
  options = options or {}
  local host = {
    config = {
      sources = function()
        if options.sources_error ~= nil then
          error(options.sources_error, 0)
        end
        return { rows = options.sources or {}, count = #(options.sources or {}), truncated = false }
      end,
      get = function(key)
        if options.get_error ~= nil then
          error(options.get_error, 0)
        end
        local value = (options.values or {})[key]
        if value == nil then
          return { key = key, found = false, value = nil, kind = "absent", source = "default", redacted = false }
        end
        return {
          key = key,
          found = true,
          value = value.value,
          kind = value.kind,
          source = value.source or "user",
          redacted = value.redacted == true,
        }
      end,
      preview = function(key, value)
        if options.preview_error ~= nil then
          error(options.preview_error, 0)
        end
        return {
          digest = options.preview_digest or digest(),
          rendered = "-" .. key .. "\n+" .. tostring(value),
          keys = { key },
        }
      end,
      set = function()
        return { applied = true, reload = "auto" }
      end,
    },
  }
  return host
end

function M.detects_the_surface_without_calling_it()
  if config.readable({}) then
    error("an empty host must not be readable")
  end
  if config.readable({ config = { sources = function() end } }) then
    error("a host without config.get must not be readable")
  end
  local host = fake_host()
  if not config.readable(host) then
    error("the fake host must be readable")
  end
  if config.writable({ config = { sources = function() end, get = function() end } }) then
    error("reads alone must not imply writes")
  end
  if config.toggleable(host) or config.switchable(host) then
    error("the minimal fake host has no plugin or profile surface")
  end
end

function M.collects_the_curated_keys_in_display_order()
  local sources = {
    { key = "scrollbar.mode", source = "default" },
    { key = "appearance.theme", source = "user" },
    { key = "not.in.the.subset", source = "default" },
  }
  local values = {
    ["appearance.theme"] = { value = "dracula", kind = "text", source = "user" },
    ["scrollbar.mode"] = { value = "auto", kind = "text", source = "default" },
  }
  local host = fake_host({ sources = sources, values = values })
  local managed, err = config.collect(host)
  if managed == nil then
    error("collect failed: " .. tostring(err and err.code))
  end
  if #managed.settings.rows ~= 2 then
    error("expected two curated rows, got " .. #managed.settings.rows)
  end
  if managed.settings.rows[1].key ~= "appearance.theme" then
    error("rows must follow the curated order, got " .. managed.settings.rows[1].key)
  end
  if managed.settings.rows[1].source ~= "user" then
    error("the source label was not preserved")
  end
  if managed.settings.rows[1].loaded or managed.settings.rows[1].value ~= nil then
    error("sources() carries no value: the row must start unloaded")
  end
  local row = config.get(host, "appearance.theme")
  if row.value ~= "dracula" or row.source ~= "user" then
    error("config.get did not return the typed value")
  end
  if managed.plugins ~= nil or managed.profiles ~= nil then
    error("a host without list surfaces must not grow managed tabs")
  end
end

function M.reuses_cached_values_across_refreshes()
  local sources = { { key = "appearance.theme", source = "user" } }
  local previous = {
    settings = {
      rows = {
        {
          key = "appearance.theme",
          found = true,
          value = "cached",
          kind = "text",
          source = "user",
          redacted = false,
          loaded = true,
        },
      },
    },
  }
  local managed = config.collect(fake_host({ sources = sources }), previous)
  if managed == nil then
    error("collect failed")
  end
  if not managed.settings.rows[1].loaded or managed.settings.rows[1].value ~= "cached" then
    error("a loaded row must be reused from the previous snapshot")
  end
end

function M.blocked_codes_are_typed()
  for _, code in ipairs({ "E_CAPABILITY_DENIED", "E_CONFIG_UNAVAILABLE", "E_CONFIG_UNSAFE" }) do
    local err = { class = "runtime", code = code, message = "no" }
    if not config.is_blocked(err) then
      error(code .. " must block the write surface")
    end
  end
  if config.is_blocked({ class = "io", code = "E_CONFIG_IO", message = "x" }) then
    error("an I/O failure must not block the whole surface")
  end
  if config.blocked_notice({ code = "E_CAPABILITY_DENIED" }) ~= "config.manage denied: showing read-only data" then
    error("the denial notice is wrong")
  end
end

function M.denied_reads_fail_closed()
  local denied = { class = "runtime", code = "E_CAPABILITY_DENIED", message = "denied" }
  local managed, err = config.collect(fake_host({ sources_error = denied }))
  if managed ~= nil then
    error("a denied sources call must not produce managed data")
  end
  if err == nil or not config.is_blocked(err) then
    error("the denial must be typed for the caller to degrade")
  end
end

function M.preview_requires_a_bounded_digest()
  local host = fake_host({ preview_digest = "abc" })
  local preview, err = config.preview(host, "appearance.theme", "x")
  if preview ~= nil then
    error("a short digest must be refused")
  end
  if err.code ~= config.CODE_MALFORMED then
    error("expected E_CONFIG_MALFORMED, got " .. tostring(err.code))
  end
end

function M.diff_lines_are_bounded_and_single_line()
  local lines = config.diff_lines("-a\tb\n+c\n")
  if #lines ~= 2 or lines[1] ~= "-a b" or lines[2] ~= "+c" then
    error("the diff was not normalized: " .. table.concat(lines, "|"))
  end
end

function M.errors_redact_host_paths()
  local err = config.error_from({
    class = "io",
    code = "E_CONFIG_IO",
    message = "failed at /home/tester/.config/bitty/init.lua",
  })
  if err.code ~= "E_CONFIG_IO" then
    error("the error code was not preserved")
  end
  if string.find(err.message, "/home/tester", 1, true) ~= nil then
    error("the error message leaked a host path")
  end
end

function M.plugin_and_profile_rows_drop_malformed_entries()
  local host = fake_host()
  host.plugins = {
    list = function()
      return {
        rows = {
          { id = "bitty-terminal.bar", enabled = true, managed = true, source = "bundled", version = "0.0.1" },
          { id = "", enabled = true },
          "not a table",
        },
        truncated = false,
      }
    end,
  }
  host.profiles = {
    list = function()
      return {
        rows = { { name = "work", active = true }, { name = "" } },
        active = "work",
        truncated = false,
      }
    end,
  }
  local plugins = config.plugins(host)
  if #plugins.rows ~= 1 or plugins.rows[1].id ~= "bitty-terminal.bar" then
    error("malformed plugin rows must be dropped")
  end
  local profiles = config.profiles(host)
  if #profiles.rows ~= 1 or profiles.rows[1].name ~= "work" or profiles.active ~= "work" then
    error("malformed profile rows must be dropped")
  end
end

function M.enum_and_kind_metadata_is_local()
  if config.kind_of("font.size") ~= "number" then
    error("font.size must be a number")
  end
  if config.kind_of("appearance.animations.enabled") ~= "bool" then
    error("the animation toggle must be a bool")
  end
  if config.kind_of("terminal.shell") ~= nil then
    error("terminal.shell is deliberately outside the editable subset")
  end
  local values = config.ENUMS["terminal.bell"]
  if values == nil or values[1] ~= "off" then
    error("the bell enum is missing")
  end
end

return M
