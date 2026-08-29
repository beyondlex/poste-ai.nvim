describe("poste-ai.chat.popup", function()
  local window = require("poste-ai.chat.window")
  local popup = require("poste-ai.chat.popup")

  local items = {
    { label = "/new", description = "new session" },
    { label = "/session", description = "switch session" },
    { label = "/models", description = "change model" },
  }

  after_each(function()
    popup.close()
    window.close()
  end)

  it("opens above the input window and tracks the selection", function()
    window.open()
    popup.open(items, {})
    assert.is_true(popup.is_open())
    assert.are.equal("/new", popup.selected().label)

    popup.move(1)
    assert.are.equal("/session", popup.selected().label)
    popup.move(-1)
    assert.are.equal("/new", popup.selected().label)
    popup.move(-5)  -- clamps
    assert.are.equal("/new", popup.selected().label)
    popup.move(99)
    assert.are.equal("/models", popup.selected().label)

    -- the popup floats above the input window (its bottom edge is at or
    -- above the input window's top edge)
    local conf = vim.api.nvim_win_get_config(popup._test.st.win)
    assert.are.equal(window.input_win(), conf.win)
    assert.are.equal("SW", conf.anchor)
  end)

  it("renders item lines into the popup buffer", function()
    window.open()
    popup.open(items, {})
    local buf = popup._test.st.buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(3, #lines)
    assert.are.same("/session", lines[2]:match("^%s*(/%S+)"))
  end)

  it("set_items replaces the list and clamps the selection", function()
    window.open()
    popup.open(items, {})
    popup.move(2)
    popup.set_items({ { label = "/only" } })
    assert.are.equal("/only", popup.selected().label)
    local lines = vim.api.nvim_buf_get_lines(popup._test.st.buf, 0, -1, false)
    assert.are.equal(1, #lines)
    popup.set_items({})  -- empty list renders a placeholder
    assert.is_nil(popup.selected())
  end)

  it("close tears the window down and restores keymaps", function()
    window.open()
    -- simulate a pre-existing buffer-local insert map that must survive
    local buf = window.input_buf()
    vim.keymap.set("i", "<C-n>", function() end, { buffer = buf, desc = "preexisting" })
    popup.open(items, {})
    local temp = vim.fn.maparg("<C-n>", "i", false, true)
    assert.is_truthy(temp.desc ~= "preexisting")

    popup.close()
    assert.is_false(popup.is_open())
    local restored = vim.fn.maparg("<C-n>", "i", false, true)
    assert.are.equal("preexisting", restored.desc)
    -- keys we did not shadow before stay unmapped
    assert.is_true(vim.tbl_isempty(vim.fn.maparg("<C-p>", "i", false, true)))
  end)

  it("on_select fires with the chosen item", function()
    window.open()
    local got = nil
    popup.open(items, { on_select = function(item) got = item end })
    popup.move(1)
    popup._test.choose()  -- the mapped <CR>/<Tab> handler
    vim.wait(50, function() return got ~= nil end)
    assert.are.equal("/session", got and got.label)
    assert.is_false(popup.is_open())
  end)
end)
