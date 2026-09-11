describe("poste-ai.provider.openai", function()
  local openai = require("poste-ai.provider.openai")

  describe("endpoint", function()
    it("joins base_url and strips trailing slashes", function()
      assert.are.equal("https://api.openai.com/v1/chat/completions",
        openai.endpoint("https://api.openai.com/v1"))
      assert.are.equal("https://api.openai.com/v1/chat/completions",
        openai.endpoint("https://api.openai.com/v1///"))
    end)
  end)

  describe("build_request", function()
    it("builds curl args and a streaming body", function()
      local cfg = { base_url = "https://x/v1", model = "m1", api_key = "sk-secret" }
      local opts = {
        messages = { { role = "user", content = "hi" } },
        temperature = 0.2,
        max_tokens = 100,
        timeout_ms = 30000,
      }
      local args, body = openai.build_request(cfg, opts)
      local joined = table.concat(args, " ")
      assert.truthy(joined:find("%-N"))
      assert.truthy(joined:find("https://x/v1/chat/completions"))
      assert.truthy(joined:find("sk%-secret"))  -- in the auth header
      local decoded = vim.json.decode(body)
      assert.are.equal("m1", decoded.model)
      assert.are.equal(true, decoded.stream)
      assert.are.equal(0.2, decoded.temperature)
      assert.are.equal(100, decoded.max_tokens)
      assert.are.equal(1, #decoded.messages)
    end)

    it("omits the auth header when no api key", function()
      local args = openai.build_request({ base_url = "https://x/v1", model = "m" }, { messages = {} })
      local joined = table.concat(args, " ")
      assert.falsy(joined:find("Authorization"))
    end)

    it("omits optional request params when unset", function()
      local _, body = openai.build_request({ base_url = "https://x", model = "m" }, { messages = {} })
      local decoded = vim.json.decode(body)
      assert.is_nil(decoded.temperature)
      assert.is_nil(decoded.max_tokens)
    end)
  end)

  describe("extract_delta / extract_finish", function()
    it("extracts text deltas", function()
      local obj = { choices = { { delta = { content = "Hi" } } } }
      assert.are.equal("Hi", openai.extract_delta(obj))
      assert.is_nil(openai.extract_finish(obj))
    end)

    it("returns nil for role-only and finish chunks", function()
      assert.is_nil(openai.extract_delta({ choices = { { delta = {} } } }))
      assert.is_nil(openai.extract_delta({ choices = { { delta = { content = "" }, finish_reason = "stop" } } }))
      assert.are.equal("stop", openai.extract_finish({ choices = { { delta = {}, finish_reason = "stop" } } }))
    end)
  end)

  describe("error_from_body", function()
    it("extracts OpenAI error messages", function()
      local msg = openai.error_from_body({ error = { message = "bad key", type = "invalid_request_error" } })
      assert.are.equal("bad key (invalid_request_error)", msg)
    end)

    it("falls back to .message then to raw json", function()
      assert.are.equal("plain", openai.error_from_body({ message = "plain" }))
      assert.truthy(openai.error_from_body({ other = 1 }):find("other"))
    end)

    it("truncates very long messages", function()
      local msg = openai.error_from_body({ error = { message = string.rep("x", 1000) } })
      assert.is_true(#msg < 400)
    end)

    it("truncates CJK messages on a character boundary", function()
      -- 200 CJK chars = 600 bytes, cut at byte 300 lands mid-character;
      -- the byte-based sub notified invalid UTF-8
      local msg = openai.error_from_body({ error = { message = string.rep("\u{6570}", 200) } })
      assert.equals("…", msg:sub(-3))
      -- every character of the result decodes: strchars counts whole chars
      assert.is_true(vim.fn.strdisplaywidth(msg) < 310)
    end)
  end)

  it("maps curl exit codes", function()
    assert.are.equal("request timed out", openai._test.EXIT_MESSAGES[28])
    assert.are.equal("could not resolve host", openai._test.EXIT_MESSAGES[6])
  end)
end)

describe("poste-ai.provider.registry", function()
  local registry = require("poste-ai.provider.registry")

  it("resolves the default openai adapter", function()
    local adapter = registry.get({})
    assert.are.equal(require("poste-ai.provider.openai"), adapter)
  end)

  it("resolves by protocol override", function()
    registry.register("mockproto", "tests.ai.fixtures.mock_adapter")
    local adapter = registry.get({ protocol = "mockproto" })
    assert.is_not_nil(adapter)
    assert.are.equal("stream", type(adapter.stream) == "function" and "stream" or type(adapter))
    registry.register("mockproto", "poste-ai.provider.openai")  -- restore
  end)

  it("falls back to openai for unknown protocols", function()
    assert.are.equal(require("poste-ai.provider.openai"), registry.get({ protocol = "nope" }))
  end)
end)

describe("poste-ai.provider.openai _feed (stdout chunk boundary)", function()
  local openai = require("poste-ai.provider.openai")
  local sse = require("poste-ai.provider.sse")

  local function collect()
    local deltas, raws = {}, {}
    local parser = sse.new({
      on_data = function(payload)
        local ok, obj = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
        if ok and obj.choices and obj.choices[1] and obj.choices[1].delta
          and type(obj.choices[1].delta.content) == "string" then
          deltas[#deltas + 1] = obj.choices[1].delta.content
        end
      end,
      on_raw = function(line) raws[#raws + 1] = line end,
    })
    return parser, deltas, raws
  end

  it("reassembles a JSON line split across two stdout callbacks", function()
    local parser, deltas, raws = collect()
    -- transport chunk 1 ends mid-JSON: nvim's list has a single partial
    -- element (no trailing "")
    openai._feed(parser, { 'data: {"choices": [{"delta": {"content": " wo' })
    assert.are.same({}, deltas)
    -- chunk 2 completes the line
    openai._feed(parser, { 'rld"}}]}', '' })
    assert.are.same({ " wo" .. "rld" }, deltas)
    assert.are.equal(0, #raws)
    assert.are.equal("", parser:pending())
  end)

  it("buffers a partial-only chunk until the rest arrives", function()
    local parser, deltas = collect()
    openai._feed(parser, { 'data: {"choices": [{"delta": {"content": " he' })
    assert.are.same({}, deltas)
    assert.is_true(#parser:pending() > 0)
    openai._feed(parser, { 'llo"}}]}', '' })
    assert.are.same({ " hello" }, deltas)
  end)

  it("handles complete multi-line chunks and lone-newline separators", function()
    local parser, deltas = collect()
    openai._feed(parser, { 'data: {"choices": [{"delta": {"content": "a"}}]}', '' })
    openai._feed(parser, { '', '' })  -- a bare "\n" chunk (SSE event separator)
    openai._feed(parser, {
      'data: {"choices": [{"delta": {"content": "b"}}]}',
      'data: {"choices": [{"delta": {"content": "c"}}]}',
      '',
    })
    assert.are.same({ "a", "b", "c" }, deltas)
  end)
end)
