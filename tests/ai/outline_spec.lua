describe("poste-ai.chat.outline", function()
  local outline = require("poste-ai.chat.outline")
  local conversation = require("poste-ai.chat.conversation")
  local window = require("poste-ai.chat.window")

  after_each(function()
    local buf = outline._test.state.buf
    outline.close()
    window.close()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe("truncate", function()
    it("keeps short titles intact", function()
      assert.are.equal("hi", outline._test.truncate("hi", 20))
    end)

    it("appends ... to long titles within the width limit", function()
      local t = outline._test.truncate("a very long question that definitely exceeds the width", 20)
      assert.truthy(t:sub(-3) == "...")
      assert.is_true(vim.fn.strdisplaywidth(t) <= 20)
    end)

    it("measures CJK titles by display width", function()
      local t = outline._test.truncate("统计每个author发了几条消息统计每个", 20)
      assert.is_true(vim.fn.strdisplaywidth(t) <= 20)
      assert.truthy(t:find("...", 1, true))
    end)
  end)

  it("outline_entries lists user questions newest first with block rows", function()
    window.open()
    conversation.set_messages({})
    conversation.append_user("old question")
    conversation.append({ role = "assistant", text = "a", model = "m" })
    conversation.append_user("new question")
    local entries = conversation.outline_entries()
    assert.are.equal(2, #entries)
    assert.are.equal("new question", entries[1].text)
    assert.are.equal("old question", entries[2].text)
    -- rows point at each block's label line in the buffer (0-based)
    assert.are.equal(6, entries[1].row)
    assert.are.equal(0, entries[2].row)
    assert.is_true(type(entries[1].ts) == "number")
  end)

  it("opens a drawer with truncated titles and gray timestamps", function()
    window.open()
    conversation.set_messages({})
    conversation.append_user("统计每个author发了几条消息统计每个")
    conversation.append({ role = "assistant", text = "ok", model = "m" })
    conversation.append_user("short q")
    outline.open()
    assert.is_true(outline.is_open())
    local buf = outline._test.state.buf
    assert.are.equal("poste://chat_outline", vim.api.nvim_buf_get_name(buf))
    assert.are.equal("poste_ai_outline", vim.api.nvim_get_option_value("filetype", { buf = buf }))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(2, #lines)
    assert.are.equal("short q", lines[1])  -- newest first
    local ns = vim.api.nvim_create_namespace("poste_ai_outline")
    local vts = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text then
        vts = vts + 1
        local chunks = m[4].virt_text
        assert.truthy(chunks[#chunks][1]:match("^%d%d:%d%d:%d%d$"))
        -- marks are created in line order: the vts-th mark sits on the vts-th line
        local title_w = vim.fn.strdisplaywidth(lines[vts])
        local pad = #chunks[1][1]
        local ts_w = vim.fn.strdisplaywidth(chunks[#chunks][1])
        -- every row right-aligns to the same column: title + pad + ts = width - 1
        assert.are.equal(outline._test.width - 1, title_w + pad + ts_w)
      end
    end
    assert.are.equal(2, vts)
  end)

  it("jumps the conversation to the selected question block and closes", function()
    window.open()
    conversation.set_messages({})
    conversation.append_user("first")
    conversation.append({ role = "assistant", text = "ok", model = "m" })
    conversation.append_user("second")
    outline.open()
    local conv_win = window.conversation_win()
    local win = outline._test.state.win
    vim.api.nvim_win_set_cursor(win, { 1, 0 })  -- newest = "second"
    outline._test.jump()
    assert.is_false(outline.is_open())
    local cursor = vim.api.nvim_win_get_cursor(conv_win)
    assert.are.equal(7, cursor[1])  -- 1-based label row of the second user block
  end)
end)