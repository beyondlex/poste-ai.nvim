describe("poste-ai.chat.window", function()
  local window = require("poste-ai.chat.window")
  local state = require("poste-ai.state")

  after_each(function()
    window.close()
  end)

  it("opens the two-pane layout with named scratch buffers", function()
    assert.is_true(window.open())
    assert.is_true(window.is_open())
    local conv_buf = window.conversation_buf()
    local input_buf = window.input_buf()
    assert.are.equal("poste://chat", vim.api.nvim_buf_get_name(conv_buf))
    assert.are.equal("poste://chat_input", vim.api.nvim_buf_get_name(input_buf))
    assert.are.equal("poste_ai_chat", vim.api.nvim_get_option_value("filetype", { buf = conv_buf }))
    assert.are.equal("poste_ai_input", vim.api.nvim_get_option_value("filetype", { buf = input_buf }))
    assert.is_false(vim.api.nvim_get_option_value("modifiable", { buf = conv_buf }))
    assert.is_true(vim.api.nvim_get_option_value("modifiable", { buf = input_buf }))
  end)

  it("reuses buffers across close/open cycles", function()
    window.open()
    local conv_buf = window.conversation_buf()
    window.close()
    assert.is_false(window.is_open())
    assert.is_true(vim.api.nvim_buf_is_valid(conv_buf))  -- hidden, not wiped
    window.open()
    assert.are.equal(conv_buf, window.conversation_buf())
  end)

  it("round-trips input text", function()
    window.open()
    window.set_input_text("line one\nline two")
    assert.are.equal("line one\nline two", window.input_text())
    window.clear_input()
    assert.are.equal("", window.input_text())
  end)

  it("records the origin buffer when opened from a named buffer", function()
    local scratch = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(scratch, vim.fn.getcwd() .. "/origin_test.sql")
    vim.api.nvim_set_current_buf(scratch)
    window.open()
    assert.are.equal(scratch, state.origin_buf)
  end)

  it("tracks the buffer the user edits while the chat is open", function()
    local first = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(first, vim.fn.getcwd() .. "/tracked_first.sql")
    vim.api.nvim_set_current_buf(first)
    window.open()
    assert.are.equal(first, state.origin_buf)

    -- recent-files style: open another file while the chat is up
    local second = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(second, vim.fn.getcwd() .. "/tracked_second.sql")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == first then vim.api.nvim_set_current_win(w) break end
    end
    vim.api.nvim_set_current_buf(second)
    assert.are.equal(second, state.origin_buf)

    -- entering chat panes does not clobber the origin
    window.focus_input(false)
    assert.are.equal(second, state.origin_buf)
    vim.api.nvim_buf_delete(first, { force = true })
    vim.api.nvim_buf_delete(second, { force = true })
  end)

  it("installs buffer-local keymaps", function()
    window.open()
    window.focus_input(false)
    -- insert mode: Enter inserts a newline, Alt+Enter submits
    assert.is_true(vim.tbl_isempty(vim.fn.maparg("<CR>", "i", false, true)))
    local submit_i = vim.fn.maparg("<M-Cr>", "i", false, true)
    assert.is_table(submit_i)
    assert.is_truthy(submit_i.buffer)
    -- normal mode: Enter submits directly
    local submit_n = vim.fn.maparg("<CR>", "n", false, true)
    assert.is_table(submit_n)
    assert.is_truthy(submit_n.buffer)
    -- Up/Down walk the question history (both modes)
    for _, lhs in ipairs({ "<Up>", "<Down>" }) do
      for _, mode in ipairs({ "n", "i" }) do
        local m = vim.fn.maparg(lhs, mode, false, true)
        assert.is_table(m, lhs .. " in " .. mode)
        assert.is_truthy(m.buffer)
      end
    end
    window.focus_chat()  -- conv keymaps resolve against the conversation buffer
    local toggle = vim.fn.maparg("R", "n", false, true)
    assert.is_table(toggle)
    assert.is_truthy(toggle.buffer)
  end)

  it("shows the chat scope at the leftmost of the context line only", function()
    local scope = require("poste-ai.chat.scope")
    window.open()
    -- empty scope → "-" on the input context line
    local line = vim.api.nvim_get_option_value("winbar", { win = window.input_win() })
    assert.truthy(line:find(" - ", 1, true))

    -- scoped → render as icon+value pairs on the context line
    scope.set("connection", "pg", "c")
    scope.set("database", "app", "d")
    line = vim.api.nvim_get_option_value("winbar", { win = window.input_win() })
    assert.truthy(line:find("c pg d app", 1, true))

    -- the conversation winbar carries no scope/context anymore
    local conv_winbar = vim.api.nvim_get_option_value("winbar", { win = window.conversation_win() })
    assert.is_nil(conv_winbar:find("pg", 1, true))
    assert.is_nil(conv_winbar:find("@", 1, true))
    assert.truthy(conv_winbar:find("PosteAI", 1, true))
    scope.clear()
  end)

  it("marks the input pane with a colored left gutter", function()
    window.open()
    local input_win = window.input_win()
    assert.are.equal("yes", vim.api.nvim_get_option_value("signcolumn", { win = input_win }))
    local col = vim.api.nvim_get_option_value("statuscolumn", { win = input_win })
    assert.is_truthy(col:find("PosteAiInputBorder", 1, true))
    -- the conversation pane keeps its clean layout
    assert.are.equal("no", vim.api.nvim_get_option_value("signcolumn", { win = window.conversation_win() }))
  end)

  it("pads code block rows to the window width with inline virtual text", function()
    local conversation = require("poste-ai.chat.conversation")
    window.open()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("```sql\nSELECT 1\n\nSELECT 2\n```")
    local ns = conversation._state().ns
    local conv_buf = window.conversation_buf()
    local width = vim.api.nvim_win_get_width(window.conversation_win())
    local padded = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(conv_buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text then padded[m[2]] = m[4].virt_text[1][1] end
    end
    -- rows: 0 label, 1 fence, 2 "SELECT 1", 3 empty, 4 "SELECT 2", 5 fence —
    -- fences are fully concealed (visible width 0), body rows keep 1 cell margin
    assert.are.equal(string.rep(" ", width - 1), padded[1])
    assert.are.equal(string.rep(" ", width - 1 - 8), padded[2])
    assert.are.equal(string.rep(" ", width - 1), padded[3])
    assert.are.equal(string.rep(" ", width - 1 - 8), padded[4])
    assert.are.equal(string.rep(" ", width - 1), padded[5])
  end)

  it("reports at_bottom correctly", function()
    window.open()
    local conv_win = window.conversation_win()
    assert.is_true(window.at_bottom(conv_win))  -- short buffer fits on screen
  end)

  it("scrolls the conversation pane to the newest block", function()
    window.open()
    local conversation = require("poste-ai.chat.conversation")
    local msgs = {}
    for i = 1, 50 do
      msgs[#msgs + 1] = { role = "user", text = "q" .. i }
      msgs[#msgs + 1] = { role = "assistant", text = "a" .. i }
    end
    conversation.set_messages(msgs)
    vim.api.nvim_win_set_height(window.conversation_win(), 3)
    vim.api.nvim_win_set_cursor(window.conversation_win(), { 1, 0 })  -- parked at the top

    window.scroll_conversation_to_end()
    local lines = vim.api.nvim_buf_get_lines(window.conversation_buf(), 0, -1, false)
    assert.are.equal(#lines, vim.api.nvim_win_get_cursor(window.conversation_win())[1])
    assert.truthy(lines[#lines]:find("a50"))
  end)

  it("redirects buffers opened into chat panes out to the editor window", function()
    window.open()
    -- what a picker's `buffer` jump does: display a file in the current
    -- (chat) window — the guard must move it to the editor window, restore
    -- the pane and focus the editor
    local picked = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(picked, vim.fn.getcwd() .. "/picked.sql")
    vim.api.nvim_set_current_win(window.input_win())
    vim.api.nvim_win_set_buf(window.input_win(), picked)

    assert.are.equal("poste://chat_input",
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window.input_win())))
    assert.are.equal("poste://chat",
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window.conversation_win())))
    -- focus follows on the next event-loop tick (deferred out of the API call)
    vim.wait(100, function() return vim.api.nvim_get_current_win() ~= window.input_win() end)
    local cur_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(window.input_win(), cur_win)
    assert.are_not.equal(window.conversation_win(), cur_win)
    assert.are.equal(picked, vim.api.nvim_win_get_buf(cur_win))
    vim.api.nvim_buf_delete(picked, { force = true })
    window.focus_chat()
  end)

  it("clamps the input pane to the configured height", function()
    window.open()
    local input_win = window.input_win()
    local cap = require("poste-ai.config").config.chat.input_height
    vim.api.nvim_win_set_height(input_win, cap + 5)
    window.enforce_input_height()
    assert.is_true(vim.api.nvim_win_get_height(input_win) <= cap)
    -- shrinking below the cap is left alone (nvim's minimum with a winbar is 2)
    vim.api.nvim_win_set_height(input_win, 1)
    window.enforce_input_height()
    assert.is_true(vim.api.nvim_win_get_height(input_win) < cap)
    window.close()
    window.open()  -- reopen restores the configured height
    assert.are.equal(cap, vim.api.nvim_win_get_height(window.input_win()))
  end)
end)
