--- Input history navigation — Up walks back through previously sent user
--- messages (questions), Down forward again, like shell history. The current
--- draft is preserved: navigating down past the newest entry restores it.
--- Cursor-aware: on a multi-line draft the arrows move within the text and
--- only wrap to history from the first (Up) / last (Down) line.

local M = {}

local st = {
  pos = nil,   -- index into the question list while navigating; nil = at draft
  draft = nil, -- input text captured when navigation started
}

--- The questions of the current session, oldest → newest.
local function questions()
  local out = {}
  local ok, session = pcall(require, "poste-ai.chat.session")
  if not ok then return out end
  for _, m in ipairs(session.current().messages or {}) do
    if m.role == "user" and m.text and m.text ~= "" then
      out[#out + 1] = m.text
    end
  end
  return out
end

--- Replace the input text and park the cursor at its end.
local function set_text(text)
  local w = require("poste-ai.chat.window")
  w.set_input_text(text or "")
  local win = w.input_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local lines = vim.api.nvim_buf_get_lines(w.input_buf(), 0, -1, false)
    local last = #lines
    vim.api.nvim_win_set_cursor(win, { last, #lines[last] })
  end
end

--- Up arrow: previous question, or a plain cursor move on a multi-line draft.
--- @return boolean true when handled (history filled or cursor moved)
function M.up()
  local w = require("poste-ai.chat.window")
  local win = w.input_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] > 1 then
    local above = vim.api.nvim_buf_get_lines(w.input_buf(), cursor[1] - 2, cursor[1] - 1, false)[1] or ""
    vim.api.nvim_win_set_cursor(win, { cursor[1] - 1, math.min(cursor[2], #above) })
    return true
  end

  local list = questions()
  if #list == 0 then return false end
  if st.pos == nil then
    st.draft = w.input_text()
    st.pos = #list
  else
    st.pos = math.max(1, math.min(st.pos - 1, #list))
  end
  set_text(list[st.pos])
  return true
end

--- Down arrow: next question, restore the draft past the newest one, or a
--- plain cursor move on a multi-line draft.
--- @return boolean true when handled
function M.down()
  local w = require("poste-ai.chat.window")
  local win = w.input_win()
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local last = vim.api.nvim_buf_line_count(w.input_buf())
  if cursor[1] < last then
    local below = vim.api.nvim_buf_get_lines(w.input_buf(), cursor[1], cursor[1] + 1, false)[1] or ""
    vim.api.nvim_win_set_cursor(win, { cursor[1] + 1, math.min(cursor[2], #below) })
    return true
  end

  if st.pos == nil then return false end
  local list = questions()
  st.pos = st.pos + 1
  if st.pos > #list then
    st.pos = nil
    set_text(st.draft)
    st.draft = nil
    return true
  end
  set_text(list[st.pos])
  return true
end

--- Drop navigation state (the draft is abandoned).
function M.reset()
  st.pos = nil
  st.draft = nil
end

function M._state() return st end

return M
