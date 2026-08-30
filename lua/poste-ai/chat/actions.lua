--- Code-block actions on AI replies — execute (delegated to the active
--- context), yank, append-to-buffer, and jump between blocks.

local state = require("poste-ai.state")
local context_api = require("poste-ai.context_api")
local conversation = require("poste-ai.chat.conversation")
local window = require("poste-ai.chat.window")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = state.TITLE })
end

--- 0-based row of the cursor when it sits in the conversation window.
local function cursor_row()
  local buf = window.conversation_buf()
  if not buf then return nil end
  local win = window.conversation_win()
  if win and vim.api.nvim_get_current_win() == win then
    return vim.api.nvim_win_get_cursor(win)[1] - 1
  end
  if vim.api.nvim_get_current_buf() == buf then
    return vim.api.nvim_win_get_cursor(0)[1] - 1
  end
  return nil
end

--- The fenced code block under the cursor, or nil.
function M.codeblock_under_cursor()
  local row = cursor_row()
  if not row then return nil end
  return conversation.codeblock_at_row(row)
end

function M.yank_codeblock()
  local cb = M.codeblock_under_cursor()
  if not cb then notify("no code block under cursor", vim.log.levels.WARN) return end
  local lines = vim.split(cb.text, "\n", { plain = true })
  vim.fn.setreg('"', cb.text .. "\n")
  notify(("yanked code block (%s, %d lines)"):format(cb.lang ~= "" and cb.lang or "text", #lines))
end

function M.yank_last_answer()
  local text = conversation.last_assistant_text()
  if not text then notify("no assistant answer yet", vim.log.levels.WARN) return end
  vim.fn.setreg('"', text .. "\n")
  notify("yanked last assistant answer")
end

--- Jump to the next/previous code block relative to the cursor.
--- @param dir number 1 = next, -1 = previous
function M.jump_codeblock(dir)
  local blocks = conversation.codeblocks()
  if #blocks == 0 then notify("no code blocks in conversation", vim.log.levels.WARN) return end
  local row = cursor_row() or -1
  local target = nil
  if dir > 0 then
    for _, cb in ipairs(blocks) do
      if cb.start_row > row then target = cb break end
    end
  else
    for i = #blocks, 1, -1 do
      if blocks[i].end_row < row then target = blocks[i] break end
    end
  end
  if not target then notify("no more code blocks") return end
  local win = window.conversation_win()
  if not win then return end
  vim.api.nvim_win_set_cursor(win, { target.start_row + 1, 0 })
end

--- Append the block under the cursor to the origin buffer (the buffer that
--- was current when the chat opened).
function M.append_codeblock()
  local cb = M.codeblock_under_cursor()
  if not cb then notify("no code block under cursor", vim.log.levels.WARN) return end
  local buf = state.origin_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf)
    or not vim.api.nvim_get_option_value("modifiable", { buf = buf }) then
    notify("origin buffer unavailable or read-only", vim.log.levels.WARN)
    return
  end
  local lines = vim.split(cb.text, "\n", { plain = true })
  -- the context may bind the appended block to the chat scope (e.g. file
  -- directives); the hook owns the directive syntax, poste-ai owns placement
  local spec = context_api.active()
  local code_cfg = spec and spec.codeblock
  if type(code_cfg) == "table" and type(code_cfg.append_header) == "function" then
    local scope = require("poste-ai.chat.scope").snapshot()
    local ok_h, header = pcall(code_cfg.append_header, scope, cb.text)
    if ok_h and type(header) == "table" and #header > 0 then
      local prefixed = {}
      for _, l in ipairs(header) do prefixed[#prefixed + 1] = l end
      prefixed[#prefixed + 1] = ""
      for _, l in ipairs(lines) do prefixed[#prefixed + 1] = l end
      lines = prefixed
    end
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  local name = vim.api.nvim_buf_get_name(buf)
  notify(("appended %d lines to %s"):format(#lines, name ~= "" and vim.fn.fnamemodify(name, ":t") or "buffer"))
end

--- Execute the code block under the cursor via the active context.
--- Read-only confirm policies etc. are owned by the context.
function M.execute_codeblock()
  local cb = M.codeblock_under_cursor()
  if not cb then notify("no code block under cursor", vim.log.levels.WARN) return end
  local spec = context_api.active()
  local code_cfg = spec and spec.codeblock
  if not code_cfg or type(code_cfg.execute) ~= "function" then
    notify("no active context can execute code blocks", vim.log.levels.WARN)
    return
  end
  local langs = code_cfg.langs or {}
  if cb.lang ~= "" and not vim.tbl_contains(langs, cb.lang) then
    notify(("no handler for language %q"):format(cb.lang), vim.log.levels.WARN)
    return
  end
  if type(code_cfg.confirm) == "function" then
    local ok, proceed = pcall(code_cfg.confirm, cb.text)
    if not ok or not proceed then notify("aborted") return end
  end

  -- refs of the most recent user turn (e.g. which connection/db was mentioned)
  local refs = {}
  local session = require("poste-ai.chat.session")
  local msgs = session.current().messages
  for i = #msgs, 1, -1 do
    if msgs[i].role == "user" then refs = msgs[i].refs or {} break end
  end

  conversation.append_note("· executing " .. (cb.lang ~= "" and cb.lang or "code") .. " block …")
  local ok, err = pcall(code_cfg.execute, cb.text, refs, function(exec_err, note)
    vim.schedule(function()
      if exec_err then
        conversation.append_error(tostring(exec_err))
      elseif note then
        conversation.append_note(note)
      end
    end)
  end)
  if not ok then conversation.append_error("execute failed: " .. tostring(err)) end
end

M._test = { codeblock_under_cursor = M.codeblock_under_cursor }

return M
