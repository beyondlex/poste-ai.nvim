--- Chat scope — ordered key/value bindings that constrain the active context
--- (e.g. which connection / database a db-scoped chat targets). Keys are
--- domain-specific and set by context slash commands; this module only owns
--- the storage, ordering, persistence shape and display.
---
--- Display contract: no binding → "-", values joined by "/" otherwise
--- ("pg" or "pg/app").

local M = {}

local st = {
  bindings = {},  -- ordered {{ key, value }}
}

local function find(key)
  for i, b in ipairs(st.bindings) do
    if b.key == key then return i end
  end
  return nil
end

--- Set (or clear with nil value) a binding; upsert keeps declaration order.
--- @param key string
--- @param value string|nil
function M.set(key, value)
  local i = find(key)
  if value == nil then
    if i then table.remove(st.bindings, i) end
  elseif i then
    st.bindings[i].value = value
  else
    st.bindings[#st.bindings + 1] = { key = key, value = value }
  end
  M.notify_changed()
end

function M.clear()
  st.bindings = {}
  M.notify_changed()
end

--- Ordered bindings, live table (do not mutate).
function M.get() return st.bindings end

--- Plain map snapshot for message records and context callbacks.
function M.snapshot()
  local out = {}
  for _, b in ipairs(st.bindings) do out[b.key] = b.value end
  return out
end

--- Leftmost status display: "-" or values joined by "/".
function M.display()
  if #st.bindings == 0 then return "-" end
  local vals = {}
  for _, b in ipairs(st.bindings) do vals[#vals + 1] = b.value end
  return table.concat(vals, "/")
end

--- Persistence shape.
function M.to_list()
  local out = {}
  for _, b in ipairs(st.bindings) do out[#out + 1] = { key = b.key, value = b.value } end
  return out
end

function M.from_list(list)
  st.bindings = {}
  for _, b in ipairs(list or {}) do
    if b.key and b.value then st.bindings[#st.bindings + 1] = { key = b.key, value = b.value } end
  end
  M.notify_changed()
end

--- Refresh the scope displays and stamp the current session so the next
--- save persists it.
function M.notify_changed()
  pcall(function()
    local session = require("poste-ai.chat.session")
    local s = session._state().current
    if s then s.scope = M.to_list() end
  end)
  pcall(function() require("poste-ai.chat.window").update_context_line() end)
  pcall(function() require("poste-ai.chat.window").update_winbar() end)
end

M._test = { st = st }

return M
