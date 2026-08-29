describe("poste-ai.chat.slash", function()
  local slash = require("poste-ai.chat.slash")
  local popup = require("poste-ai.chat.popup")
  local scope = require("poste-ai.chat.scope")
  local window = require("poste-ai.chat.window")
  local context_api = require("poste-ai.context_api")

  after_each(function()
    popup.close()
    window.close()
    scope.clear()
    context_api.set_active(nil)
    context_api.unregister("test")
  end)

  it("lists built-in commands plus active context commands", function()
    local names = {}
    for _, c in ipairs(slash.commands()) do names[#names + 1] = c.name end
    assert.are.same({ "new", "session", "models" }, names)

    context_api.register("test", {
      system_prompt = function() return "test" end,
      commands = {
        { name = "connections", desc = "pick a connection", complete = function() end, run = function() end },
        "garbage",  -- skipped: not a table with a name
      },
    })
    context_api.set_active("test")
    names = {}
    for _, c in ipairs(slash.commands()) do names[#names + 1] = c.name end
    assert.are.same({ "new", "session", "models", "connections" }, names)
  end)

  it("on_input_changed shows the palette for a '/' prefix and filters", function()
    window.open()
    window.set_input_text("/")
    slash.on_input_changed()
    assert.is_true(popup.is_open())
    assert.are.equal(3, #popup._test.st.items)

    window.set_input_text("/se")
    slash.on_input_changed()
    assert.are.equal(1, #popup._test.st.items)
    assert.are.equal("/session", popup.selected().label)

    window.set_input_text("hello")
    slash.on_input_changed()
    assert.is_false(popup.is_open())
  end)

  it("argument mode fetches candidates (sync and async)", function()
    context_api.register("test", {
      system_prompt = function() return "t" end,
      commands = {
        {
          name = "connections",
          desc = "pick",
          complete = function(prefix, sc, cb)
            -- async style
            vim.schedule(function()
              cb({ { label = "pg", description = "postgres" }, { label = "mysql", description = "mysql" } })
            end)
          end,
          run = function() end,
        },
      },
    })
    context_api.set_active("test")
    window.open()
    window.set_input_text("/connections")
    slash.on_input_changed()
    assert.are.equal("argument", slash._test.st.mode)
    assert.is_true(vim.wait(200, function() return #popup._test.st.items == 2 end))
    assert.are.equal("pg", popup.selected().label)

    -- prefix filtering is the command's job; typed prefix flows through
    window.set_input_text("/connections my")
    slash.on_input_changed()
    assert.is_true(vim.wait(200, function() return #popup._test.st.items == 2 end))

    -- sync style: complete returns the list directly
    popup.close()
    slash.reset()
    context_api.unregister("test")
    context_api.register("test", {
      system_prompt = function() return "t" end,
      commands = {
        {
          name = "conns",
          complete = function(prefix)
            return { { label = "a" .. prefix, description = "x" } }
          end,
          run = function() end,
        },
      },
    })
    context_api.set_active("test")
    window.set_input_text("/conns pg")
    slash.on_input_changed()
    assert.are.equal(1, #popup._test.st.items)
    assert.are.equal("apg", popup.selected().label)
  end)

  it("submit executes commands with the scope api and consumes the text", function()
    local got_item, got_scope
    context_api.register("test", {
      system_prompt = function() return "t" end,
      commands = {
        {
          name = "scope-me",
          complete = function() return { { label = "pg" } } end,
          run = function(item, api)
            got_item = item
            got_scope = api
            api.set_scope("connection", item.label, "c")
          end,
        },
      },
    })
    context_api.set_active("test")
    window.open()

    -- complete-style command via submit opens the palette for picking
    assert.is_true(slash.submit("/scope-me"))
    assert.is_true(popup.is_open())
    assert.are.equal("pg", popup.selected().label)
    -- simulate the popup Enter: runs the command with the selected item
    popup._test.choose()
    vim.wait(50, function() return got_item ~= nil end)
    assert.are.equal("pg", got_item.label)
    assert.are.equal("pg", scope.snapshot().connection)
    assert.are.equal("c pg", scope.render())
    assert.are.equal("pg", got_scope.scope().connection)
    got_scope.set_scope("database", "app")
    assert.are.equal("pg/app", scope.display())
    got_scope.clear_scope()
    assert.are.equal("-", scope.display())
    assert.is_false(popup.is_open())
  end)

  it("submit intercepts unknown single-word slash commands but passes the rest", function()
    assert.is_false(slash.submit("just a question"))
    assert.is_false(slash.submit("/bin/bash is a path"))  -- unknown but has args
    window.open()
    assert.is_true(slash.submit("/nope"))
    assert.are.equal("", window.input_text())
  end)

  it("built-in /new works through submit", function()
    local session = require("poste-ai.chat.session")
    local conversation = require("poste-ai.chat.conversation")
    window.open()
    session.new("old")
    scope.set("connection", "pg")
    assert.is_true(slash.submit("/new"))
    assert.are.equal("-", scope.display())
    assert.are.equal(1, #conversation.messages())  -- the "New session" note
  end)
end)
