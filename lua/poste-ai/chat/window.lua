--- Chat window layout — a vertical split holding two stacked windows:
--- the conversation buffer (`poste://chat`) on top and the input buffer
--- (`poste://chat_input`) below. Buffers are created once and reused across
--- open/close cycles; all chat state lives in `conversation`/`session`.

local config = require("poste-ai.config")
local state = require("poste-ai.state")
local conversation = require("poste-ai.chat.conversation")

local M = {}

local st = {
  conv_win = nil,
  input_win = nil,
  conv_buf = nil,
  input_buf = nil,
  augroup = nil,
}

local CONV_BUF_NAME = "poste://chat"
local INPUT_BUF_NAME = "poste://chat_input"

local HELP_ACTIONS = {
  chat_window = {
    { "close", "close chat" },
    { "focus_input", "jump to input" },
    { "cancel", "cancel streaming" },
    { "toggle_render", "toggle markdown render/source" },
    { "show_outline", "show question outline" },
    { "execute_codeblock", "execute code block under cursor" },
    { "yank_codeblock", "yank code block under cursor" },
    { "append_codeblock", "append code block to origin buffer" },
    { "yank_last_answer", "yank last assistant answer" },
    { "next_codeblock", "next code block" },
    { "prev_codeblock", "previous code block" },
    { "help", "show this help" },
  },
  chat_input = {
    { "submit", "send message (normal mode)" },
    { "submit_insert", "send message (insert mode; Enter inserts newline)" },
    { "cancel", "cancel streaming" },
    { "focus_chat", "back to conversation" },
    { "new_session", "new session" },
    { "history_up", "previous question (from first line)" },
    { "history_down", "next question / restore draft" },
    { "complete_mention", "@mention completion" },
  },
}

local function create_conv_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, CONV_BUF_NAME)
  vim.api.nvim_set_option_value("filetype", "poste_ai_chat", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  conversation.attach(buf)
  return buf
end

local function create_input_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, INPUT_BUF_NAME)
  vim.api.nvim_set_option_value("filetype", "poste_ai_input", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.b[buf].completion = false
  return buf
end

local redirecting = false

--- The slash-command palette floats above the input window; when the panes go
--- away it must be closed explicitly or its temporary input keymaps would
--- survive the teardown and hijack the reused input buffer after a reopen.
local function close_popup()
  pcall(function() require("poste-ai.chat.popup").close() end)
end

--- A picker/command tried to display a foreign buffer in one of the chat
--- panes: reopen it in the user's editor window (preferring the window that
--- shows origin_buf) and restore the pane — the chat UI is never replaced
--- and nothing hard-fails (a winfixbuf E1513 from e.g. snacks.picker reads
--- like a crash). Fires from the BufEnter guard in setup_autocmds.
local function redirect_foreign_buffer(win, buf)
  if redirecting or not vim.api.nvim_win_is_valid(win) then return end
  redirecting = true
  pcall(function()
    local editor = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= st.conv_win and w ~= st.input_win and vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
        if state.origin_buf and vim.api.nvim_win_get_buf(w) == state.origin_buf then
          editor = w break  -- the user's working window wins
        end
        editor = editor or w
      end
    end
    if editor then
      vim.api.nvim_win_set_buf(editor, buf)
      -- focus cannot be changed from inside the caller's autocmd (nvim
      -- restores the invoking window when the API call returns), so defer it
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(editor) then
          pcall(vim.api.nvim_set_current_win, editor)
        end
      end)
    end
    vim.api.nvim_win_set_buf(win, (win == st.conv_win) and st.conv_buf or st.input_buf)
  end)
  redirecting = false
end

local function set_win_opts(win, kind)
  local opts = {
    wrap = true, linebreak = true, number = false, relativenumber = false,
    signcolumn = "no", foldcolumn = "0", spell = false, conceallevel = 0,
    winfixwidth = true, list = false,
  }
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
  if kind == "conv" then
    -- rendered view conceals markdown markers (display-only; yank keeps raw text)
    pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = win })
    pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })
    pcall(vim.api.nvim_set_option_value, "cursorlineopt", "line", { win = win })
    -- statusline: current block title + right-aligned gray block counter.
    -- `%{}` results are literal, so the %-items live in this option string.
    pcall(vim.api.nvim_set_option_value, "statusline",
      "%#PosteAiTimestamp#Q%* %{v:lua.require('poste-ai.chat.conversation').statusline_title()}"
      .. "%=%#PosteAiTimestampBg# %{v:lua.require('poste-ai.chat.conversation').statusline_counter()} %*",
      { win = win })
  elseif kind == "input" then
    -- colored left gutter so the input pane is visually distinct
    pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = win })
    pcall(vim.api.nvim_set_option_value, "statuscolumn", "%#PosteAiInputBorder#▍ ", { win = win })
  end
