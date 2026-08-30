--- Conversation buffer composition — owns the message list of the chat
--- buffer (`poste://chat`), its layout (label line + content + separator),
--- and the render extmarks. Window/keymap concerns live in `chat/window.lua`;
--- streaming orchestration lives in `chat/stream.lua`.
---
--- Invariant: buffer content is exactly the message texts (raw markdown for
--- assistant turns) joined by blank separators, so copying from the buffer is
--- always faithful. All styling is extmarks-only.

local render = require("poste-ai.chat.render")
local tshl = require("poste-ai.chat.tshl")

local M = {}

local st = {
  buf = nil,
  ns = nil,
  messages = {},  -- { role, text, model, kind, _ids }
  rows = {},      -- message index → { label_row, content_start, content_end } (0-based)
  source_mode = false,
}

local LABELS = {
  user = "❯ You",
  error = "✗ error",
}
local LABEL_GROUPS = {
  user = "PosteAiUserLabel",
  assistant = "PosteAiAssistantLabel",
  error = "PosteAiErrorLabel",
}

local function label_for(msg)
  if msg.role == "assistant" then return "✦ " .. (msg.model or "assistant") end
  return LABELS[msg.role]
end

--- Timestamp text for a message, defaulting to now when unset.
--- @param ts number|nil unix seconds
--- @return string
local function ts_text(ts)
  if type(ts) ~= "number" or ts <= 0 then ts = os.time() end
  return os.date("%m-%d %H:%M:%S", ts)
end

local function content_lines(msg)
  return vim.split(msg.text or "", "\n", { plain = true })
end

local function line_count(buf)
  return vim.api.nvim_buf_line_count(buf)
end

local function buf_ready()
  return st.buf ~= nil and vim.api.nvim_buf_is_valid(st.buf)
end

--- Width of the window showing the conversation buffer (nil when hidden).
--- @return number|nil
local function conv_width()
  if not buf_ready() then return nil end
  for _, w in ipairs(vim.fn.win_findbuf(st.buf)) do
    if vim.api.nvim_win_is_valid(w) then return vim.api.nvim_win_get_width(w) end
  end
  return nil
end

