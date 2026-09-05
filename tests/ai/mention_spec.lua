describe("poste-ai.chat.mention", function()
  local mention = require("poste-ai.chat.mention")
  local context_api = require("poste-ai.context_api")

  local tmp_file = "poste_ai_mention_test_fixture.sql"

  before_each(function()
    vim.fn.writefile({ "SELECT 1;", "SELECT 2;", "SELECT 3;" }, tmp_file)
  end)

  after_each(function()
    pcall(vim.fn.delete, tmp_file)
    context_api.unregister("tc")
    context_api.set_active(nil)
  end)

  it("cleans trailing punctuation from tokens", function()
    assert.are.equal("a/b", mention._test.clean_token("a/b,"))
    assert.are.equal("x.sql(1-2)", mention._test.clean_token("x.sql(1-2)."))
  end)

  it("parses file mentions with and without ranges", function()
    local refs = mention.parse("look at @" .. tmp_file .. "(1-2) and @" .. tmp_file .. " please")
    assert.are.equal(2, #refs)
    assert.are.equal("file", refs[1].type)
    assert.are.equal(1, refs[1].l1)
    assert.are.equal(2, refs[1].l2)
    assert.are.equal("file", refs[2].type)
    assert.is_nil(refs[2].l1)
  end)

  it("parses single-line range mentions (what range_mention emits)", function()
    local refs = mention.parse("check @" .. tmp_file .. "(2)")
    assert.are.equal(1, #refs)
    assert.are.equal("file", refs[1].type)
    assert.are.equal(2, refs[1].l1)
    assert.are.equal(2, refs[1].l2)
  end)

  it("resolves file mention paths relative to the cwd", function()
    local refs = mention.parse("@" .. tmp_file)
    assert.are.equal(1, #refs)
    assert.truthy(refs[1].abspath:find(tmp_file, 1, true))
  end)

  it("lets registered contexts claim tokens before the file fallback", function()
    context_api.register("tc", {
      mention = {
        match = function(token)
          local conn, db = token:match("^tc/([%w%-]+)/([%w%-]+)$")
          if conn then return { connection = conn, database = db } end
        end,
      },
    })
    local refs = mention.parse("@tc/my-conn/mydb stuff")
    assert.are.equal(1, #refs)
    assert.are.equal("context", refs[1].type)
    assert.are.equal("tc", refs[1].context)
    assert.are.equal("my-conn", refs[1].data.connection)
  end)

  it("collapses duplicate tokens and ignores unknown tokens", function()
    context_api.register("tc", { mention = { match = function() return nil end } })
    local refs = mention.parse("@nope1 @nope1 @no_such_file_xyz(1-2)")
    assert.are.equal(0, #refs)  -- unknown to the context and not a real file
  end)

  it("builds range mentions from a buffer range", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/sub/dir/test.sql")
    local m = mention.range_mention(buf, 5, 2)
    assert.are.equal("@sub/dir/test.sql(2-5)", m)
    local single = mention.range_mention(buf, 3, 3)
    assert.are.equal("@sub/dir/test.sql(3)", single)
  end)

  describe("resolve_all", function()
    local function read_block(md, header_prefix)
      for _, chunk in ipairs(vim.split(md, "\n\n", { plain = true })) do
        if chunk:find(header_prefix, 1, true) then return chunk end
      end
    end

    it("renders file refs as fenced blocks", function()
      local out
      mention.resolve_all({ { type = "file", path = tmp_file, abspath = vim.fn.getcwd() .. "/" .. tmp_file, token = tmp_file } },
        function(md) out = md end)
      local block = read_block(out, tmp_file)
      assert.truthy(block:find("```sql"))
      assert.truthy(block:find("SELECT 2;"))
    end)

    it("renders ranged file refs", function()
      local out
      mention.resolve_all({ { type = "file", path = tmp_file, abspath = vim.fn.getcwd() .. "/" .. tmp_file, token = tmp_file, l1 = 2, l2 = 3 } },
        function(md) out = md end)
      local block = read_block(out, "(lines 2-3)")
      assert.truthy(block:find("SELECT 3;"))
      assert.falsy(block:find("SELECT 1;"))
    end)

    it("renders single-line ranged file refs", function()
      local out
      mention.resolve_all({ { type = "file", path = tmp_file, abspath = vim.fn.getcwd() .. "/" .. tmp_file, token = tmp_file, l1 = 2, l2 = 2 } },
        function(md) out = md end)
      assert.truthy(out:find("(lines 2-2)", 1, true))
      assert.truthy(out:find("SELECT 2;"))
      assert.falsy(out:find("SELECT 1;"))
    end)

    it("delegates context refs and aggregates in order", function()
      context_api.register("tc", {
        mention = {
          match = function() return nil end,
          resolve = function(ref, cb)
            vim.defer_fn(function() cb("SCHEMA:" .. ref.name, nil) end, 5)
          end,
        },
      })
      local out
      mention.resolve_all({
        { type = "file", path = tmp_file, abspath = vim.fn.getcwd() .. "/" .. tmp_file, token = "f.sql" },
        { type = "context", context = "tc", token = "tc/x", data = { name = "db-one" } },
      }, function(md) out = md end)
      vim.wait(1000, function() return out ~= nil end)
      local pos_f = out:find("### @f%.sql")
      local pos_c = out:find("SCHEMA:db%-one")
      assert.truthy(pos_f)
      assert.truthy(pos_c)
      assert.is_true(pos_f < pos_c)
    end)

    it("notes unresolved refs instead of failing", function()
      local out
      mention.resolve_all({ { type = "context", context = "ghost", token = "g", data = {} } },
        function(md) out = md end)
      assert.truthy(out:find("unavailable"))
    end)
  end)
end)
