describe("poste-ai.chat.render", function()
  local render = require("poste-ai.chat.render")

  it("styles headings, hr, quotes and bullets", function()
    local specs = render.specs({
      "# Title",       -- 0
      "- bullet",      -- 1
      "1. ordered",    -- 2
      "> quoted",      -- 3
      "---",           -- 4
    })
    local function find(row, group)
      for _, m in ipairs(specs.marks) do
        if m.row == row and m.group == group then return m end
      end
    end
    assert.truthy(find(0, "PosteAiHeading"))
    assert.truthy(find(1, "PosteAiBullet"))
    local ordered = find(2, "PosteAiBullet")
    assert.are.equal(2, ordered.length)  -- "1."
    assert.truthy(find(3, "PosteAiQuote"))
    assert.truthy(find(4, "PosteAiHr"))
  end)

  it("highlights inline code spans", function()
    local specs = render.specs({ "use `foo_bar()` here" })
    local found = {}
    for _, m in ipairs(specs.marks) do
      if m.group == "PosteAiInlineCode" then found[#found + 1] = m end
    end
    assert.are.equal(1, #found)
    assert.are.equal(5, found[1].col)
    assert.are.equal(9, found[1].length)  -- foo_bar() without backticks
  end)

  it("renders fenced code blocks with bg, lang and block metadata", function()
    local specs = render.specs({
      "before",       -- 0
      "```sql",       -- 1
      "SELECT 1",     -- 2
      "FROM t",       -- 3
      "```",          -- 4
      "after",        -- 5
    })
    assert.are.equal(1, #specs.code_blocks)
    local cb = specs.code_blocks[1]
    assert.are.equal("sql", cb.lang)
    assert.are.equal("SELECT 1\nFROM t", cb.text)
    assert.are.equal(2, cb.start)
    assert.are.equal(3, cb.end_)

    assert.are.equal(1, #specs.bg_ranges)
    assert.are.equal(2, specs.bg_ranges[1].start)
    assert.are.equal(3, specs.bg_ranges[1].end_)
    assert.are.equal("PosteAiCodeBlock", specs.bg_ranges[1].group)

    local fence_marks = {}
    for _, m in ipairs(specs.marks) do
      if m.group == "PosteAiCodeFence" then fence_marks[#fence_marks + 1] = m end
    end
    assert.are.equal(2, #fence_marks)
  end)

  it("handles an unterminated fence (mid-stream) to the last line", function()
    local specs = render.specs({ "```sql", "SELECT", "2" })
    local cb = specs.code_blocks[1]
    assert.are.equal("sql", cb.lang)
    assert.are.equal("SELECT\n2", cb.text)
    assert.are.equal(1, cb.start)
    assert.are.equal(2, cb.end_)
  end)

  it("returns empty specs for plain text", function()
    local specs = render.specs({ "just text", "more text" })
    assert.are.equal(0, #specs.marks)
    assert.are.equal(0, #specs.bg_ranges)
    assert.are.equal(0, #specs.code_blocks)
  end)
end)
