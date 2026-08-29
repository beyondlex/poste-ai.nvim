describe("poste-ai.chat.history", function()
  local history = require("poste-ai.chat.history")
  local window = require("poste-ai.chat.window")
  local session = require("poste-ai.chat.session")

  before_each(function()
    window.open()
    session.set_current({
      id = "t", name = "t", created_at = 0, updated_at = 0,
      messages = {
        { role = "user", text = "first question" },
        { role = "assistant", text = "answer" },   -- skipped
        { role = "user", text = "second question" },
        { role = "user", text = "" },              -- skipped
      },
    })
  end)

  after_each(function()
    window.close()
    history.reset()
    session.set_current(nil)
  end)

  local function input() return window.input_text() end

  it("fills the previous question and walks back / forward", function()
    window.set_input_text("draft text")
    assert.is_true(history.up())
    assert.are.equal("second question", input())
    assert.is_true(history.up())
    assert.are.equal("first question", input())
    assert.is_true(history.down())
    assert.are.equal("second question", input())
    assert.is_true(history.down())
    assert.are.equal("draft text", input())  -- draft restored past the newest
    assert.is_false(history.down())          -- already at the draft
  end)

  it("only considers non-empty user messages", function()
    window.set_input_text("")
    assert.is_true(history.up())
    assert.are.equal("second question", input())
    assert.is_true(history.up())
    assert.are.equal("first question", input())
    assert.is_true(history.up())  -- oldest reached; stays there
    assert.are.equal("first question", input())
  end)

  it("repositions the cursor to the end of the filled text", function()
    window.set_input_text("")
    history.up()
    local win = window.input_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    assert.are.equal(1, cur[1])
    -- normal-mode cursor clamps onto the last char; insert mode sits after it
    assert.is_true(cur[2] >= #"second question" - 1)
  end)

  it("moves the cursor within a multi-line draft instead of history", function()
    window.set_input_text("line one\nline two")
    local win = window.input_win()
    vim.api.nvim_win_set_cursor(win, { 2, 3 })
    assert.is_true(history.up())
    assert.are.equal("line one\nline two", input())  -- unchanged
    local cur = vim.api.nvim_win_get_cursor(win)
    assert.are.equal(1, cur[1])
    assert.are.equal(3, cur[2])

    -- from the first line Up wraps to history; Down past the newest returns
    -- the full multi-line draft
    assert.is_true(history.up())
    assert.are.equal("second question", input())
    history.down()
    history.down()
    assert.are.equal("line one\nline two", input())
  end)

  it("returns false with no history and leaves the input alone", function()
    session.set_current({ id = "e", name = "e", created_at = 0, updated_at = 0, messages = {} })
    window.set_input_text("keep me")
    assert.is_false(history.up())
    assert.are.equal("keep me", input())
  end)

  it("reset() drops navigation state (draft no longer restored)", function()
    window.set_input_text("draft")
    history.up()
    window.clear_input()  -- submit path clears; must also drop the state
    window.set_input_text("new draft")
    assert.is_true(history.up())
    assert.are.equal("second question", input())
    history.down()
    history.down()
    assert.are.equal("new draft", input())  -- not the pre-clear "draft"
  end)
end)
