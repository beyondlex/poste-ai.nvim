--- Provider adapter registry. Adapters implement `stream(cfg, opts, handlers)`
--- with the same contract as `provider/openai.lua`. New protocols (e.g.
--- Anthropic messages) register themselves here.

local M = {}

local adapters = {
  openai = "poste-ai.provider.openai",
}

--- Register (or replace) an adapter for a protocol name.
--- @param name string
--- @param module string require path
function M.register(name, module)
  adapters[name] = module
end

--- Resolve the adapter module for a provider config. `cfg.protocol` selects
--- an adapter explicitly; anything else (including unknown names) uses the
--- OpenAI-compatible one. Registered values are either require paths
--- (strings) or adapter tables.
--- @param cfg table provider config
--- @return table|nil adapter
--- @return string|nil err
function M.get(cfg)
  local name = (cfg and (cfg.protocol or nil)) or "openai"
  if not adapters[name] then name = "openai" end
  local entry = adapters[name]
  if type(entry) == "table" then return entry, nil end
  local ok, mod = pcall(require, entry)
  if not ok then return nil, "provider adapter not found: " .. tostring(entry) end
  return mod, nil
end

--- List registered adapter names (for :PosteAIInfo / tests).
--- @return string[]
function M.names()
  local out = {}
  for name in pairs(adapters) do out[#out + 1] = name end
  table.sort(out)
  return out
end

M._test = { get = M.get, names = M.names }

return M
