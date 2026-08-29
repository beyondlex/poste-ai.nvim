describe("poste-ai.chat.conversation", function()
  local conversation = require("poste-ai.chat.conversation")
  local window = require("poste-ai.chat.window")

  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    conversation.attach(buf)
  end)

  local function lines()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  it("appends messages with labels and blank separators", function()
    conversation.append_user("hello world")
    conversation.append({ role = "assistant", text = "reply", model = "m1" })

    local ls = lines()
    assert.are.same({ "❯ You", "hello world", "", "✦ m1", "reply" }, ls)
  end)

  it("replaces the virgin empty line with the first block", function()
    assert.are.same({ "" }, lines())
    conversation.append_user("first")
    assert.are.same({ "❯ You", "first" }, lines())
  end)

  it("updates the last assistant message in place", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("part one")
    conversation.update_last_assistant("part one\npart two")
    local ls = lines()
    assert.are.same({ "✦ m1", "part one", "part two" }, ls)
  end)

  it("locates code blocks by buffer row", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("text\n```sql\nSELECT 1\nSELECT 2\n```\ntail")
    -- rows: 0 label, 1 text, 2 fence, 3-4 code, 5 fence, 6 tail
    local cb = conversation.codeblock_at_row(3)
    assert.is_not_nil(cb)
    assert.are.equal("sql", cb.lang)
    assert.are.equal("SELECT 1\nSELECT 2", cb.text)
    assert.are.equal(3, cb.start_row)
    assert.are.equal(4, cb.end_row)
    assert.is_nil(conversation.codeblock_at_row(1))  -- plain text row
    assert.is_nil(conversation.codeblock_at_row(6))  -- tail row
  end)

  it("collects code blocks across messages", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("```lua\nprint('a')\n```")
    conversation.append_user("next")
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("```sql\nSELECT 1\n```")
    local blocks = conversation.codeblocks()
    assert.are.equal(2, #blocks)
    assert.are.equal("lua", blocks[1].lang)
    assert.are.equal("sql", blocks[2].lang)
  end)

  it("applies and toggles render extmarks", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("# Heading\n```sql\nSELECT 1\n```")
    local ns = conversation._state().ns
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_true(#marks > 0)

    conversation.set_source_mode(true)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    assert.is_true(conversation.is_source_mode())

    conversation.toggle_source_mode()
    assert.is_true(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0)
  end)

  it("sets conceal opts on marker extmarks (display-only; buffer keeps raw text)", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("# Heading\n- item\n```sql\nSELECT 1\n```")
    local ns = conversation._state().ns
    local concealed = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].conceal ~= nil then concealed[#concealed + 1] = m end
    end
    -- heading prefix, bullet "- ", both fence lines
    assert.is_true(#concealed >= 4)
    -- raw markdown is untouched in the buffer
    assert.are.same(
      { "✦ m1", "# Heading", "- item", "```sql", "SELECT 1", "```" },
      lines())
  end)

  it("applies treesitter highlight marks inside code blocks when a parser exists", function()
    local has_lua = pcall(vim.treesitter.get_string_parser, "", "lua")
    if not has_lua then return end
    local tshl = require("poste-ai.chat.tshl")
    tshl._test._reset()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("```lua\nlocal x = 1\n```")
    local ns = conversation._state().ns
    local ts_groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local g = m[4].hl_group
      if g and g:find("^@") then ts_groups[#ts_groups + 1] = g end
    end
    assert.is_true(#ts_groups > 0)
  end)

  it("rebuilds from a stored message list", function()
    conversation.set_messages({
      { role = "user", text = "q1" },
      { role = "assistant", text = "a1", model = "m" },
    })
    assert.are.same({ "❯ You", "q1", "", "✦ m", "a1" }, lines())
    assert.are.equal(2, #conversation.messages())
  end)

  it("yanks the last non-empty assistant text", function()
    assert.is_nil(conversation.last_assistant_text())
    conversation.begin_assistant("m")
    assert.is_nil(conversation.last_assistant_text())  -- still empty
    conversation.update_last_assistant("answer here")
    assert.are.equal("answer here", conversation.last_assistant_text())
  end)

  it("renders error and note messages with styling", function()
    conversation.append_error("boom happened")
    conversation.append_note("fyi")
    local ls = lines()
    assert.are.same({ "✗ error", "boom happened", "", "fyi" }, ls)
    local ns = conversation._state().ns
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_true(#marks >= 3)
  end)

  it("shows a right-aligned timestamp virt text on label rows without touching the buffer", function()
    conversation.append_user("hello")
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("reply")
    local ns = conversation._state().ns
    local labels = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text then labels[#labels + 1] = m end
    end
    assert.are.equal(2, #labels)
    for _, m in ipairs(labels) do
      local chunks = m[4].virt_text
      assert.truthy(chunks[#chunks][1]:match("^%d%d%-%d%d %d%d:%d%d:%d%d$"))
    end
    -- virt text never lands in the buffer
    assert.are.same({ "❯ You", "hello", "", "✦ m1", "reply" }, lines())
  end)

  it("pads the timestamp to the window width", function()
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 0, col = 0, width = 60, height = 5,
    })
    conversation.append_user("hello")
    local ns = conversation._state().ns
    local vt
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].virt_text then vt = m[4].virt_text break end
    end
    assert.is_not_nil(vt)
    local pad = #vt[1][1]
    local ts = vt[2][1]
    -- timestamp ends one column before the window edge (60 - 1 margin)
    assert.are.equal(59, vim.fn.strdisplaywidth("❯ You") + pad + vim.fn.strdisplaywidth(ts))
    pcall(vim.api.nvim_win_close, win, true)
  end)

  describe("block title / statusline", function()
    it("resolves the block title under a buffer row", function()
      conversation.append_user("first question")
      conversation.append({ role = "assistant", text = "a1", model = "m" })
      conversation.append_user("second question")
      conversation.append({ role = "assistant", text = "a2", model = "m" })
      -- rows: 0 label, 1 q1, 2 blank, 3 label, 4 a1, 5 blank, 6 label, 7 q2, ...
      assert.are.equal("first question", conversation.block_title_at(0))
      assert.are.equal("first question", conversation.block_title_at(4))   -- inside first answer
      assert.are.equal("second question", conversation.block_title_at(6))
      assert.are.equal("second question", conversation.block_title_at(10)) -- inside second answer
    end)

    it("returns nil above the first question block", function()
      conversation.append_note("ready")
      conversation.append_user("q")
      assert.is_nil(conversation.block_title_at(0))
    end)

    it("statusline truncates the title to the window width", function()
      conversation.append_user("统计每个author发了几条消息统计每个统计每个")
      -- no window shows the buffer here → empty
      assert.are.equal("", conversation.statusline_title())
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor", row = 0, col = 0, width = 40, height = 5,
      })
      conversation.append({ role = "assistant", text = "a", model = "m" })
      vim.api.nvim_win_set_cursor(win, { 2, 0 })  -- first answer line
      local s = conversation.statusline_title()
      assert.is_not_equal("", s)
      -- the title is plain text (no % markup leaks through)
      assert.falsy(s:find("%%", 1, true))
      assert.is_true(vim.fn.strdisplaywidth(s) <= 40)
      pcall(vim.api.nvim_win_close, win, true)
    end)

    it("reports the block index and total under a row", function()
      conversation.append_user("q1")
      conversation.append({ role = "assistant", text = "a1", model = "m" })
      conversation.append_user("q2")
      conversation.append({ role = "assistant", text = "a2", model = "m" })
      conversation.append_user("q3")
      local idx, total = conversation.block_index_at(0)   -- q1 label
      assert.are.equal(1, idx)
      assert.are.equal(3, total)
      idx = conversation.block_index_at(4)                -- inside q1's answer
      assert.are.equal(1, idx)
      idx = conversation.block_index_at(6)                -- q2 label
      assert.are.equal(2, idx)
      idx = conversation.block_index_at(10)               -- q2's answer
      assert.are.equal(2, idx)
      -- above the first block (note row)
      conversation.set_messages({})
      conversation.append_note("ready")
      conversation.append_user("q")
      idx, total = conversation.block_index_at(0)
      assert.is_nil(idx)
      assert.are.equal(1, total)
    end)

    it("statusline counter reports the block position, markup stays in the option", function()
      window.open()
      local conv_win = window.conversation_win()
      conversation.set_messages({})
      conversation.append_user("q1")
      conversation.append({ role = "assistant", text = "a1", model = "m" })
      conversation.append_user("q2")
      conversation.append({ role = "assistant", text = "a2", model = "m" })
      -- rows: 0 label, 1 q1, 2 blank, 3 label, 4 a1, 5 blank, 6 label, 7 q2, ...
      vim.api.nvim_win_set_cursor(conv_win, { 5, 0 })  -- a1 content → 1/2
      assert.are.equal("1/2", conversation.statusline_counter())
      -- title is plain text with no % markup leaking through
      assert.truthy(conversation.statusline_title():find("q1", 1, true))
      assert.falsy(conversation.statusline_title():find("%%", 1, true))
      -- the chat window option carries the literal right-align + gray chip markup
      local opt = vim.api.nvim_get_option_value("statusline", { win = conv_win })
      assert.truthy(opt:find("%=", 1, true))                -- right-align separator
      assert.truthy(opt:find("PosteAiTimestampBg", 1, true)) -- gray chip group
    end)
  end)
end)
