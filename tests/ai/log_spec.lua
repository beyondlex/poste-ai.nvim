describe("poste-ai.log", function()
  local log = require("poste-ai.log")
  local config = require("poste-ai.config")

  local function log_file()
    return vim.fn.stdpath("data") .. "/poste-ai/logs/requests-" .. vim.fn.strftime("%Y-%m-%d") .. ".jsonl"
  end

  local function clear()
    pcall(vim.fn.delete, log_file())
  end

  before_each(function()
    config.config = vim.deepcopy(config.defaults)
    config.config.log = true
    clear()
  end)

  after_each(function()
    clear()
    config.config = vim.deepcopy(config.defaults)
  end)

  it("appends request and response records as JSONL", function()
    log.request({ endpoint = "https://x/v1/chat/completions", model = "m1", messages = { { role = "user", content = "hi" } } })
    log.response({ model = "m1", finish_reason = "stop", content = "Hello!", error = vim.NIL, raw = vim.NIL })

    local lines = vim.fn.readfile(log_file())
    assert.are.equal(2, #lines)
    local r1 = vim.json.decode(lines[1])
    local r2 = vim.json.decode(lines[2])
    assert.are.equal("request", r1.kind)
    assert.are.equal("m1", r1.model)
    assert.are.equal("hi", r1.messages[1].content)
    assert.are.equal("response", r2.kind)
    assert.are.equal("Hello!", r2.content)
    assert.are.equal("stop", r2.finish_reason)
    assert.are.equal(vim.NIL, r2.error)
  end)

  it("is a no-op when logging is disabled", function()
    config.config.log = false
    log.request({ model = "m" })
    log.response({ content = "x" })
    assert.are.equal(0, vim.fn.filereadable(log_file()))
  end)
end)