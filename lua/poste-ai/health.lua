--- :checkhealth poste-ai

local M = {}

function M.check()
  local config = require("poste-ai.config")

  vim.health.start("poste-ai")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required")
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found (" .. vim.fn.exepath("curl") .. ")")
  else
    vim.health.error("curl not found — required for LLM streaming")
  end

  local cfg, err = config.resolve_provider()
  if not cfg then
    vim.health.error(err or "no provider configured",
      { "Add to setup: require('poste-ai').setup({ providers = { openai = { model = '...' } } })" })
  else
    vim.health.ok(("provider %q · model %q · %s"):format(
      config.config.provider, tostring(cfg.model), cfg.base_url or ""))
    local key_env = cfg.api_key_env
    if not key_env or key_env == "" then
      vim.health.warn("no api_key_env set — requests without an API key may be rejected")
    elseif config.api_key(cfg) then
      vim.health.ok(("API key set via %s"):format(key_env))
    else
      vim.health.warn(("%s is not set in the environment"):format(key_env),
        { "export " .. key_env .. "=..." })
    end
  end

  local ok_dir = pcall(vim.fn.mkdir, config.sessions_dir(), "p")
  if ok_dir then
    vim.health.ok("sessions dir writable: " .. config.sessions_dir())
  else
    vim.health.warn("cannot create sessions dir: " .. config.sessions_dir())
  end

  local context_api = require("poste-ai.context_api")
  local ids = context_api.list()
  if #ids > 0 then
    vim.health.ok("contexts registered: " .. table.concat(ids, ", "))
  else
    vim.health.info("no contexts registered (generic chat with file @mentions only)")
  end

  -- optional: code-block syntax highlighting falls back to plain background
  -- optional: code-block syntax highlighting falls back to plain background
  local have = {}
  for _, lang in ipairs({ "sql", "lua", "python", "bash", "javascript", "json" }) do
    if pcall(vim.treesitter.get_string_parser, "", lang) then have[#have + 1] = lang end
  end
  if #have > 0 then
    vim.health.ok("treesitter parsers for code blocks: " .. table.concat(have, ", "))
  else
    vim.health.info("no treesitter parsers — code blocks render without syntax highlighting")
  end
end

return M