end

local function key(k)
  return config.get_keymap("chat_window", k)
end

local function input_key(k)
  return config.get_keymap("chat_input", k)
end

--- Build one keymap binding; `handler` is called with no args.
local function map(buf, mode, lhs, handler, desc)
  if not lhs then return end
  vim.keymap.set(mode, lhs, handler, { noremap = true, silent = true, buffer = buf, desc = "PosteAI: " .. desc })
end

local function apply_conv_keymaps(buf)
  local actions = require("poste-ai.chat.actions")
  local stream = require("poste-ai.chat.stream")
  map(buf, "n", key("close"), M.close, "close chat")
  map(buf, "n", key("focus_input"), function() M.focus_input(true) end, "jump to input")
  map(buf, "n", key("cancel"), function() stream.cancel() end, "cancel streaming")
  map(buf, "n", key("toggle_render"), function() conversation.toggle_source_mode() end, "toggle render/source")
  map(buf, "n", key("show_outline"), function() require("poste-ai.chat.outline").toggle() end, "show question outline")
  map(buf, "n", key("yank_last_answer"), function() actions.yank_last_answer() end, "yank last answer")
  map(buf, "n", key("next_codeblock"), function() actions.jump_codeblock(1) end, "next code block")
  map(buf, "n", key("prev_codeblock"), function() actions.jump_codeblock(-1) end, "previous code block")
  map(buf, "n", key("execute_codeblock"), function() actions.execute_codeblock() end, "execute code block")
  map(buf, "n", key("yank_codeblock"), function() actions.yank_codeblock() end, "yank code block")
  map(buf, "n", key("append_codeblock"), function() actions.append_codeblock() end, "append code block")
  map(buf, "n", key("help"), M.show_help, "show help")
end

local function apply_input_keymaps(buf)
  local stream = require("poste-ai.chat.stream")
  local submit = function() stream.submit_from_input() end
  map(buf, "n", input_key("submit"), submit, "send message")
  map(buf, "i", input_key("submit_insert", "<M-Cr>"), submit, "send message")
  local cancel = function()
    if stream.is_busy() then stream.cancel() else M.focus_chat() end
  end
  map(buf, "n", input_key("cancel"), cancel, "cancel streaming")
  map(buf, "i", input_key("cancel"), cancel, "cancel streaming")
  map(buf, "i", input_key("focus_chat"), function() M.focus_chat() end, "back to conversation")
  map(buf, "n", input_key("new_session"), function() require("poste-ai.commands").new_session() end, "new session")
  map(buf, "i", input_key("new_session"), function() require("poste-ai.commands").new_session() end, "new session")
  map(buf, "i", input_key("complete_mention", "<C-Space>"), M.trigger_mention, "@mention completion")
  local history = require("poste-ai.chat.history")
  map(buf, "n", input_key("history_up", "<Up>"), function() history.up() end, "previous question")
  map(buf, "i", input_key("history_up", "<Up>"), function() history.up() end, "previous question")
  map(buf, "n", input_key("history_down", "<Down>"), function() history.down() end, "next question")
  map(buf, "i", input_key("history_down", "<Down>"), function() history.down() end, "next question")
end

