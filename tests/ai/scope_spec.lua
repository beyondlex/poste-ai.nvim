describe("poste-ai.chat.scope", function()
  local scope = require("poste-ai.chat.scope")

  before_each(function()
    scope.clear()
  end)

  it("starts empty with the '-' display", function()
    assert.are.same({}, scope.get())
    assert.are.equal("-", scope.display())
    assert.are.same({}, scope.snapshot())
  end)

  it("sets ordered bindings and joins values for display", function()
    scope.set("connection", "pg")
    assert.are.equal("pg", scope.display())
    scope.set("database", "app")
    assert.are.equal("pg/app", scope.display())
    assert.are.same({ connection = "pg", database = "app" }, scope.snapshot())
  end)

  it("renders per-binding icon + value for the context line", function()
    assert.are.equal("-", scope.render())
    scope.set("connection", "pg", "c")
    assert.are.equal("c pg", scope.render())
    scope.set("database", "app", "d")
    assert.are.equal("c pg d app", scope.render())
    assert.are.equal("pg/app", scope.display())  -- slash display unaffected
    scope.set("connection", "mysql", "C")
    assert.are.equal("C mysql d app", scope.render())
  end)

  it("upserts in place and clears with nil", function()
    scope.set("connection", "pg")
    scope.set("database", "app")
    scope.set("connection", "mysql")
    assert.are.equal("mysql/app", scope.display())
    scope.set("database", nil)
    assert.are.equal("mysql", scope.display())
    scope.set("connection", nil)
    assert.are.equal("-", scope.display())
  end)

  it("round-trips through the persistence shape", function()
    scope.set("connection", "pg", "c")
    scope.set("database", "app", "d")
    local list = scope.to_list()
    assert.are.same({
      { key = "connection", value = "pg", icon = "c" },
      { key = "database", value = "app", icon = "d" },
    }, list)

    scope.clear()
    scope.from_list(list)
    assert.are.equal("pg/app", scope.display())
    assert.are.equal("c pg d app", scope.render())

    scope.from_list(nil)
    assert.are.equal("-", scope.display())
    scope.from_list({ { key = "x" }, { value = "y" } })  -- malformed entries skipped
    assert.are.equal("-", scope.display())
  end)

  it("stamps the current session on change", function()
    local session = require("poste-ai.chat.session")
    session.new("scoped")
    scope.set("connection", "pg")
    local cur = session.current()
    assert.are.same({ { key = "connection", value = "pg" } }, cur.scope)
    scope.clear()
    assert.are.same({}, cur.scope)
  end)
end)
