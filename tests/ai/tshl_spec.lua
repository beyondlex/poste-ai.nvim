describe("poste-ai.chat.tshl", function()
  local tshl = require("poste-ai.chat.tshl")

  before_each(function()
    tshl._test._reset()
  end)

  it("resolves language aliases and rejects unknown/plain", function()
    assert.are.equal("bash", tshl._test.resolve_lang("sh"))
    assert.are.equal("bash", tshl._test.resolve_lang("SHELL"))
    assert.are.equal("python", tshl._test.resolve_lang("py"))
    assert.are.equal("lua", tshl._test.resolve_lang("lua"))
    assert.is_nil(tshl._test.resolve_lang("text"))
    assert.is_nil(tshl._test.resolve_lang(""))
  end)

  it("returns empty specs for empty text or missing parser", function()
    assert.are.same({}, tshl.specs("", "lua"))
    assert.are.same({}, tshl.specs("SELECT 1", "definitely-not-a-lang"))
    -- failure results are cached (stable, no repeated parse attempts)
    assert.are.same(tshl.specs("SELECT 1", "definitely-not-a-lang"),
      tshl.specs("SELECT 1", "definitely-not-a-lang"))
  end)

  it("produces capture specs from a real parser when available", function()
    local has_lua = pcall(vim.treesitter.get_string_parser, "", "lua")
    if not has_lua then
      print("skipping: no lua treesitter parser")
      return
    end
    local specs = tshl.specs("local x = 1\n", "lua")
    assert.is_true(#specs > 0)
    for _, s in ipairs(specs) do
      assert.is_not_nil(s.group:find("^@"))
      assert.is_true(s.row >= 0)
      assert.is_true(s.end_row >= s.row)
    end
    -- at least one keyword/variable capture on row 0
    local row0 = vim.tbl_filter(function(s) return s.row == 0 end, specs)
    assert.is_true(#row0 > 0)
  end)

  it("caches results per (lang, text)", function()
    local has_lua = pcall(vim.treesitter.get_string_parser, "", "lua")
    if not has_lua then return end
    local a = tshl.specs("local x = 1", "lua")
    local b = tshl.specs("local x = 1", "lua")
    assert.are.equal(a, b)  -- same table instance
    local c = tshl.specs("local y = 2", "lua")
    assert.are_not.equal(a, c)
  end)

  it("caps the cache so streaming blocks cannot grow it unboundedly", function()
    -- streaming writes one intermediate block text per flush tick; without a
    -- cap each would keep a full copy of the block until nvim exits
    for i = 1, 400 do tshl.specs("local x = " .. i, "lua") end
    local n = 0
    for _ in pairs(tshl._test._cache()) do n = n + 1 end
    assert.is_true(n <= 256)
  end)
end)
