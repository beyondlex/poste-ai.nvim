--- Generic list popup floating ABOVE the chat input window (agent-style
--- command palette). The popup owns the window + selection state and installs
--- temporary insert-mode keymaps (<Up>/<Down>/<C-n>/<C-p>/<CR>/<Tab>/<Esc>)
--- on the input buffer while open, restoring whatever was mapped before.
--- Item semantics ({label, description, ...payload}) belong to the caller.

local M = {}

local MAX_HEIGHT = 8

local st = {
  buf = nil,
  win = nil,
  items = {},
  sel = 1,
  on_select = nil,
  on_cancel = nil,
  saved_maps = nil,
  input_buf = nil,
}

local function window_mod()
  local ok, w = pcall(require, "poste-ai.chat.window")
  return ok and w or nil
end

local function render()
  if not st.win or not vim.api.nvim_win_is_valid(st.win) then return end
  local lines = {}
  local width = 1
  for _, it in ipairs(st.items) do
    local line = " " .. (it.label or "")
    if it.description and it.description ~= "" then
      line = line .. "  " .. it.description
    end
    lines[#lines + 1] = line
    if #line > width then width = #line end
  end
  if #lines == 0 then lines = { " (no matches)" } end
  st.buf = st.buf and vim.api.nvim_buf_is_valid(st.buf) and st.buf
    or vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(st.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(st.buf, "modifiable", false)

  local max_w = 40
  if st.input_win and vim.api.nvim_win_is_valid(st.input_win) then
    max_w = vim.api.nvim_win_get_width(st.input_win) - 2
  end
  vim.api.nvim_win_set_config(st.win, {
    width = math.max(math.min(width + 1, max_w), 8),
    height = math.min(#lines, MAX_HEIGHT),
  })
  if st.sel > #st.items then st.sel = math.max(#st.items, 1) end
  vim.api.nvim_win_set_cursor(st.win, { st.sel, 0 })
end

local function restore_maps()
  if not st.saved_maps or not st.input_buf or not vim.api.nvim_buf_is_valid(st.input_buf) then return end
  for _, m in ipairs(st.saved_maps) do
    if m.existing then
      vim.keymap.set("i", m.lhs, m.existing.callback or m.existing.rhs, {
        buffer = st.input_buf, noremap = true, silent = true, desc = m.existing.desc,
      })
    else
      pcall(vim.api.nvim_buf_del_keymap, st.input_buf, "i", m.lhs)
    end
  end
  st.saved_maps = nil
end

local function choose()
  local item = M.selected()
  local cb = st.on_select
  M.close()
  if item and cb then vim.schedule(function() cb(item) end) end
end

local function temp_maps(buf)
  local keys = { "<Up>", "<Down>", "<C-n>", "<C-p>", "<CR>", "<Tab>", "<Esc>" }
  st.saved_maps = {}
  for _, lhs in ipairs(keys) do
    local existing = vim.fn.maparg(lhs, "i", false, true)
    st.saved_maps[#st.saved_maps + 1] = {
      lhs = lhs,
      existing = (type(existing) == "table" and existing.buffer == 1) and existing or nil,
    }
  end
  local function map(lhs, fn)
    vim.keymap.set("i", lhs, fn, { noremap = true, silent = true, buffer = buf })
  end
  map("<Up>", function() M.move(-1) end)
  map("<Down>", function() M.move(1) end)
  map("<C-n>", function() M.move(1) end)
  map("<C-p>", function() M.move(-1) end)
  map("<CR>", choose)
  map("<Tab>", choose)
  map("<Esc>", function()
    local cb = st.on_cancel
    M.close()
    if cb then vim.schedule(cb) end
  end)
end

--- Open (or re-target) the popup above the input window.
--- @param items table[] {label, description, ...}
--- @param opts table|nil { on_select = function(item), on_cancel = function() }
function M.open(items, opts)
  opts = opts or {}
  st.items = items or {}
  st.sel = 1
  st.on_select = opts.on_select
  st.on_cancel = opts.on_cancel
  local w = window_mod()
  local input_win = w and w.input_win()
  local input_buf = w and w.input_buf()
  if not input_win or not vim.api.nvim_win_is_valid(input_win) then return end
  if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end
  st.input_win = input_win
  st.input_buf = input_buf

  if not st.win or not vim.api.nvim_win_is_valid(st.win) then
    if not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
      st.buf = vim.api.nvim_create_buf(false, true)
    end
    vim.api.nvim_buf_set_option(st.buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(st.buf, "swapfile", false)
    -- anchored above the input window: popup bottom-left at its top-left cell
    st.win = vim.api.nvim_open_win(st.buf, false, {
      relative = "win",
      win = input_win,
      anchor = "SW",
      row = 0,
      col = 0,
      width = 30,
      height = 1,
      style = "minimal",
      border = "rounded",
      zindex = 50,
    })
    vim.api.nvim_win_set_option(st.win, "wrap", false)
    vim.api.nvim_win_set_option(st.win, "cursorline", true)
    vim.api.nvim_win_set_option(st.win, "cursorlineopt", "line")
    vim.api.nvim_win_set_option(st.win, "winhighlight", "CursorLine:PosteAiPopupSel,Normal:PosteAiPopup")
    if not st.saved_maps then temp_maps(input_buf) end
  end
  render()
end

function M.is_open()
  return st.win ~= nil and vim.api.nvim_win_is_valid(st.win)
end

--- Replace the item list, keeping the selection when possible.
function M.set_items(items)
  st.items = items or {}
  if st.sel > #st.items then st.sel = math.max(#st.items, 1) end
  if M.is_open() then render() end
end

function M.move(delta)
  if #st.items == 0 then return end
  st.sel = math.max(1, math.min(#st.items, st.sel + delta))
  if M.is_open() then vim.api.nvim_win_set_cursor(st.win, { st.sel, 0 }) end
end

--- Currently highlighted item (or nil when the list is empty).
function M.selected()
  return st.items[st.sel]
end

function M.close()
  restore_maps()
  st.input_win = nil
  st.input_buf = nil
  st.on_select = nil
  st.on_cancel = nil
  st.items = {}
  st.sel = 1
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  st.win = nil
end

M._test = {
  st = st,
  render = render,
  choose = choose,
}

return M
