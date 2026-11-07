-- Interaction state machine: input capture, enum cycling, and confirm rows.

local edit = require("dashboard.edit")

local M = {}

function M.new_state_is_browse()
  local state = edit.new()
  if state.mode ~= edit.MODE_BROWSE then
    error("a fresh state must browse")
  end
  if state.notice ~= nil then
    error("a fresh state has no notice")
  end
end

function M.parse_value_accepts_typed_scalars()
  local value, err = edit.parse_value("integer", "10000")
  if value ~= 10000 or err ~= nil then
    error("an integer input was not parsed")
  end
  value = edit.parse_value("number", "12.5")
  if value ~= 12.5 then
    error("a number input was not parsed")
  end
  value = edit.parse_value("text", "JetBrains Mono")
  if value ~= "JetBrains Mono" then
    error("a text input was not parsed")
  end
end

function M.parse_value_rejects_bad_input()
  local value, err = edit.parse_value("integer", "1.5")
  if value ~= nil or err == nil then
    error("a fractional integer must be refused")
  end
  value, err = edit.parse_value("integer", "-1")
  if value ~= nil or err == nil then
    error("a negative integer must be refused")
  end
  value, err = edit.parse_value("number", "NaN")
  if value ~= nil or err == nil then
    error("a non-numeric value must be refused")
  end
  value, err = edit.parse_value("text", "")
  if value ~= nil or err == nil then
    error("an empty text value must be refused")
  end
end

function M.enum_cycles_and_wraps()
  local values = { "hidden", "always", "auto" }
  if edit.next_enum("hidden", values) ~= "always" then
    error("the enum did not advance")
  end
  if edit.next_enum("auto", values) ~= "hidden" then
    error("the enum did not wrap")
  end
  if edit.next_enum("unknown", values) ~= "hidden" then
    error("an unknown value must start the cycle")
  end
end

function M.input_appends_and_backspaces_utf8()
  local state = edit.start_input(edit.new(), {
    target = edit.TARGET_CONFIG,
    subject = "font.family",
    kind = "text",
    seed = "ab",
    prompt = "font.family = ",
  })
  if state.mode ~= edit.MODE_INPUT or state.buffer ~= "ab" then
    error("the input was not seeded")
  end
  state = edit.append(state, "c")
  if state.buffer ~= "abc" then
    error("a character was not appended")
  end
  state = edit.append(state, "é")
  state = edit.backspace(state)
  if state.buffer ~= "abc" then
    error("backspace must remove one whole UTF-8 sequence, got " .. state.buffer)
  end
  if edit.input_row(state) ~= "font.family = abc" then
    error("the input row is wrong: " .. edit.input_row(state))
  end
end

function M.invalid_keeps_the_step_and_the_buffer()
  local state = edit.start_input(edit.new(), {
    target = edit.TARGET_CONFIG,
    subject = "font.size",
    kind = "number",
    seed = "x",
    prompt = "font.size = ",
  })
  state = edit.invalid(state, "enter a finite number")
  if state.mode ~= edit.MODE_INPUT then
    error("a parse error must keep the input step")
  end
  if state.buffer ~= "x" or state.notice ~= "enter a finite number" then
    error("the buffer or notice was lost")
  end
end

function M.confirm_carries_the_digest_and_rendering()
  local state = edit.start_confirm(edit.new(), {
    target = edit.TARGET_CONFIG,
    subject = "appearance.theme",
    kind = "text",
    value = "dracula",
    preview = {
      digest = string.rep("a", 64),
      lines = { '-appearance.theme = "default"', '+appearance.theme = "dracula"' },
      keys = { "appearance.theme" },
      changed = true,
    },
  })
  if state.mode ~= edit.MODE_CONFIRM or #state.digest ~= 64 then
    error("the confirm step did not keep the digest")
  end
  local rows = edit.confirm_rows(state)
  if rows[1] ~= 'Apply appearance.theme = "dracula"' then
    error("the intent row is wrong: " .. rows[1])
  end
  if rows[2] ~= "Changed: appearance.theme" then
    error("the changed-key row is wrong: " .. rows[2])
  end
  if rows[3] ~= '-appearance.theme = "default"' then
    error("the rendered diff was not carried")
  end
end

function M.confirm_rows_name_plugin_and_profile_intents()
  local plugin = edit.start_confirm(edit.new(), {
    target = edit.TARGET_PLUGIN,
    subject = "bitty-terminal.bar",
    kind = "bool",
    value = false,
    preview = { digest = string.rep("b", 64), lines = {}, keys = {} },
  })
  if edit.confirm_rows(plugin)[1] ~= "Disable bitty-terminal.bar" then
    error("the plugin intent is wrong")
  end
  local profile = edit.start_confirm(edit.new(), {
    target = edit.TARGET_PROFILE,
    subject = "work",
    kind = "text",
    value = nil,
    preview = { digest = string.rep("c", 64), lines = {}, keys = {} },
  })
  if edit.confirm_rows(profile)[1] ~= "Switch profile to work" then
    error("the profile intent is wrong")
  end
end

function M.notice_and_cancel_return_to_browse()
  local state = edit.start_confirm(edit.new(), {
    target = edit.TARGET_CONFIG,
    subject = "appearance.theme",
    kind = "text",
    value = "x",
    preview = { digest = string.rep("d", 64), lines = {}, keys = {} },
  })
  state = edit.cancel(state)
  if state.mode ~= edit.MODE_BROWSE or state.digest ~= nil then
    error("cancel must clear the pending step")
  end
  state = edit.notice(state, "applied · reload auto")
  if state.notice ~= "applied · reload auto" then
    error("the notice was not kept")
  end
end

function M.value_rendering_is_typed()
  if edit.describe_value(true, "bool") ~= "true" then
    error("a bool must render unquoted")
  end
  if edit.describe_value(12.5, "number") ~= "12.5" then
    error("a number must render as a number")
  end
  if edit.describe_value("steady_bar", "text") ~= '"steady_bar"' then
    error("a text value must render quoted")
  end
  if edit.seed_value("steady_bar", "text") ~= "steady_bar" then
    error("the input seed must not be quoted")
  end
end

return M
