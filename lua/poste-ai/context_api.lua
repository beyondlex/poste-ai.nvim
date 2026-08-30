--- Context registry — the extension point sibling plugins use to teach the
--- generic chat about their domain. A context provides:
---
---   system_prompt(scope) → string      domain knowledge (feature help,
---                                      conventions); called per request with
---                                      the chat scope snapshot (nil keys
---                                      unset) — implementations may ignore it
---   mention = {
---     match(token) → ref|nil           classify a @token ("my-conn/mydb")
---     complete(prefix, cb) → candidates  completion items {label, description}
---     resolve(ref, cb) → markdown       turn a ref into a context block
---                                      (cb(md_text, err); async allowed)
---   }
---   codeblock = {
---     langs = { "sql", ... }           fenced languages it can execute
---     confirm(text) → boolean|nil      optional gate before execute
---     execute(text, refs, cb)          run it; cb(err, note) when done
---     append_header(scope, text)       optional header lines inserted above a
---                                      block appended with `ga` (e.g. file
---                                      directives binding the buffer to the
---                                      chat scope); followed by one blank
---                                      line; nil adds nothing
---   }
---   commands = {                       optional slash commands for the input
---     {                                 palette (typed "/" in the chat input):
---       name = "connections"            invoked as /connections
---       desc = "..."                    shown in the palette
---       complete(prefix, scope, cb)     optional argument candidates
---                                      ({label, description, ...}); may
---                                      return the list synchronously instead
---                                      of calling cb
---       run(item, api)                  execute; item is the chosen candidate
---                                      or nil; api exposes set_scope(key,
---                                      value, icon?), scope(), clear_scope()
---                                      to bind the chat scope (displayed above
---                                      the input and persisted per message)
---     }
---   }
---
--- Note: "context" here is an AI-domain plugin integration — unrelated to the
--- SQL execution context in poste-db.nvim's `context.lua`.

local state = require("poste-ai.state")

local M = {}

local contexts = {}

--- Register (or replace) a context. Ids are typically the plugin domain
--- ("db", "http"). Returns the stored spec.
--- @param id string
--- @param spec table
--- @return table
function M.register(id, spec)
  assert(type(id) == "string" and id ~= "", "context id required")
  assert(type(spec) == "table", "context spec must be a table")
  contexts[id] = spec
  return spec
end

--- Remove a context (used by tests/unload).
function M.unregister(id) contexts[id] = nil end

--- @return table|nil
function M.get(id) return contexts[id] end

--- Registered context ids, sorted.
--- @return string[]
function M.list()
  local out = {}
  for id in pairs(contexts) do out[#out + 1] = id end
  table.sort(out)
  return out
end

--- Activate a context for new requests. Nil restores generic chat.
--- @param id string|nil
--- @return boolean success
function M.set_active(id)
  if id ~= nil and not contexts[id] then return false end
  state.active_context = id
  return true
end

--- The active context spec, or nil.
--- @return table|nil
function M.active()
  return state.active_context and contexts[state.active_context] or nil
end

local BASE_PROMPT = [[You are poste-ai, an AI assistant embedded in the user's Neovim editor.
Guidelines:
- Reply in the same language the user writes in.
- Use GitHub-flavored markdown. Put any code in fenced blocks tagged with a language (e.g. ```sql).
- Stay concise and practical; you render in an editor side panel.
- When several options exist, recommend one instead of enumerating them all.]]

--- Compose the system prompt: base + active context knowledge. The context
--- system_prompt receives the chat scope snapshot (map of bound keys).
--- @return string
function M.system_prompt()
  local parts = { BASE_PROMPT }
  local spec = M.active()
  if spec and type(spec.system_prompt) == "function" then
    local scope = require("poste-ai.chat.scope").snapshot()
    local ok, out = pcall(spec.system_prompt, scope)
    if ok and type(out) == "string" and out ~= "" then
      parts[#parts + 1] = out
    end
  end
  return table.concat(parts, "\n\n")
end

M._test = {
  register = M.register,
  unregister = M.unregister,
  get = M.get,
  list = M.list,
  system_prompt = M.system_prompt,
}

return M