local function setup_autocmds()
  st.augroup = vim.api.nvim_create_augroup("PosteAIChatWindow", { clear = true })
  for _, win_key in ipairs({ "conv_win", "input_win" }) do
    local win_id = st[win_key]
    if win_id then
      vim.api.nvim_create_autocmd("WinClosed", {
        group = st.augroup,
        pattern = tostring(win_id),
        once = true,
        callback = function()
          st[win_key] = nil
          close_popup()
          -- when one pane dies, tear the other down with it
          local other = win_key == "conv_win" and "input_win" or "conv_win"
          if st[other] and vim.api.nvim_win_is_valid(st[other]) then
            pcall(vim.api.nvim_win_close, st[other], true)
          end
          st[other] = nil
        end,
      })
    end
  end
  -- keep tail-follow honest: user scrolled up → stop following
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = st.augroup,
    callback = function(args)
      if st.conv_win and args.file == tostring(st.conv_win) then
        local stream = require("poste-ai.chat.stream")
        stream.set_follow(M.at_bottom(st.conv_win))
      end
    end,
  })
  -- on resize: clamp the input pane height, re-align right-side label
  -- timestamps (dragging other windows can pull the input tall)
  vim.api.nvim_create_autocmd("WinResized", {
    group = st.augroup,
    callback = function()
      M.enforce_input_height()
      require("poste-ai.chat.conversation").redraw_marks()
    end,
  })
  -- keep origin_buf pointed at the file the user is actually working in
  -- while the chat is open (ga's append target, @mention path base). open()
  -- records the buffer current at chat-open time; afterwards every named,
  -- modifiable, non-chat buffer the user enters updates it — so opening a
  -- file AFTER the chat works too. The same event redirects buffers that a
  -- picker/command opened in a chat pane back out to the editor window.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = st.augroup,
    callback = function(args)
      if not M.is_open() then return end
      if not redirecting then
        for _, pane in ipairs({
          { win = st.conv_win, buf = st.conv_buf },
          { win = st.input_win, buf = st.input_buf },
        }) do
          if vim.api.nvim_win_is_valid(pane.win)
            and vim.api.nvim_win_get_buf(pane.win) ~= pane.buf then
            return redirect_foreign_buffer(pane.win, vim.api.nvim_win_get_buf(pane.win))
          end
        end
      end
      local buf = args.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf)
        or buf == st.conv_buf or buf == st.input_buf then return end
      local name = vim.api.nvim_buf_get_name(buf)
      if name == "" or name:find("^poste://") then return end
      if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then return end
      if not vim.api.nvim_get_option_value("modifiable", { buf = buf }) then return end
      state.origin_buf = buf
    end,
  })
  -- slash command palette: re-target the popup as the input text changes
  if st.input_buf and vim.api.nvim_buf_is_valid(st.input_buf) then
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = st.augroup,
      buffer = st.input_buf,
      callback = function() require("poste-ai.chat.slash").on_input_changed() end,
    })
  end
end

--- Open (or re-open) the chat sidebar. Returns true when a new window pair
--- was created, false when it was already open.
function M.open()
  if M.is_open() then return false end

  if not st.conv_buf or not vim.api.nvim_buf_is_valid(st.conv_buf) then
    st.conv_buf = create_conv_buf()
  end
  if not st.input_buf or not vim.api.nvim_buf_is_valid(st.input_buf) then
    st.input_buf = create_input_buf()
  end

  local origin = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(origin) and vim.api.nvim_buf_get_name(origin) ~= "" then
    state.origin_buf = origin
  end

  local chat_cfg = config.config.chat
  local side = chat_cfg.split_position == "left" and "topleft" or "botright"
  vim.cmd(string.format("%s %dvsplit", side, chat_cfg.split_width))
  st.conv_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.conv_win, st.conv_buf)
  set_win_opts(st.conv_win, "conv")

  vim.cmd(string.format("below %dsplit", chat_cfg.input_height))
  st.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.input_win, st.input_buf)
  set_win_opts(st.input_win, "input")

  apply_conv_keymaps(st.conv_buf)
  apply_input_keymaps(st.input_buf)
  setup_autocmds()
  M.update_winbar()
  M.update_context_line()
  return true
end

function M.is_open()
  return st.conv_win ~= nil and vim.api.nvim_win_is_valid(st.conv_win)
    and st.input_win ~= nil and vim.api.nvim_win_is_valid(st.input_win)
end

function M.close()
  close_popup()
  -- if focus sits in a chat pane, move it to a regular window first so the
  -- editor window (not some fallback) becomes current after the teardown
  local cur = vim.api.nvim_get_current_win()
  if (st.conv_win and cur == st.conv_win) or (st.input_win and cur == st.input_win) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= st.conv_win and w ~= st.input_win and vim.api.nvim_win_is_valid(w)
        and vim.api.nvim_win_get_config(w).relative == "" then
        pcall(vim.api.nvim_set_current_win, w)
        break
      end
    end
  end
  if st.conv_win and vim.api.nvim_win_is_valid(st.conv_win) then
    pcall(vim.api.nvim_win_close, st.conv_win, true)
  elseif st.input_win and vim.api.nvim_win_is_valid(st.input_win) then
    pcall(vim.api.nvim_win_close, st.input_win, true)
  end
  -- WinClosed autocmds clean the handles; also clear directly in case the
  -- autocmd didn't fire (e.g. last window edge cases)
  st.conv_win, st.input_win = nil, nil
end

function M.toggle()
  if M.is_open() then M.close() return false end
  M.open()
  return true
end

