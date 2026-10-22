-- Staged `bitty.runtime.inspect()` snapshots for the behavior suite.
--
-- Values mirror the documented host payload. Host paths are synthetic and
-- deliberately absolute so the path-redaction tests have something to catch.

local M = {}

function M.full()
  return {
    diagnostics = {
      app_version = "0.0.26",
      config_file = "/home/tester/.config/bitty/init.lua",
      config_dir = "/home/tester/.config/bitty",
      plugin_ledger = "/home/tester/.local/share/bitty/plugins/current.json",
      plugin_store = "/home/tester/.local/share/bitty/plugins/packages",
      extension_user_root = "/home/tester/.local/share/bitty/extensions",
      extension_system_root = "/usr/lib/bitty/extensions",
      extension_state_root = "/home/tester/.local/state/bitty/extensions",
      profile = "work",
      profile_source = "env",
      theme = "default",
      theme_source = "file",
      font_family = "JetBrains Mono",
      font_size = 12.5,
      decoration = { gaps_in = 8, gaps_out = 16, border = 1, radius = 8, content_inset = 0 },
    },
    plugins = {
      rows = {
        {
          id = "bitty-terminal.dashboard",
          name = "Dashboard",
          version = "0.0.1",
          source = "registry",
          enabled = true,
          recorded = true,
        },
        {
          id = "bitty-terminal.bar",
          name = "Unified Bar",
          version = "0.0.1",
          source = "bundled",
          enabled = true,
          recorded = false,
        },
        {
          id = "bitty-terminal.palette",
          name = "Palette",
          version = "0.1.0",
          source = "git",
          enabled = false,
          recorded = true,
        },
      },
      truncated = false,
    },
    settings = {
      rows = {
        {
          plugin_id = "bitty-terminal.dashboard",
          key = "width",
          current = "80",
          default = "80",
          source = "default",
        },
        {
          plugin_id = "bitty-terminal.bar",
          key = "label",
          current = "index",
          default = "index",
          source = "user",
        },
      },
    },
    extensions = {
      rows = {
        {
          name = "kitty-graphics",
          version = "1.2.0",
          tier = "user",
          abi_compatible = true,
          sha256 = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          executable_path = "/home/tester/.local/share/bitty/extensions/kitty-graphics/bin/kitty-graphics",
          activation = "active",
          trust = "verified",
        },
        {
          name = "legacy-renderer",
          version = "0.9.0",
          tier = "system",
          abi_compatible = false,
          sha256 = "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
          executable_path = "/usr/lib/bitty/extensions/legacy-renderer/bin/legacy-renderer",
          activation = "denied:component_untrusted",
          trust = "untrusted",
        },
      },
    },
    profiles = {
      rows = {
        { name = "default", active = false },
        { name = "work", active = true },
      },
    },
  }
end

-- Every section failed at its source.
function M.unavailable()
  return {
    diagnostics = { unavailable = "source unavailable" },
    plugins = { unavailable = "source unavailable" },
    settings = { unavailable = "source unavailable" },
    extensions = { unavailable = "source unavailable" },
    profiles = { unavailable = "source unavailable" },
  }
end

-- Every section available but empty.
function M.empty()
  return {
    diagnostics = { app_version = "0.0.26", profile_source = "none", theme_source = "default" },
    plugins = { rows = {} },
    settings = { rows = {} },
    extensions = { rows = {} },
    profiles = { rows = {} },
  }
end

-- One very long plugin name and one long setting value, for truncation tests.
function M.overlong()
  local snapshot = M.full()
  snapshot.plugins.rows = {
    {
      id = "bitty-terminal.an-extraordinarily-long-identifier-that-should-never-reach-the-screen-in-full",
      name = string.rep("Overlong Plugin Name ", 8),
      version = "1.2.3",
      source = "local-path",
      enabled = true,
      recorded = true,
    },
  }
  snapshot.settings.rows = {
    {
      plugin_id = "bitty-terminal.dashboard",
      key = "note",
      current = string.rep("value ", 40),
      default = "",
      source = "user",
    },
  }
  return snapshot
end

return M
