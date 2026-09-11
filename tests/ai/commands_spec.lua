--- Tests for the session-delete command paths (commands.lua). The vim.ui
--- picker/input flows can't run headless, so the specs drive the confirmed
--- delete seam (_delete_confirmed) directly and pin its session/view effects.

describe("poste-ai.commands delete_session", function()
  local config = require("poste-ai.config")
  local session = require("poste-ai.chat.session")
  local commands = require("poste-ai.commands")

  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname() .. "-sessions-delete"
    config.merge({ sessions_dir = tmp_dir })
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
    config.config = vim.deepcopy(config.defaults)
    session.set_current(nil)
  end)

  it("deleting the current session clears it and tolerates the pointer", function()
    local s = session.new("doomed")
    s.messages = { { role = "user", text = "hi" } }
    session.save(s)

    commands._delete_confirmed(s.id)

    assert.is_nil(session.load(s.id))
    -- the pointer references the deleted file; the next current() must not
    -- resurrect it but fall back to a fresh session
    session.set_current(nil)
    local next_cur = session.current()
    assert.are_not.equal(s.id, next_cur.id)
  end)

  it("deleting another session leaves the current one intact", function()
    local other = session.new("other")
    session.save(other)
    local cur = session.new("kept")
    session.save(cur)

    commands._delete_confirmed(other.id)

    assert.is_nil(session.load(other.id))
    assert.are.equal(cur.id, session.current().id)
    assert.are.equal("kept", session.load(cur.id).name)
  end)
end)
