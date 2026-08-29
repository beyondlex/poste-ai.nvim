--- Chat scope — ordered key/value bindings that constrain the active context
--- (e.g. which connection / database a db-scoped chat targets). Keys are
--- domain-specific and set by context slash commands; this module only owns
--- the storage, ordering, persistence shape and display.
---
--- Display contract: no binding → "-"; `display` joins values by "/"
--- ("pg" or "pg/app"); `render` renders each binding as "<icon> <value>"
--- (icon optional, set with the binding) joined by a space.

local M = {}

local st = {
  bindings = {},  -- ordered {{ key, value, icon }}
}

local function find(key)
  for i, b in ipairs(st.bindings) do
    if b.key == key then return i end
  end
  return nil
end

--- Set (or clear with nil value) a binding; upsert keeps declaration order.
--- An optional icon is carried for the winbar/context-line display.
--- @param key string
--- @param value string|nil
--- @param icon string|nil
function M.set(key, value, icon)
  local i = find(key)
  if value == nil then
    if i then table.remove(st.bindings, i) end
  elseif i then
    st.bindings[i].value = value
    st.bindings[i].icon = icon
  else
    st.bindings[#st.bindings + 1] = { key = key, value = value, icon = icon }
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

--- Context-line display: "-" or each binding rendered as its optional icon
--- followed by the value, joined by a space. Icons are set by the context
--- (e.g. poste-db passes "connection"/"database" glyphs via the slash api).
function M.render()
  if #st.bindings == 0 then return "-" end
  local parts = {}
  for _, b in ipairs(st.bindings) do
    parts[#parts + 1] = (b.icon and (b.icon .. " ") or "") .. b.value
  end
  return table.concat(parts, " ")
end

--- Persistence shape.
function M.to_list()
  local out = {}
  for _, b in ipairs(st.bindings) do
    local rec = { key = b.key, value = b.value }
    if b.icon then rec.icon = b.icon end
    out[#out + 1] = rec
  end
  return out
end

function M.from_list(list)
  st.bindings = {}
  for _, b in ipairs(list or {}) do
    if b.key and b.value then
      st.bindings[#st.bindings + 1] = { key = b.key, value = b.value, icon = b.icon }
    end
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