function M.conversation_win() return (st.conv_win and vim.api.nvim_win_is_valid(st.conv_win)) and st.conv_win or nil end
function M.input_win() return (st.input_win and vim.api.nvim_win_is_valid(st.input_win)) and st.input_win or nil end
function M.conversation_buf() return st.conv_buf end
function M.input_buf() return st.input_buf end

function M.focus_input(insert)
  local win = M.input_win()
  if not win then return end
  vim.api.nvim_set_current_win(win)
  local count = vim.api.nvim_buf_line_count(st.input_buf)
  pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
  if insert ~= false then vim.cmd("startinsert!") end
end

function M.focus_chat()
  local win = M.conversation_win()
  if not win then return end
  vim.api.nvim_set_current_win(win)
  vim.cmd("stopinsert")
end

--- Current input text (all lines joined).
--- @return string
function M.input_text()
  if not st.input_buf or not vim.api.nvim_buf_is_valid(st.input_buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\n")
end

function M.set_input_text(text)
  if not st.input_buf or not vim.api.nvim_buf_is_valid(st.input_buf) then return end
  local lines = vim.split(text or "", "\n", { plain = true })
  vim.api.nvim_set_option_value("modifiable", true, { buf = st.input_buf })
  vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, lines)
end

function M.clear_input()
  M.set_input_text("")
  require("poste-ai.chat.history").reset()
end

--- Update the conversation winbar with provider/model and stream state.
function M.update_winbar()
  local win = M.conversation_win()
  if not win then return end
  local cfg_ok, cfg = pcall(config.resolve_provider)
  local model = cfg_ok and cfg and (config.config.provider .. "/" .. cfg.model) or "no provider"
  local parts = { "%#PosteAiInputBorder#PosteAI%*" }
  parts[#parts + 1] = " · " .. model
  local stream = require("poste-ai.chat.stream")
  if stream.is_busy() then parts[#parts + 1] = " · ⟳" end
  pcall(vim.api.nvim_set_option_value, "winbar", table.concat(parts), { win = win })
end

--- Reserved context line above the input: leftmost scope display.
function M.update_context_line()
  local win = M.input_win()
  if not win then return end
  local scope = require("poste-ai.chat.scope")
  local parts = { "%#PosteAiInputBorder# " .. scope.render() .. " %*" }
  pcall(vim.api.nvim_set_option_value, "winbar", table.concat(parts), { win = win })
end

--- Clamp the input pane to `chat.input_height` — dragging other windows or
--- layout redistribution can pull it much taller than intended.
function M.enforce_input_height()
  local win = M.input_win()
  local cap = config.config.chat.input_height
  if win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_height(win) > cap then
    pcall(vim.api.nvim_win_set_height, win, cap)
  end
end

--- Scroll the conversation pane to the newest block (used on open and on
--- session switch, so the latest exchange is visible immediately).
function M.scroll_conversation_to_end()
  local win = M.conversation_win()
  local buf = M.conversation_buf()
  if not win or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
end

--- True when the last buffer line is visible in the window (tail-follow).
--- @param win number
function M.at_bottom(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  local ok, last_visible = pcall(vim.fn.line, "w$", win)
  local ok2, last_line = pcall(vim.fn.line, "$")
  if not ok or not ok2 then return false end
  return last_visible >= last_line - 1
end

--- Open the @mention completion popup for the input buffer.
function M.trigger_mention()
  local win = M.input_win()
  if not win or vim.api.nvim_get_current_win() ~= win then return end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_get_current_line()
  local col = cursor[2] + 1  -- 1-based col after cursor
  local at = nil
  for i = col, 1, -1 do
    local c = line:sub(i, i)
    if c == "@" then at = i break end
    if c:match("%s") then break end
  end
  if not at then
    vim.notify("poste-ai: no @mention under cursor", vim.log.levels.INFO, { title = state.TITLE })
    return
  end
  local prefix = line:sub(at + 1, col - 1)
  require("poste-ai.chat.mention").complete(prefix, at + 1)
end

--- Notify-style keymap cheat sheet (g?).
function M.show_help()
  local lines = { "PosteAI keymaps:", "  (in the input, type / for slash commands: /new /session /models …)" }
  for _, section in ipairs({ "chat_window", "chat_input" }) do
    lines[#lines + 1] = "  " .. section .. ":"
    for _, action in ipairs(HELP_ACTIONS[section]) do
      local k = config.format_keymap(section, action[1])
      if k ~= "" then
        lines[#lines + 1] = string.format("    %-10s %s", k, action[2])
      end
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = state.TITLE })
end

--- Test hooks.
function M._state() return st end
function M._help_actions() return HELP_ACTIONS end

return M
