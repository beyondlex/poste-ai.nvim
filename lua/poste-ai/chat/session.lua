--- Chat session management — multiple named sessions persisted as JSON under
--- `stdpath("data")/poste-ai/sessions/`, with a `current.json` pointer so the
--- last session is restored on next start.

local config = require("poste-ai.config")

local M = {}

local st = { current = nil }

local function dir() return config.sessions_dir() end
local function path_for(id) return dir() .. "/" .. id .. ".json" end

local function ensure_dir()
  pcall(vim.fn.mkdir, dir(), "p")
end

local function make_id()
  -- second-resolution timestamp plus a wide random tail: two sessions created
  -- in the same second must not overwrite each other's file
  return vim.fn.strftime("%Y%m%d-%H%M%S")
    .. "-" .. string.format("%06x", math.random(0, 0xffffff))
end

--- Start a fresh session and make it current.
--- @param name string|nil
function M.new(name)
  st.current = {
    id = make_id(),
    name = name or ("chat " .. vim.fn.strftime("%Y-%m-%d %H:%M")),
    created_at = os.time(),
    updated_at = os.time(),
    messages = {},
  }
  return st.current
end

--- The current session, loading/restoring/creating as needed.
function M.current()
  if not st.current then st.current = M.load_last() or M.new() end
  return st.current
end

--- Persist a session (or the current one) + update the pointer file.
--- @param s table|nil
--- @return boolean
function M.save(s)
  s = s or st.current
  if not s then return false end
  ensure_dir()
  local ok, encoded = pcall(vim.json.encode, { version = 1, session = s })
  if not ok then return false end
  local ok_w = pcall(vim.fn.writefile, { encoded }, path_for(s.id))
  pcall(vim.fn.writefile, { vim.json.encode({ id = s.id }) }, dir() .. "/current.json")
  return ok_w
end

--- Load a session by id. nil when missing/corrupt.
--- @param id string
--- @return table|nil
function M.load(id)
  local ok, raw = pcall(vim.fn.readfile, path_for(id))
  if not ok then return nil end
  local ok_j, obj = pcall(vim.json.decode, table.concat(raw, "\n"), { luanil = { object = true, array = true } })
  if ok_j and type(obj) == "table" and type(obj.session) == "table" then
    return obj.session
  end
  return nil
end

--- Most recently used session id from the pointer file.
local function last_id()
  local ok, raw = pcall(vim.fn.readfile, dir() .. "/current.json")
  if not ok then return nil end
  local ok_j, obj = pcall(vim.json.decode, table.concat(raw, "\n"))
  if ok_j and type(obj) == "table" then return obj.id end
end

function M.load_last()
  local id = last_id()
  if not id then return nil end
  return M.load(id)
end

--- List sessions, newest first: { {id, name, updated_at, count} }.
function M.list()
  ensure_dir()
  local out = {}
  local ok, files = pcall(vim.fn.readdir, dir())
  if not ok or type(files) ~= "table" then return out end
  for _, f in ipairs(files) do
    local id = f:match("^(.+)%.json$")
    if id and id ~= "current" then
      local s = M.load(id)
      if s then
        out[#out + 1] = {
          id = s.id, name = s.name or id,
          updated_at = s.updated_at or 0,
          count = #(s.messages or {}),
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.updated_at > b.updated_at end)
  return out
end

--- Switch to a stored session (also updates the pointer).
--- @param id string
--- @return table|nil
function M.switch(id)
  local s = M.load(id)
  if not s then return nil end
  st.current = s
  M.save(s)
  return s
end

--- Delete a session file; clears current when it points at it.
--- @param id string
function M.delete(id)
  pcall(vim.fn.delete, path_for(id))
  if st.current and st.current.id == id then st.current = nil end
end

--- Append a non-chat record (role "error" or "note") to a session's message
--- list so these blocks survive reopen — previously they lived only in the
--- conversation buffer and vanished on the next render. `s` defaults to the
--- current session. LLM history (`history_messages`) ignores these roles.
--- @param role string "error"|"note"
--- @param text string
--- @param s table|nil owning session
--- @return table|nil the stored record
function M.append_record(role, text, s)
  s = s or st.current
  if not s or not text or text == "" then return nil end
  local rec = { role = role, text = text, ts = os.time() }
  s.messages[#s.messages + 1] = rec
  s.updated_at = rec.ts
  return rec
end

--- Test/low-level: set the current session without switching files.
function M.set_current(s) st.current = s end

function M._state() return st end

return M
