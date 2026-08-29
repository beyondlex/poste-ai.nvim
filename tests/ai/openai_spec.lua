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