--- Build the buffer lines of one message block; returns lines + row anchors.
--- `start_row` is the 0-based row the block will begin at.
local function block_lines(msg, start_row)
  local out = {}
  local label = label_for(msg)
  local rows = { label_row = nil, content_start = start_row, content_end = start_row }
  if label then
    out[#out + 1] = label
    rows.label_row = start_row
    rows.content_start = start_row + 1
  end
  local clines = content_lines(msg)
  for _, l in ipairs(clines) do out[#out + 1] = l end
  rows.content_end = rows.content_start + #clines - 1
  return out, rows
end

local function modify(buf, fn)
  local was = vim.api.nvim_get_option_value("modifiable", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", was, { buf = buf })
  if not ok then error(err) end
end

local function delete_marks(msg)
  if not st.buf or not msg._ids then return end
  for _, id in ipairs(msg._ids) do
    pcall(vim.api.nvim_buf_del_extmark, st.buf, st.ns, id)
  end
  msg._ids = nil
end

--- Apply highlight extmarks for one message. `off` shifts 0-based content rows.
local function apply_marks(msg, off)
  if st.source_mode or not buf_ready() then return end
  delete_marks(msg)
  local max_row = line_count(st.buf) - 1
  local clines = content_lines(msg)
  local specs = render.specs(clines)
  local ids = {}

  local function mark(row, col, length, group, end_row, end_col, hl_mode, conceal, hl_eol)
    if row > max_row then return end
    local opts = {
      id = nil,
      hl_group = group,
      end_row = end_row or row,
      end_col = end_col or (col + length),
      hl_mode = hl_mode or "replace",
    }
    if conceal then opts.conceal = conceal end
    if hl_eol then opts.hl_eol = true end
    if length == 0 and not end_row then return end
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, st.buf, st.ns, row, col, opts)
    if ok and id then ids[#ids + 1] = id end
  end

  for _, bg in ipairs(specs.bg_ranges) do
    -- one hl_eol extmark per row (fences included): the highlight paints to
    -- the window edge on every screen row, wrapped lines included — no width
    -- math needed. Treesitter marks below combine on top of the background.
    for r = bg.start - 1 + off, bg.end_ + 1 + off do
      if r >= 0 and r <= max_row then
        mark(r, 0, 0, bg.group, r + 1, 0, "combine", nil, true)
      end
    end
  end
  for _, m in ipairs(specs.marks) do
    mark(m.row + off, m.col, m.length, m.group, nil, nil, nil, m.conceal)
  end
  -- treesitter syntax highlighting inside fenced code blocks
  for _, cb in ipairs(specs.code_blocks) do
    if cb.text ~= "" then
      local base = cb.start + off
      for _, h in ipairs(tshl.specs(cb.text, cb.lang)) do
        mark(h.row + base, h.col, 0, h.group, h.end_row + base, h.end_col, "combine")
      end
    end
  end

  -- labels & special content styling
  local rows = nil
  for i, msg_i in ipairs(st.messages) do
    if msg_i == msg then rows = st.rows[i] break end
  end
  if rows then
    if rows.label_row ~= nil then
      local label = label_for(msg)
      local group = LABEL_GROUPS[msg.role] or "PosteAiAssistantLabel"
      mark(rows.label_row, 0, #label, group)
      -- right-aligned gray timestamp on the label row; virt text only, so the
      -- buffer text stays untouched (copy/yank exactness preserved). Leave a
      -- 1-column right margin — text flush at the window edge gets clipped.
      local ts = ts_text(msg.ts)
      local width = conv_width() or 60
      local pad = math.max(1, width - 1 - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(ts))
      local ok_vt, id_vt = pcall(vim.api.nvim_buf_set_extmark, st.buf, st.ns, rows.label_row, 0, {
        virt_text = {
          { string.rep(" ", pad), "PosteAiTimestamp" },
          { ts, "PosteAiTimestamp" },
        },
        virt_text_pos = "eol",
      })
      if ok_vt and id_vt then ids[#ids + 1] = id_vt end
    end
    if msg.role == "error" then
      for r = rows.content_start, rows.content_end do
        mark(r, 0, #(clines[r - off + 1] or ""), "PosteAiErrorText")
      end
    elseif msg.role == "note" then
      for r = rows.content_start, rows.content_end do
        mark(r, 0, #(clines[r - off + 1] or ""), "PosteAiNote")
      end
    elseif msg.role == "user" then
      for r = rows.content_start, rows.content_end do
        local line = clines[r - off + 1] or ""
        local pos = 1
        while true do
          local s, e = line:find("@[%S]+", pos)
          if not s then break end
          while e > s and (line:sub(e, e):match("[.,%)]")) do e = e - 1 end
          mark(r, s - 1, e - s + 1, "PosteAiMention")
          pos = e + 1
        end
      end
    end
  end
  msg._ids = ids
end

--- Attach to a (fresh) conversation buffer and reset all state.
function M.attach(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  st.buf = buf
  st.ns = vim.api.nvim_create_namespace("poste_ai_chat_render")
  st.messages = {}
  st.rows = {}
  modify(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end)
end

function M.buffer() return st.buf end
function M.is_empty() return #st.messages == 0 end
function M.is_source_mode() return st.source_mode end

--- Full rebuild from a message list (session switch/restore).
--- @param messages table { role, text, model } — note: no extmark ids
function M.set_messages(messages)
  if not buf_ready() then return end
  st.messages = {}
  st.rows = {}
  local all = {}
  for i, msg in ipairs(messages) do
    if i > 1 then all[#all + 1] = "" end
    local stored = { role = msg.role, text = msg.text, model = msg.model, ts = msg.ts }
    st.messages[#st.messages + 1] = stored
    local lines, rows = block_lines(stored, #all)
    for _, l in ipairs(lines) do all[#all + 1] = l end
    st.rows[#st.rows + 1] = rows
  end
  modify(st.buf, function()
    vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, all)
  end)
  for i, msg in ipairs(st.messages) do
    apply_marks(msg, st.rows[i].content_start)
  end
end

--- Append a new message at the bottom. `msg = { role, text, model }`.
--- @return table the stored message
function M.append(msg)
  if not buf_ready() then return nil end
  local stored = { role = msg.role, text = msg.text or "", model = msg.model, ts = msg.ts }
  local sep = #st.messages > 0

  -- A fresh/emptied buffer still reports one empty line; the first block must
  -- replace it rather than append after it.
  local virgin = false
  if not sep then
    local cur = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    virgin = (#cur == 0) or (#cur == 1 and cur[1] == "")
  end
  -- Non-virgin appends go after the last line (+1 more for the blank
  -- separator row); virgin buffers replace their single empty line.
  local start_row = virgin and 0 or (line_count(st.buf) + (sep and 1 or 0))
  local lines, rows = block_lines(stored, start_row)

  st.messages[#st.messages + 1] = stored
  st.rows[#st.rows + 1] = rows
  modify(st.buf, function()
    if virgin then
      vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
    else
      local all = sep and { "" } or {}
      for _, l in ipairs(lines) do all[#all + 1] = l end
      vim.api.nvim_buf_set_lines(st.buf, -1, -1, false, all)
    end
  end)
  apply_marks(stored, rows.content_start)
  return stored
end

--- Replace the text of the last assistant message (streaming updates).
function M.update_last_assistant(text)
  if not buf_ready() then return end
  local last = st.messages[#st.messages]
  if not last or last.role ~= "assistant" then return end
  local rows = st.rows[#st.rows]
  last.text = text
  local clines = content_lines(last)
  rows.content_end = rows.content_start + #clines - 1
  modify(st.buf, function()
    vim.api.nvim_buf_set_lines(st.buf, rows.content_start, -1, false, clines)
  end)
  apply_marks(last, rows.content_start)
end

function M.append_user(text) return M.append({ role = "user", text = text, ts = os.time() }) end
function M.append_error(text) return M.append({ role = "error", text = text, ts = os.time() }) end
function M.append_note(text) return M.append({ role = "note", text = text, ts = os.time() }) end

--- Begin an empty assistant turn (placeholder for streaming).
--- @param model string|nil
function M.begin_assistant(model)
  return M.append({ role = "assistant", text = "", model = model, ts = os.time() })
end

--- User questions for the outline drawer, newest first.
--- @return table[] { text, ts, row, idx } `row` is the 0-based buffer row of the label
function M.outline_entries()
  local out = {}
  for i, msg in ipairs(st.messages) do
    if msg.role == "user" and msg.text and msg.text ~= "" then
      local rows = st.rows[i]
      out[#out + 1] = {
        text = msg.text,
        ts = msg.ts,
        row = rows.label_row or rows.content_start,
        idx = i,
      }
    end
  end
  -- newest first; same-second messages keep their conversation order
  table.sort(out, function(a, b)
    local at, bt = a.ts or 0, b.ts or 0
    if at ~= bt then return at > bt end
    return a.idx > b.idx
  end)
  return out
end

--- Truncate a string to fit `limit` display columns, appending "...".
--- @param text string
--- @param limit number
--- @return string
local function truncate(text, limit)
  if limit <= 3 then return vim.fn.strcharpart(text, 0, math.max(0, limit - 3)) .. "..." end
  local n = vim.fn.strchars(text)
  for i = 0, n do
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, i)) > limit - 3 then
      return vim.fn.strcharpart(text, 0, math.max(0, i - 1)) .. "..."
    end
  end
  return text
end

--- Title of the chat block under a buffer row — the user question of the turn
--- whose block starts at or before `row` (an assistant answer belongs to the
--- preceding question). Returns nil above the first block.
--- @param row number 0-based buffer row
--- @return string|nil
function M.block_title_at(row)
  local title = nil
  for i, msg in ipairs(st.messages) do
    if msg.role == "user" and msg.text and msg.text ~= "" then
      local start_row = st.rows[i].label_row or st.rows[i].content_start
      if start_row > row then break end
      title = msg.text
    end
  end
  return title
end

--- Index (1-based) of the chat block under a buffer row plus the total number
--- of blocks. Blocks are user questions; an answer belongs to the preceding
--- one. Index is nil above the first block.
--- @param row number 0-based buffer row
--- @return number|nil index
--- @return number total
function M.block_index_at(row)
  local total = 0
  for i, msg in ipairs(st.messages) do
    if msg.role == "user" and msg.text and msg.text ~= "" then total = total + 1 end
  end
  if total == 0 then return nil, 0 end
  local index = nil
  for i, msg in ipairs(st.messages) do
    if msg.role == "user" and msg.text and msg.text ~= "" then
      local start_row = st.rows[i].label_row or st.rows[i].content_start
      if start_row > row then break end
      index = (index or 0) + 1
    end
  end
  return index, total
end

--- Plain title for the statusline: the current chat block's user question,
--- truncated to fit the window width alongside the right-aligned block
--- counter. Returns "" when no block is under the cursor. No `%` markup —
--- statusline items in a `%{}` result are shown literally.
--- @return string
function M.statusline_title()
  if not buf_ready() then return "" end
  for _, w in ipairs(vim.fn.win_findbuf(st.buf)) do
    if vim.api.nvim_win_is_valid(w) then
      local row = vim.api.nvim_win_get_cursor(w)[1] - 1
      local width = vim.api.nvim_win_get_width(w)
      local title = M.block_title_at(row)
      if not title then return "" end
      local _, total = M.block_index_at(row)
      local counter_w = (total and total > 0) and vim.fn.strdisplaywidth(total .. "/" .. total) or 0
      title = (title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
      return truncate(title, math.max(4, width - counter_w - 6))
    end
  end
  return ""
end

--- Plain `index/total` counter of the block under the cursor, or "" when no
--- block. The gray chip around it lives in the statusline option string.
--- @return string
function M.statusline_counter()
  if not buf_ready() then return "" end
  for _, w in ipairs(vim.fn.win_findbuf(st.buf)) do
    if vim.api.nvim_win_is_valid(w) then
      local row = vim.api.nvim_win_get_cursor(w)[1] - 1
      local index, total = M.block_index_at(row)
      if not index or not total or total == 0 then return "" end
      return index .. "/" .. total
    end
  end
  return ""
end

--- Raw text of the last non-empty assistant message (for yank-last).
--- @return string|nil
function M.last_assistant_text()
  for i = #st.messages, 1, -1 do
    local m = st.messages[i]
    if m.role == "assistant" and m.text and m.text ~= "" then return m.text end
  end
end

--- All messages, shape suitable for persistence.
function M.messages()
  local out = {}
  for _, m in ipairs(st.messages) do
    out[#out + 1] = { role = m.role, text = m.text, model = m.model }
  end
  return out
end

--- Drop all extmarks (source view) or reapply (rendered view).
function M.set_source_mode(enabled)
  st.source_mode = enabled
  if not buf_ready() then return end
  if enabled then
    for _, msg in ipairs(st.messages) do delete_marks(msg) end
  else
    for i, msg in ipairs(st.messages) do
      apply_marks(msg, st.rows[i].content_start)
    end
  end
end

--- Re-apply all extmarks (e.g. window resize moves the right-aligned labels).
function M.redraw_marks()
  if not buf_ready() or st.source_mode then return end
  for i, msg in ipairs(st.messages) do
    apply_marks(msg, st.rows[i].content_start)
  end
end

function M.toggle_source_mode() M.set_source_mode(not st.source_mode) end

--- Find the fenced code block under a buffer row (0-based), if any.
--- @param row number 0-based buffer row
--- @return table|nil { lang, text, start_row, end_row }
function M.codeblock_at_row(row)
  for i, msg in ipairs(st.messages) do
    if msg.role == "assistant" and msg.text and msg.text ~= "" then
      local rows = st.rows[i]
      if row >= rows.content_start and row <= rows.content_end then
        local clines = content_lines(msg)
        local specs = render.specs(clines)
        for _, cb in ipairs(specs.code_blocks) do
          local abs_start = cb.start + rows.content_start
          local abs_end = cb.end_ + rows.content_start
          if row >= abs_start and row <= abs_end and cb.text ~= "" then
            return { lang = cb.lang, text = cb.text, start_row = abs_start, end_row = abs_end }
          end
        end
      end
    end
  end
  return nil
end

--- All code blocks across assistant messages (absolute rows).
function M.codeblocks()
  local out = {}
  for i, msg in ipairs(st.messages) do
    if msg.role == "assistant" and msg.text and msg.text ~= "" then
      local rows = st.rows[i]
      local clines = content_lines(msg)
      for _, cb in ipairs(render.specs(clines).code_blocks) do
        if cb.text ~= "" then
          out[#out + 1] = {
            lang = cb.lang, text = cb.text,
            start_row = cb.start + rows.content_start,
            end_row = cb.end_ + rows.content_start,
          }
        end
      end
    end
  end
  return out
end

--- Test hooks.
function M._state() return st end

return M
