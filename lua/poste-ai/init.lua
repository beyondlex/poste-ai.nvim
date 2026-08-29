--- poste-ai.nvim — AI assistant chat for the Poste plugin family.
--- Zero dependencies: streaming via curl + Lua SSE, contexts registered by
--- sibling plugins (poste-db.nvim, poste-http.nvim, ...).

local M = {}

--- Setup. Idempotent: safe to call again with user opts (e.g. from lazy.nvim
--- after plugin/poste-ai.lua already ran).
--- @param opts table|nil
function M.setup(opts)
  opts = opts or {}
  local config = require("poste-ai.config")
  config.merge(opts)
  require("poste-ai.highlights").setup()
  require("poste-ai.commands").setup()

  local group = vim.api.nvim_create_augroup("PosteAISetup", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function() require("poste-ai.highlights").setup() end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      pcall(function() require("poste-ai.chat.session").save() end)
    end,
  })
  math.randomseed(os.time())
end

--- Register a context (see context_api.lua for the contract).
M.register_context = require("poste-ai.context_api").register
M.set_active_context = require("poste-ai.context_api").set_active

--- Convenience entry points.
M.chat = function(context_id) require("poste-ai.commands").toggle_chat(context_id) end
M.send = function(text) return require("poste-ai.chat.stream").send(text) end
M.cancel = function() require("poste-ai.chat.stream").cancel() end

--- Current chat scope snapshot (map of slash-command bindings, e.g.
--- { connection = "pg", database = "app" }) — read by sibling plugins.
M.scope = function() return require("poste-ai.chat.scope").snapshot() end

M._test = { config = require("poste-ai.config") }

return M
