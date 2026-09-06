--- Question outline — a drawer popup to the right of the chat pane listing
--- every user question of the current session (truncated title + right-aligned
--- gray timestamp). Pressing Enter jumps the conversation to that block. The
--- drawer closes on jump, `q`/`<Esc>`, or when it loses focus.

local config = require("poste-ai.config")
local state = require("poste-ai.state")
local truncate = require("poste-ai.text").truncate

local M = {}

local st = {
  win = nil,
  buf = nil,
  entries = {},  -- { text, ts, row } newest first
  lines = {},    -- rendered (truncated) buffer lines, parallel to entries
}

local DRAWER_WIDTH = 36

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = state.TITLE })
end

local function key(section, action)
  return config.get_keymap(section, action)
end

--- Truncate a title so its display width fits `limit` columns, appending "...".
--- Kept as a `_test`-visible alias — the implementation lives in `poste-ai.text`.
--- @param title string
--- @param limit number
--- @return string
function M._truncate(title, limit) return truncate(title, limit) end

--- Collapse internal whitespace to a single space (titles may be multi-line).
local function flatten(text)
  return (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Build the drawer buffer lines from entries for a given width.
--- @param entries table[] { text, ts, row }
--- @param width number drawer width in columns
--- @return string[] truncated titles (parallel to entries)
function M._render_lines(entries, width)
  local ts_w = vim.fn.strdisplaywidth("00:00:00")
  -- reserve 1 gap before the timestamp + 1 right margin so the padded row
  -- always fits (CJK titles otherwise overflow and clip the last digit)
  local avail = width - 2 - ts_w
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = M._truncate(flatten(e.text), math.max(1, avail))
  end
  return lines
end

function M.is_open()
  return st.win ~= nil and vim.api.nvim_win_is_valid(st.win)
end

--- Close the drawer (idempotent). The scratch buffer is kept for reuse.
function M.close()
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  st.win = nil
end

local function ensure_buf()
  if st.buf and vim.api.nvim_buf_is_valid(st.buf) then return st.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "poste://chat_outline")
  vim.api.nvim_set_option_value("filetype", "poste_ai_outline", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  st.buf = buf
  return buf
end

--- Jump the conversation window to the block of the selected row, then close.
local function jump_selected()
  if not M.is_open() then return end
  local line = vim.api.nvim_win_get_cursor(st.win)[1]
  local entry = st.entries[line]
  if not entry then M.close() return end
  local window = require("poste-ai.chat.window")
  local conv_win = window.conversation_win()
  if conv_win and vim.api.nvim_win_is_valid(conv_win) then
    pcall(vim.api.nvim_win_set_cursor, conv_win, { entry.row + 1, 0 })
    pcall(vim.fn.win_execute, conv_win, "normal! zz")
    vim.api.nvim_set_current_win(conv_win)
    local stream = require("poste-ai.chat.stream")
    stream.set_follow(window.at_bottom(conv_win))
  end
  M.close()
end

--- Open the outline drawer next to the chat pane.
function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(st.win)
    return
  end
  local window = require("poste-ai.chat.window")
  local conv_win = window.conversation_win()
  if not conv_win or not vim.api.nvim_win_is_valid(conv_win) then
    notify("open the chat first", vim.log.levels.WARN)
    return
  end

  local conversation = require("poste-ai.chat.conversation")
  local entries = conversation.outline_entries()
  if #entries == 0 then
    notify("no questions yet", vim.log.levels.INFO)
    return
  end
  st.entries = entries
  st.lines = M._render_lines(entries, DRAWER_WIDTH)

  local buf = ensure_buf()
  local ns = vim.api.nvim_create_namespace("poste_ai_outline")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, st.lines)
  local ts_w = vim.fn.strdisplaywidth("00:00:00")
  for i, e in ipairs(entries) do
    local title_w = vim.fn.strdisplaywidth(st.lines[i])
    local ts = os.date("%H:%M:%S", e.ts or os.time())
    local pad = math.max(1, DRAWER_WIDTH - 1 - title_w - ts_w)
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      virt_text = {
        { string.rep(" ", pad), "PosteAiTimestamp" },
        { ts, "PosteAiTimestamp" },
      },
      virt_text_pos = "eol",
    })
  end

  local width = DRAWER_WIDTH
  local height = math.max(3, vim.api.nvim_win_get_height(conv_win))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = conv_win,
    row = 0,
    col = vim.api.nvim_win_get_width(conv_win),
    width = width,
    height = height,
    style = "minimal",
    border = "single",
  })
  st.win = win
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("cursorlineopt", "line", { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })

  local function map(mode, lhs, handler, desc)
    if not lhs then return end
    vim.keymap.set(mode, lhs, handler, { noremap = true, silent = true, buffer = buf, desc = "PosteAI: " .. desc })
  end
  map("n", key("chat_outline", "jump"), jump_selected, "jump to question block")
  map("n", key("chat_outline", "close"), M.close, "close outline")
  map("n", key("chat_outline", "cancel"), M.close, "close outline")
  map("i", key("chat_outline", "cancel"), M.close, "close outline")

  -- closing on focus loss (BufLeave fires right after jump too — harmless)
  vim.api.nvim_create_autocmd("BufLeave", {
    group = vim.api.nvim_create_augroup("PosteAIOutline", { clear = true }),
    buffer = buf,
    callback = M.close,
  })
end

--- Toggle the drawer.
function M.toggle()
  if M.is_open() then
    M.close()
    return false
  end
  M.open()
  return M.is_open()
end

M._test = {
  state = st,
  width = DRAWER_WIDTH,
  truncate = M._truncate,
  render_lines = M._render_lines,
  jump = jump_selected,
}

return M