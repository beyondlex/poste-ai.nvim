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

  it("scrolls the origin window to the appended block", function()
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "-- existing", "SELECT 0;" })
    local origin_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == origin_buf then origin_win = w break end
    end
    assert.is_not_nil(origin_win)
    pcall(vim.api.nvim_win_set_cursor, origin_win, { 1, 0 })

    focus_code_row()
    actions.append_codeblock()
    -- cursor of the origin window sits on the first appended row
    assert.are.equal(3, vim.api.nvim_win_get_cursor(origin_win)[1])
  end)

  it("jumps the cursor into the target file by default (chat.append_focus)", function()
    focus_code_row()
    actions.append_codeblock()
    local origin_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == origin_buf then origin_win = w break end
    end
    assert.are.equal(origin_win, vim.api.nvim_get_current_win())
  end)

  it("appends to a file opened after the chat was opened", function()
    window.close()
    state.origin_buf = nil
    local scratch = vim.api.nvim_create_buf(true, false)  -- unnamed, e.g. a dashboard
    vim.api.nvim_set_current_buf(scratch)
    window.open()
    assert.is_nil(state.origin_buf)  -- nothing recordable at chat-open time

    -- recent-files opens a named sql file in the editor window afterwards
    local sql_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(sql_buf, vim.fn.getcwd() .. "/opened_later.sql")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == scratch then vim.api.nvim_set_current_win(w) break end
    end
    vim.api.nvim_set_current_buf(sql_buf)
    assert.are.equal(sql_buf, state.origin_buf)

    focus_code_row()
    actions.append_codeblock()
    local lines = vim.api.nvim_buf_get_lines(sql_buf, 0, -1, false)
    assert.are.equal("SELECT 1", lines[#lines])
    window.close()  -- tear the chat down before deleting the listed buffers
    vim.api.nvim_buf_delete(sql_buf, { force = true })
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)

  it("keeps chat focus when chat.append_focus is false", function()
    local config = require("poste-ai.config")
    config.config.chat.append_focus = false
    focus_code_row()
    actions.append_codeblock()
    local origin_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == origin_buf then origin_win = w break end
    end
    assert.are_not.equal(origin_win, vim.api.nvim_get_current_win())
    config.config.chat.append_focus = true
  end)

  it("prepends the context append_header and a blank line above the block", function()
    local got_scope, got_text
    context_api.register("ac", {
      codeblock = {
        langs = { "sql" },
        append_header = function(scope, text)
          got_scope, got_text = scope, text
          return { "-- @fake-conn " .. scope.connection }
        end,
      },
    })
    context_api.set_active("ac")
    local scope = require("poste-ai.chat.scope")
    scope.set("connection", "demo-conn")
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "-- existing", "SELECT 0;" })

    focus_code_row()
    actions.append_codeblock()
    assert.are.same({ connection = "demo-conn" }, got_scope)
    assert.are.equal("SELECT 1", got_text)

    local origin_lines = vim.api.nvim_buf_get_lines(origin_buf, 0, -1, false)
    assert.are.same({
      "-- existing", "SELECT 0;",
      "", "-- @fake-conn demo-conn", "SELECT 1",
    }, origin_lines)
    scope.clear()
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
