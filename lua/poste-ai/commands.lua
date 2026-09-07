--- User commands: :PosteAIChat, :PosteAIModel, :PosteAINew, :PosteAISessions,
--- :PosteAICancel, :PosteAIInfo.

local config = require("poste-ai.config")
local state = require("poste-ai.state")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = state.TITLE })
end

--- Open the chat (optionally activating a context first).
--- @param context_id string|nil
function M.open_chat(context_id)
  if context_id then
    if not require("poste-ai.context_api").set_active(context_id) then
      notify("unknown context: " .. context_id, vim.log.levels.WARN)
      return
    end
  end
  local window = require("poste-ai.chat.window")
  local conversation = require("poste-ai.chat.conversation")
  local session = require("poste-ai.chat.session")
  window.open()
  local s = session.current()
  require("poste-ai.chat.scope").from_list(s.scope)
  conversation.set_messages(s.messages)
  if conversation.is_empty() then
    conversation.append_note("PosteAI ready — type @ for mentions, / for commands, Enter to send.")
  end
  window.update_winbar()
  window.scroll_conversation_to_end()
  window.focus_input(true)
end

--- Toggle the chat sidebar (open_chat when closed/closed when open).
--- @param context_id string|nil
function M.toggle_chat(context_id)
  local window = require("poste-ai.chat.window")
  if window.is_open() and not context_id then
    window.close()
    return
  end
  M.open_chat(context_id)
end

--- Start a fresh session.
function M.new_session()
  local session = require("poste-ai.chat.session")
  local conversation = require("poste-ai.chat.conversation")
  local scope = require("poste-ai.chat.scope")
  -- drop any in-flight exchange first (its partials are saved to the session
  -- it started in) so it cannot leak into the fresh session's view or file
  require("poste-ai.chat.stream").force_reset()
  session.new()
  scope.clear()
  conversation.set_messages({})
  conversation.append_note("New session — type @ for mentions, / for commands, Enter to send.")
  notify("new session started")
end

--- Switch to a stored session by id and restore its view + scope.
--- @param id string
function M.open_session(id)
  local session = require("poste-ai.chat.session")
  local conversation = require("poste-ai.chat.conversation")
  local scope = require("poste-ai.chat.scope")
  -- same as new_session: an in-flight exchange belongs to the session it
  -- started in, not the one we are about to show
  require("poste-ai.chat.stream").force_reset()
  local s = session.switch(id)
  if not s then notify("failed to load session", vim.log.levels.ERROR) return end
  scope.from_list(s.scope)
  conversation.set_messages(s.messages or {})
  local window = require("poste-ai.chat.window")
  window.update_winbar()
  window.scroll_conversation_to_end()
  notify("switched to " .. tostring(s.name))
end

--- Pick and switch a stored session.
function M.switch_session()
  local session = require("poste-ai.chat.session")
  local items = session.list()
  if #items == 0 then notify("no saved sessions yet", vim.log.levels.WARN) return end
  vim.ui.select(items, {
    prompt = "Switch session:",
    format_item = function(item)
      return string.format("%s  (%d msgs, %s)", item.name, item.count,
        os.date("%m-%d %H:%M", item.updated_at))
    end,
  }, function(choice)
    if not choice then return end
    M.open_session(choice.id)
  end)
end

--- Pick provider + model at runtime.
--- @param args string|nil "provider model" (e.g. "openai gpt-4o")
function M.set_model(args)
  local provider, model
  if args and args ~= "" then
    provider, model = args:match("^(%S+)%s+(%S+)$")
    provider = provider or args
  end
  local names = {}
  for name in pairs(config.config.providers) do names[#names + 1] = name end
  table.sort(names)

  local function apply(p, m)
    local cfg = config.config.providers[p]
    if not cfg then notify("unknown provider: " .. p, vim.log.levels.WARN) return end
    if m and m ~= "" then cfg.model = m end
    config.config.provider = p
    notify(("provider: %s · model: %s"):format(p, tostring(cfg.model)))
    require("poste-ai.chat.window").update_winbar()
  end

  if provider and model then apply(provider, model) return end
  if #names == 0 then notify("no providers configured", vim.log.levels.WARN) return end
  vim.ui.select(names, { prompt = "Provider:" }, function(p)
    if not p then return end
    if model then apply(p, model) return end
    vim.ui.input({ prompt = "Model:", default = config.config.providers[p].model }, function(m)
      if not m or m == "" then return end
      apply(p, m)
    end)
  end)
end

--- Status summary for :PosteAIInfo.
function M.info()
  local context_api = require("poste-ai.context_api")
  local stream = require("poste-ai.chat.stream")
  local session = require("poste-ai.chat.session")
  local lines = { "PosteAI status:" }

  local cfg, err = config.resolve_provider()
  if cfg then
    lines[#lines + 1] = ("  provider:  %s (%s)"):format(config.config.provider, cfg.base_url or "")
    lines[#lines + 1] = ("  model:     %s"):format(tostring(cfg.model))
    local key_env = cfg.api_key_env or "(none)"
    local key_set = (config.api_key(cfg) ~= nil)
    lines[#lines + 1] = ("  api key:   %s via %s"):format(key_set and "set" or "MISSING", key_env)
  else
    lines[#lines + 1] = "  provider:  " .. err
  end
  context_api.active()  -- ensure the active context is resolved
  lines[#lines + 1] = ("  context:   %s"):format(state.active_context or "(generic)")
  local ids = context_api.list()
  lines[#lines + 1] = ("  registered: %s"):format(#ids > 0 and table.concat(ids, ", ") or "(none)")
  lines[#lines + 1] = ("  streaming: %s"):format(stream.is_busy() and "yes" or "no")
  local cur = session.current()
  lines[#lines + 1] = ("  session:   %s (%d messages)"):format(tostring(cur.name), #cur.messages)
  notify(table.concat(lines, "\n"))
end

function M.setup()
  local context_api = require("poste-ai.context_api")

  vim.api.nvim_create_user_command("PosteAIChat", function(args)
    local ctx = vim.trim(args.args)
    M.toggle_chat(ctx ~= "" and ctx or nil)
  end, {
    nargs = "?",
    complete = function() return context_api.list() end,
    desc = "Toggle the PosteAI chat sidebar — :PosteAIChat [context]",
  })

  vim.api.nvim_create_user_command("PosteAIModel", function(args)
    M.set_model(args.args)
  end, { nargs = "*", desc = "Set the PosteAI provider/model" })

  vim.api.nvim_create_user_command("PosteAINew", function()
    M.new_session()
  end, { desc = "Start a new PosteAI chat session" })

  vim.api.nvim_create_user_command("PosteAISessions", function()
    M.switch_session()
  end, { desc = "Switch PosteAI chat session" })

  vim.api.nvim_create_user_command("PosteAICancel", function()
    require("poste-ai.chat.stream").cancel()
  end, { desc = "Cancel the in-flight PosteAI request" })

  vim.api.nvim_create_user_command("PosteAIInfo", function()
    M.info()
  end, { desc = "Show PosteAI status" })
end

return M
