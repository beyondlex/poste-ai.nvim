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
end)
