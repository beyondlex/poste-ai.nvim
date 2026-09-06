describe("poste-ai.chat.stream", function()
  local config = require("poste-ai.config")
  local registry = require("poste-ai.provider.registry")
  local stream = require("poste-ai.chat.stream")
  local conversation = require("poste-ai.chat.conversation")
  local window = require("poste-ai.chat.window")
  local session = require("poste-ai.chat.session")
  local context_api = require("poste-ai.context_api")
  local state = require("poste-ai.state")

  local tmp_dir
  local origin_buf

  before_each(function()
    tmp_dir = vim.fn.tempname() .. "-stream-sessions"
    config.merge({ sessions_dir = tmp_dir })
    config.config.provider = "mock"
    config.config.providers.mock = { base_url = "mock://x", model = "mock-1", protocol = "mock" }
    registry.register("mock", "tests.ai.fixtures.mock_adapter")
    require("tests.ai.fixtures.mock_adapter").reset({ "Hello", " world" }, 10)
    session.set_current(nil)
    window.open()
    conversation.set_messages({})
  end)

  after_each(function()
    stream.force_reset()
    window.close()
    vim.fn.delete(tmp_dir, "rf")
    config.config = vim.deepcopy(config.defaults)
    registry.register("mock", "poste-ai.provider.openai")
    context_api.unregister("tc")
    session.set_current(nil)
    state.origin_buf = nil
    if origin_buf and vim.api.nvim_buf_is_valid(origin_buf) then
      vim.api.nvim_buf_delete(origin_buf, { force = true })
    end
    origin_buf = nil
  end)

  local function conv_lines()
    return vim.api.nvim_buf_get_lines(window.conversation_buf(), 0, -1, false)
  end

  it("streams a reply end-to-end into conversation and session", function()
    assert.is_true(stream.send("hello there"))
    assert.is_true(stream.is_busy())
    vim.wait(3000, function() return not stream.is_busy() end)

    assert.is_false(stream.is_busy())
    -- conversation: user block + assistant reply
    local ls = table.concat(conv_lines(), "\n")
    assert.truthy(ls:find("❯ You"))
    assert.truthy(ls:find("hello there"))
    assert.truthy(ls:find("Hello world"))

    -- session persisted both turns
    local msgs = session.current().messages
    assert.are.equal(2, #msgs)
    assert.are.equal("user", msgs[1].role)
    assert.are.equal("assistant", msgs[2].role)
    assert.are.equal("Hello world", msgs[2].text)
  end)

  it("rejects empty input and concurrent sends", function()
    assert.is_false(stream.send("   "))
    -- occupy the stream with a slow mock
    require("tests.ai.fixtures.mock_adapter").reset({ "slow" }, 200)
    assert.is_true(stream.send("first"))
    assert.is_false(stream.send("second"))
    vim.wait(3000, function() return not stream.is_busy() end)
  end)

  it("rejects a send while an async compose is still pending", function()
    -- auto_context holds the compose open past the busy check: a second send
    -- during the window must be rejected or two composes would race
    local release
    context_api.register("tc", {
      auto_context = function(_text, _scope, cb) release = cb end,
    })
    context_api.set_active("tc")

    assert.is_true(stream.send("first"))
    assert.is_false(stream.is_busy())       -- composing, not streaming yet
    assert.is_false(stream.send("second"))  -- gated by the pending compose

    release(nil)
    -- compose runs on a scheduled tick: wait for the messages to land first
    vim.wait(3000, function() return #session.current().messages >= 2 end)
    vim.wait(3000, function() return not stream.is_busy() end)
    local msgs = session.current().messages
    assert.are.equal(2, #msgs)              -- exactly one exchange landed
    assert.are.equal("first", msgs[1].text)
    assert.are.equal("Hello world", msgs[2].text)
    context_api.set_active(nil)
  end)

  it("cancels an in-flight request and records a note", function()
    require("tests.ai.fixtures.mock_adapter").reset({ "chunk one", "chunk two", "chunk three" }, 60)
    assert.is_true(stream.send("cancel me"))
    vim.wait(1000, function() return stream.is_busy() end, 5)
    stream.cancel()
    vim.wait(3000, function() return not stream.is_busy() end)

    local ls = table.concat(conv_lines(), "\n")
    assert.truthy(ls:find("cancelled"))
    local msgs = session.current().messages
    assert.are.equal("assistant", msgs[#msgs].role)
    assert.is_true(#msgs[#msgs].text < #"chunk onechunk twochunk three")
  end)

  it("injects mention context into the LLM user content", function()
    context_api.register("tc", {
      mention = {
        match = function(token)
          local db = token:match("^tc/(%w+)$")
          if db then return { name = db } end
        end,
        resolve = function(ref, cb) cb("SCHEMA for " .. ref.name, nil) end,
      },
    })
    assert.is_true(stream.send("@tc/mydb run a query"))
    vim.wait(3000, function() return not stream.is_busy() end)

    local msgs = session.current().messages
    assert.are.equal("user", msgs[1].role)
    assert.truthy(msgs[1].content:find("SCHEMA for mydb"))
    assert.truthy(msgs[1].content:find("@tc/mydb run a query"))
  end)

  it("renders provider errors as an error block and keeps the session", function()
    registry.register("mock", "tests.ai.fixtures.failing_adapter")
    assert.is_true(stream.send("make it fail"))
    vim.wait(3000, function() return not stream.is_busy() end)
    local ls = table.concat(conv_lines(), "\n")
    assert.truthy(ls:find("✗ error"))
    assert.truthy(ls:find("mock exploded"))
    local msgs = session.current().messages
    assert.are.equal(2, #msgs)
    assert.is_true(msgs[#msgs].errored)
  end)

  it("leaves no stale handle when the adapter errors synchronously", function()
    registry.register("mock", {
      stream = function(_cfg, _opts, handlers)
        handlers.on_error("sync boom")
        return { cancel = function() end }
      end,
    })
    assert.is_true(stream.send("go"))
    vim.wait(1000, function() return not stream.is_busy() end)
    assert.is_false(stream.is_busy())
    assert.is_nil(stream._test.state.handle)  -- finalize's cleanup stands
    local ls = table.concat(conv_lines(), "\n")
    assert.truthy(ls:find("sync boom"))
  end)

  it("finalize survives a missing session_msg without wedging busy", function()
    -- defensive path: st.current without a session_msg must not crash
    -- finalize — an error there would leave busy stuck true forever
    local st = stream._test.state
    st.seq = st.seq + 1
    st.busy = true
    st.current = { assistant_text = "partial" }
    stream._test.finalize(st.seq, "boom", nil)
    assert.is_false(stream.is_busy())
    assert.is_nil(st.current)
  end)

  it("finalize saves the session the stream started in, not the one current now", function()
    -- user runs /session mid-stream: the reply belongs to the old session,
    -- and that is the file finalize must persist
    local st = stream._test.state
    local owner = session.new()
    local owner_msg = { role = "assistant", text = "", model = "mock-1" }
    owner.messages = { owner_msg }
    session.new()          -- a different session is current by finalize time
    assert.are_not.equal(owner.id, session.current().id)

    st.seq = st.seq + 1
    st.busy = true
    st.current = { assistant_text = "final text", session_msg = owner_msg, session = owner }
    stream._test.finalize(st.seq, nil, {})

    assert.are.equal("final text", owner.messages[1].text)
    local saved = session.load(owner.id)
    assert.is_not_nil(saved, "owning session must be persisted")
    assert.are.equal("final text", saved.messages[1].text)
  end)

  it("sends the composed history including the system prompt", function()
    local captured
    registry.register("mock", {
      stream = function(_cfg, opts, handlers)
        captured = opts.messages
        handlers.on_finish({ content = "ok", finish_reason = "stop" })
        return { cancel = function() end }
      end,
    })
    stream.send("capture me")
    vim.wait(1000, function() return not stream.is_busy() end)
    assert.is_not_nil(captured)
    assert.are.equal("system", captured[1].role)
    assert.truthy(captured[1].content:find("Neovim"))
    assert.are.equal(2, #captured)  -- system + user (assistant empty filtered)
    assert.are.equal("capture me", captured[2].content)
  end)

  it("records the chat scope on user messages and passes it to the system prompt", function()
    local scope = require("poste-ai.chat.scope")
    local captured_scope
    context_api.register("tc", {
      system_prompt = function(sc)
        captured_scope = sc
        return "domain knowledge"
      end,
    })
    context_api.set_active("tc")
    scope.set("connection", "pg")
    scope.set("database", "app")

    assert.is_true(stream.send("query something"))
    vim.wait(3000, function() return not stream.is_busy() end)

    assert.are.same({ connection = "pg", database = "app" }, captured_scope)
    local msgs = session.current().messages
    assert.are.equal("user", msgs[1].role)
    assert.are.same({ connection = "pg", database = "app" }, msgs[1].scope)
    -- the system prompt composed for the request contains the domain part
    local reqs = require("tests.ai.fixtures.mock_adapter").state.requests
    assert.is_true(#reqs > 0)
    assert.truthy(reqs[#reqs].opts.messages[1].content:find("domain knowledge"))

    context_api.set_active(nil)
    scope.clear()
  end)

  it("prepends the context auto_context block ahead of mention blocks", function()
    context_api.register("tc", {
      auto_context = function(_text, _scope, cb) cb("AUTO SCHEMA BLOCK") end,
      mention = {
        match = function(token)
          local db = token:match("^tc/(%w+)$")
          if db then return { name = db } end
        end,
        resolve = function(ref, cb) cb("MENTION BLOCK " .. ref.name, nil) end,
      },
    })
    context_api.set_active("tc")
    assert.is_true(stream.send("@tc/mydb check it"))
    -- compose runs on a scheduled tick: wait for the messages to land first
    vim.wait(3000, function() return #session.current().messages >= 2 end)
    vim.wait(3000, function() return not stream.is_busy() end)

    local content = session.current().messages[1].content
    local auto_at = content:find("AUTO SCHEMA BLOCK", 1, true)
    local mention_at = content:find("MENTION BLOCK mydb", 1, true)
    assert.truthy(auto_at)
    assert.truthy(mention_at)
    assert.is_true(auto_at < mention_at)
    context_api.set_active(nil)
  end)

  it("survives a failing auto_context and still sends", function()
    context_api.register("tc", {
      auto_context = function() error("auto boom") end,
    })
    context_api.set_active("tc")
    assert.is_true(stream.send("hello anyway"))
    vim.wait(3000, function() return #session.current().messages >= 2 end)
    vim.wait(3000, function() return not stream.is_busy() end)
    local msgs = session.current().messages
    assert.are.equal("hello anyway", msgs[1].content)
    assert.are.equal("Hello world", msgs[2].text)
    context_api.set_active(nil)
  end)

  it("re-engages tail-follow when sending after scrolling up", function()
    -- long history so the buffer overflows the pane
    local msgs = {}
    for i = 1, 60 do
      msgs[#msgs + 1] = { role = "user", text = "q" .. i }
      msgs[#msgs + 1] = { role = "assistant", text = "a" .. i }
    end
    conversation.set_messages(msgs)
    local conv_win = window.conversation_win()
    vim.api.nvim_win_set_height(conv_win, 3)
    vim.api.nvim_win_set_cursor(conv_win, { 1, 0 })  -- parked at the top
    stream.set_follow(false)                          -- user scrolled up

    assert.is_true(stream.send("jump to the end"))
    vim.wait(3000, function() return not stream.is_busy() end)

    local lines = vim.api.nvim_buf_line_count(window.conversation_buf())
    assert.are.equal(lines, vim.api.nvim_win_get_cursor(conv_win)[1])
    assert.is_true(stream.following())
  end)

  it("trims the sent history to request.history_max_bytes, newest wins", function()
    local captured
    registry.register("mock", {
      stream = function(_cfg, opts, handlers)
        captured = opts.messages
        handlers.on_finish({ content = "ok", finish_reason = "stop" })
        return { cancel = function() end }
      end,
    })
    local long_pad = string.rep("x", 70000)
    -- a huge first exchange that exceeds the budget on its own
    session.current().messages = {
      { role = "user", text = long_pad, content = long_pad },
      { role = "assistant", text = "first reply", content = "first reply" },
      { role = "user", text = "final question", content = "final question" },
    }
    assert.is_true(stream.send("and one more"))
    vim.wait(1000, function() return not stream.is_busy() end)

    -- the oversized first exchange is dropped; the newest prior user
    -- message ("final question") is the last history entry
    local contents = vim.tbl_map(function(m) return m.content end, captured)
    assert.falsy(vim.tbl_contains(contents, long_pad))
    assert.are.equal("final question", contents[#contents - 1])  -- newest kept
    assert.are.equal("and one more", contents[#contents])        -- in-flight msg last
    config.config.request.history_max_bytes = false  -- disable for remaining assertions
  end)
end)
