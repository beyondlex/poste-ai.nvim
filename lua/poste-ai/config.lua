--- poste-ai configuration — provider defaults, chat window layout, keymaps.
--- Zero-dependency: unlike the poste family satellites there is no
--- `poste.state` fallback; everything resolves from this module.

local M = {}

--- Defaults. Merged with user opts in M.merge().
M.defaults = {
  --- Active provider name (key into `providers`).
  provider = "openai",
  --- Provider configs. `api_key_env` names an environment variable; the key
  --- itself is never stored in config files.
  providers = {
    openai = {
      base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY",
      model = nil, -- must be set by the user; health.lua reports it
    },
  },
  --- Per-request parameters passed through to the provider when set.
  request = {
    temperature = nil,
    max_tokens = nil,
    timeout_ms = 120000,
  },
  --- Write AI request/response round-trips to
  --- `stdpath("data")/poste-ai/logs/requests-YYYY-MM-DD.jsonl`.
  log = true,
  chat = {
    split_position = "right", -- "left" or "right"
    split_width = 60,
    input_height = 3, -- input pane height in lines; also its maximum (clamped on resize)
    append_focus = true, -- move the cursor into the target buffer after ga appends a block
  },
  --- Session storage directory. Defaults to `stdpath("data")/poste-ai/sessions`.
  sessions_dir = nil,
  keymaps = {
    chat_window = {
      close = "q",
      focus_input = "i",
      cancel = "<Esc>",
      toggle_render = "R",
      show_outline = "gs",
      yank_last_answer = "Y",
      next_codeblock = "]]",
      prev_codeblock = "[[",
      execute_codeblock = "<CR>",
      yank_codeblock = "gy",
      append_codeblock = "ga",
      help = "g?",
    },
    chat_outline = {
      jump = "<CR>",
      close = "q",
      cancel = "<Esc>",
    },
    chat_input = {
      submit = "<CR>",          -- normal mode; in insert mode Enter inserts a newline
      submit_insert = "<M-Cr>", -- insert mode (Option/Alt+Enter)
      cancel = "<C-c>",
      focus_chat = "<Esc>",
      new_session = "<C-n>",
      history_up = "<Up>",      -- previous question; inside a multi-line draft the
      history_down = "<Down>",  -- arrows move the cursor instead (first/last line wraps)
    },
  },
}

--- Effective config (defaults + merged user opts).
M.config = vim.deepcopy(M.defaults)

local KEY_DISPLAY_NAMES = {
  ["<Tab>"] = "Tab",
  ["<S-Tab>"] = "S-Tab",
  ["<CR>"] = "Enter",
  ["<M-Cr>"] = "Alt+Enter",
  ["<Up>"] = "Up",
  ["<Down>"] = "Down",
  ["<Esc>"] = "Esc",
  ["<Space>"] = "<Space>",
  ["<C-c>"] = "C-c",
  ["<C-n>"] = "C-n",
  ["<BS>"] = "BS",
}

--- Merge user opts into the effective config (deep for nested tables).
--- Called from poste-ai.setup().
--- @param opts table|nil
function M.merge(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if type(v) == "table" and type(M.config[k]) == "table" then
      M.config[k] = vim.tbl_deep_extend("force", M.config[k], v)
    else
      M.config[k] = v
    end
  end
end

--- Resolve a keymap for (section, action). `false` disables; nil → default.
--- @param section string
--- @param action string
--- @param default string|nil
--- @return string|nil
function M.get_keymap(section, action, default)
  local sec = M.config.keymaps[section]
  if not sec then return default end
  local key = sec[action]
  if key == nil then return default end
  if key == false then return nil end
  return key
end

--- Format a key string for display (handles <leader> and named keys).
--- @param key string
--- @return string
function M.format_key_string(key)
  if not key or key == "" then return "" end
  if KEY_DISPLAY_NAMES[key] then return KEY_DISPLAY_NAMES[key] end
  if key:sub(1, 8) == "<leader>" then
    local leader = vim.g.mapleader or "\\"
    if leader == " " then leader = "<Space>"
    elseif leader == "\t" then leader = "<Tab>"
    elseif leader == "\r" then leader = "<CR>"
    end
    leader = KEY_DISPLAY_NAMES[leader] or leader
    return leader .. key:sub(9)
  end
  return key
end

--- Resolve and format a keymap for (section, action).
--- @param section string
--- @param action string
--- @return string
function M.format_keymap(section, action)
  local key = M.get_keymap(section, action)
  if not key then return "" end
  return M.format_key_string(key)
end

--- Sessions directory, applying the default when unconfigured.
--- @return string
function M.sessions_dir()
  return M.config.sessions_dir or (vim.fn.stdpath("data") .. "/poste-ai/sessions")
end

--- Resolve the active provider config table.
--- @return table|nil cfg
--- @return string|nil err human-readable reason when unresolvable
function M.resolve_provider()
  local name = M.config.provider
  local cfg = name and M.config.providers[name]
  if not cfg then
    return nil, ("provider %q is not configured (set opts.providers.%s)"):format(tostring(name), tostring(name))
  end
  if not cfg.model then
    return nil, ("provider %q has no model set"):format(tostring(name))
  end
  return cfg, nil
end

--- Read the API key for a provider config from the environment.
--- @param cfg table provider config with `api_key_env`
--- @return string|nil
function M.api_key(cfg)
  if not cfg or not cfg.api_key_env or cfg.api_key_env == "" then return nil end
  return os.getenv(cfg.api_key_env)
end

M._test = {
  get_keymap = M.get_keymap,
  format_key_string = M.format_key_string,
  format_keymap = M.format_keymap,
  merge = M.merge,
  resolve_provider = M.resolve_provider,
}

return M
