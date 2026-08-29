describe("poste-ai.chat.session", function()
  local config = require("poste-ai.config")
  local session = require("poste-ai.chat.session")

  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname() .. "-sessions"
    config.merge({ sessions_dir = tmp_dir })
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
    config.config = vim.deepcopy(config.defaults)
    session.set_current(nil)
  end)

  it("creates a new current session", function()
    local s = session.new("my chat")
    assert.are.equal("my chat", s.name)
    assert.are.equal(0, #s.messages)
    assert.are.equal(s.id, session.current().id)
  end)

  it("saves, lists, loads and switches", function()
    local s = session.new()
    s.messages = { { role = "user", text = "hi" }, { role = "assistant", text = "hello" } }
    assert.is_true(session.save(s))

    local listed = session.list()
    assert.are.equal(1, #listed)
    assert.are.equal(2, listed[1].count)

    local loaded = session.load(s.id)
    assert.are.equal(s.id, loaded.id)
    assert.are.equal("assistant", loaded.messages[2].role)

    session.set_current(nil)
    local switched = session.switch(s.id)
    assert.are.equal(s.id, switched.id)
    assert.are.equal(s.id, session.current().id)
  end)

  it("restores the last session via the pointer file", function()
    local s = session.new("keepme")
    session.save(s)
    session.set_current(nil)
    local restored = session.load_last()
    assert.is_not_nil(restored)
    assert.are.equal("keepme", restored.name)
  end)

  it("deletes sessions and clears current", function()
    local s = session.new()
    session.save(s)
    session.delete(s.id)
    assert.is_nil(session.load(s.id))
    assert.are.equal(0, #session.list())
    assert.are_not.equal(s.id, session.current().id)
  end)

  it("survives corrupt files", function()
    local s = session.new()
    vim.fn.mkdir(tmp_dir, "p")
    vim.fn.writefile({ "not json {" }, tmp_dir .. "/" .. s.id .. ".json")
    assert.is_nil(session.load(s.id))
  end)
end)
