--- Slash command framework for the chat input — agent-style "/" commands.
--- Typing "/" as the first character pops a command palette ABOVE the input
--- window (chat/popup.lua); Up/Down move, Enter/Tab select, Esc closes.
--- Built-ins: /new, /session, /models. Contexts extend the palette through
--- the optional `commands` contract field (see context_api.lua):
---   commands = { { name, desc, complete?(prefix, scope, cb), run(item, api) } }
--- `run` receives the chosen candidate (or nil) and an api table with
--- set_scope(key, value) / scope() / clear_scope() to bind the chat scope.

local M = {}

local st = {
  mode = nil,       -- nil | "commands" | "argument"
  command = nil,    -- resolved command in argument mode
  candidates = {},
  seq = 0,          -- stale async candidate guard
}

--- The api handed to context command run() callbacks.
local api = {
  set_scope = function(key, value) require("poste-ai.chat.scope").set(key, value) end,
  scope = function() return require("poste-ai.chat.scope").snapshot() end,
  clear_scope = function() require("poste-ai.chat.scope").clear() end,
}

--- Built-in commands (no context needed).
local function builtins()
  return {
    {
      name = "new",
      desc = "start a new chat session",
      run = function() require("poste-ai.commands").new_session() end,
    },
    {
      name = "session",
      desc = "switch to another session",
      complete = function(prefix)
        local items = {}
        for _, s in ipairs(require("poste-ai.chat.session").list()) do
          if s.name:sub(1, #prefix) == prefix then
            items[#items + 1] = {
              label = s.name,
              description = ("%d msgs · %s"):format(s.count, os.date("%m-%d %H:%M", s.updated_at)),
              id = s.id,
            }
          end
        end
        return items
      end,
      run = function(item)
        if item and item.id then require("poste-ai.commands").open_session(item.id) end
      end,
    },
    {
      name = "models",
      desc = "change provider / model",
      run = function() require("poste-ai.commands").set_model() end,
    },
  }
end

--- All available commands: built-ins + active context commands.
--- @return table[] normalized { name, desc?, complete?, run? }
function M.commands()
  local out = {}
  for _, c in ipairs(builtins()) do out[#out + 1] = c end
  local ok, spec = pcall(function() return require("poste-ai.context_api").active() end)
  if ok and type(spec) == "table" and type(spec.commands) == "table" then
    for _, c in ipairs(spec.commands) do
      if type(c) == "table" and type(c.name) == "string" and c.name ~= "" then
        out[#out + 1] = { name = c.name, desc = c.desc, complete = c.complete, run = c.run }
      end
    end
  end
  return out
end

local function find_command(name)
  for _, c in ipairs(M.commands()) do
    if c.name == name then return c end
  end
  return nil
end

local function command_item(c)
  return { label = "/" .. c.name, description = c.desc or "", name = c.name }
end

--- Drop the palette and internal mode (keeps input text).
function M.reset()
  st.mode = nil
  st.command = nil
  st.candidates = {}
  st.seq = st.seq + 1
  require("poste-ai.chat.popup").close()
end

local function run_command(cmd, item)
  M.reset()
  local w = require("poste-ai.chat.window")
  w.clear_input()
  if type(cmd.run) ~= "function" then return end
  local ok, err = pcall(cmd.run, item, api)
  if not ok then
    vim.notify(("poste-ai: /%s failed: %s"):format(cmd.name, err),
      vim.log.levels.ERROR, { title = "PosteAI" })
  end
end

--- Show argument candidates for a command (async, stale-guarded).
local function enter_argument_mode(cmd, arg_prefix)
  st.mode = "argument"
  st.command = cmd
  st.candidates = {}
  st.seq = st.seq + 1
  local seq = st.seq
  local popup = require("poste-ai.chat.popup")
  popup.open({}, {
    on_select = function(item) run_command(cmd, item) end,
    on_cancel = function() st.mode = nil st.command = nil end,
  })
  if type(cmd.complete) ~= "function" then return end
  local deliver = function(items)
    if seq ~= st.seq then return end
    st.candidates = type(items) == "table" and items or {}
    popup.set_items(st.candidates)
  end
  local ok, res = pcall(cmd.complete, arg_prefix, api.scope(), deliver)
  if not ok then
    vim.notify(("poste-ai: /%s completion failed: %s"):format(cmd.name, res),
      vim.log.levels.ERROR, { title = "PosteAI" })
    deliver({})
  elseif type(res) == "table" then
    -- synchronous complete(): returned the candidate list directly
    deliver(res)
  end
end

--- Show the command palette filtered by the typed prefix.
local function show_commands(name_prefix)
  st.mode = "commands"
  local items = {}
  for _, c in ipairs(M.commands()) do
    if c.name:sub(1, #name_prefix) == name_prefix then
      items[#items + 1] = command_item(c)
    end
  end
  require("poste-ai.chat.popup").open(items, {
    on_select = function(item)
      local cmd = find_command(item.name)
      if not cmd then return end
      if type(cmd.complete) == "function" then
        -- prefill "/name " and switch to argument candidates
        local w = require("poste-ai.chat.window")
        w.set_input_text("/" .. cmd.name .. " ")
        local win = w.input_win()
        if win then
          local last = vim.api.nvim_buf_line_count(w.input_buf())
          pcall(vim.api.nvim_win_set_cursor, win, { last, #(vim.api.nvim_buf_get_lines(w.input_buf(), last - 1, last, false)[1] or "") })
        end
        enter_argument_mode(cmd, "")
      else
        run_command(cmd, nil)
      end
    end,
    on_cancel = function() st.mode = nil end,
  })
end

--- TextChangedI hook: parse the input buffer and (re)target the palette.
function M.on_input_changed()
  local w = require("poste-ai.chat.window")
  if not w.is_open() then M.reset() return end
  local text = w.input_text()
  if text:sub(1, 1) ~= "/" or text:find("\n") then M.reset() return end
  local name, arg = text:match("^/(%S*)%s*(.-)$")
  if name == "" then
    show_commands("")
    return
  end
  local cmd = find_command(name)
  if cmd then
    if type(cmd.complete) == "function" then
      enter_argument_mode(cmd, arg)
    else
      show_commands(name)
    end
  else
    show_commands(name)
  end
end

--- Try to execute the input as a slash command. Returns true when the text
--- was consumed (must NOT be sent to the LLM).
--- @param text string
--- @return boolean
function M.submit(text)
  text = text or ""
  if text:sub(1, 1) ~= "/" or text:find("\n") then return false end
  local name, arg = text:match("^/(%S*)%s*(.-)$")
  local cmd = name ~= "" and find_command(name) or nil
  if not cmd then
    if not text:find("%s") then
      vim.notify("poste-ai: unknown command " .. text, vim.log.levels.WARN, { title = "PosteAI" })
      M.reset()
      require("poste-ai.chat.window").clear_input()
      return true
    end
    return false
  end
  if type(cmd.complete) == "function" then
    -- open the palette so the user picks an argument candidate
    enter_argument_mode(cmd, arg)
  else
    run_command(cmd, nil)
  end
  return true
end

M._test = {
  st = st,
  builtins = builtins,
  find_command = find_command,
  api = api,
}

return M
