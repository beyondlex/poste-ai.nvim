describe("poste-ai.chat.actions", function()
  local conversation = require("poste-ai.chat.conversation")
  local window = require("poste-ai.chat.window")
  local actions = require("poste-ai.chat.actions")
  local context_api = require("poste-ai.context_api")
  local state = require("poste-ai.state")

  local origin_buf
  local executed

  before_each(function()
    origin_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(origin_buf, vim.fn.getcwd() .. "/actions_origin.sql")
    vim.api.nvim_set_current_buf(origin_buf)
    window.open()  -- records origin_buf
    conversation.set_messages({})
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("before\n```sql\nSELECT 1\n```\nafter")
    executed = nil
  end)

  after_each(function()
    window.close()
    context_api.unregister("ac")
    context_api.set_active(nil)
    state.origin_buf = nil
    if vim.api.nvim_buf_is_valid(origin_buf) then
      vim.api.nvim_buf_delete(origin_buf, { force = true })
    end
  end)

  local function focus_code_row()
    window.focus_chat()
    local cb = conversation.codeblocks()[1]
    vim.api.nvim_win_set_cursor(window.conversation_win(), { cb.start_row + 1, 0 })
    return cb
  end

  it("finds the code block under the cursor", function()
    focus_code_row()
    local cb = actions.codeblock_under_cursor()
    assert.is_not_nil(cb)
    assert.are.equal("sql", cb.lang)
    assert.are.equal("SELECT 1", cb.text)
  end)

  it("yanks the code block", function()
    focus_code_row()
    actions.yank_codeblock()
    assert.truthy(vim.fn.getreg('"'):find("SELECT 1"))
  end)

  it("yanks the last assistant answer", function()
    actions.yank_last_answer()
    assert.truthy(vim.fn.getreg('"'):find("```sql"))
  end)

  it("appends the code block to the origin buffer", function()
    focus_code_row()
    actions.append_codeblock()
    local origin_lines = vim.api.nvim_buf_get_lines(origin_buf, 0, -1, false)
    assert.are.equal("SELECT 1", origin_lines[#origin_lines])
  end)

  it("jumps between code blocks", function()
    conversation.begin_assistant("m1")
    conversation.update_last_assistant("```lua\nprint(1)\n```")
    focus_code_row()  -- on first block (sql)
    actions.jump_codeblock(1)
    local cb = actions.codeblock_under_cursor()
    assert.is_not_nil(cb)
    assert.are.equal("lua", cb.lang)
    actions.jump_codeblock(-1)
    cb = actions.codeblock_under_cursor()
    assert.are.equal("sql", cb.lang)
  end)

  it("executes via the active context with lang gate and refs", function()
    context_api.register("ac", {
      codeblock = {
        langs = { "sql" },
        execute = function(text, refs, cb)
          executed = { text = text, refs = refs }
          cb(nil, "executed ok")
        end,
      },
    })
    context_api.set_active("ac")
    focus_code_row()
    actions.execute_codeblock()

    assert.is_not_nil(executed)
    assert.are.equal("SELECT 1", executed.text)

    -- cursor off any block → nothing executes
    executed = nil
    window.focus_chat()
    vim.api.nvim_win_set_cursor(window.conversation_win(), { 2, 0 })  -- "before" text row
    actions.execute_codeblock()
    assert.is_nil(executed)
  end)

  it("refuses to execute without an active context", function()
    focus_code_row()
    actions.execute_codeblock()
    assert.is_nil(executed)
  end)

  it("survives a failing execute callback", function()
    context_api.register("ac", {
      codeblock = {
        langs = { "sql" },
        execute = function(text, refs, cb) cb("kaput", nil) end,
      },
    })
    context_api.set_active("ac")
    focus_code_row()
    actions.execute_codeblock()
    vim.wait(200, function()
      local ls = table.concat(vim.api.nvim_buf_get_lines(window.conversation_buf(), 0, -1, false), "\n")
      return ls:find("kaput") ~= nil
    end)
    local ls = table.concat(vim.api.nvim_buf_get_lines(window.conversation_buf(), 0, -1, false), "\n")
    assert.truthy(ls:find("kaput"))
  end)
end)
