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

  it("highlights inline code spans and conceals the backticks", function()
    local specs = render.specs({ "use `foo_bar()` here" })
    local found = {}
    for _, m in ipairs(specs.marks) do
      if m.group == "PosteAiInlineCode" then found[#found + 1] = m end
    end
    assert.are.equal(3, #found)
    assert.are.equal(5, found[1].col)
    assert.are.equal(9, found[1].length)  -- foo_bar() without backticks
    assert.is_nil(found[1].conceal)
    assert.are.equal(4, found[2].col)      -- opening backtick
    assert.are.equal(1, found[2].length)
    assert.are.equal("", found[2].conceal)
    assert.are.equal(14, found[3].col)     -- closing backtick
    assert.are.equal("", found[3].conceal)
  end)

  it("conceals markdown markers for fences, headings, bullets and quotes", function()
    local specs = render.specs({
      "## Heading",   -- 0
      "- item",       -- 1
      "> quote",      -- 2
    })
    local function find_conceal(row)
      for _, m in ipairs(specs.marks) do
        if m.row == row and m.conceal ~= nil then return m end
      end
    end
    local h = find_conceal(0)
    assert.truthy(h)
    assert.are.equal(0, h.col)
    assert.are.equal(3, h.length)  -- "## "
    local b = find_conceal(1)
    assert.truthy(b)
    assert.are.equal(0, b.col)
    assert.are.equal(2, b.length)  -- "- "
    assert.are.equal("•", b.conceal)
    local q = find_conceal(2)
    assert.truthy(q)
    assert.are.equal(0, q.col)     -- "> "
    assert.are.equal(2, q.length)
  end)

  it("conceals whole fence lines including the language", function()
    local specs = render.specs({ "```sql", "SELECT 1", "```" })
    local fences = {}
    for _, m in ipairs(specs.marks) do
      if m.group == "PosteAiCodeFence" then fences[#fences + 1] = m end
    end
    assert.are.equal(2, #fences)
    assert.are.equal("", fences[1].conceal)
    assert.are.equal(6, fences[1].length)  -- "```sql"
    assert.are.equal("", fences[2].conceal)
  end)

  it("highlights bold and italic spans and conceals markers", function()
    local specs = render.specs({ "a **bold** and *ital* and _und_ end" })
    local function span(group)
      for _, m in ipairs(specs.marks) do
        if m.group == group and m.conceal == nil then return m end
      end
    end
    local bold = span("PosteAiBold")
    assert.truthy(bold)
    assert.are.equal(4, bold.col)
    assert.are.equal(4, bold.length)  -- "bold"
    local ital = span("PosteAiItalic")
    assert.truthy(ital)
    assert.are.equal(16, ital.col)
    assert.are.equal(4, ital.length)  -- "ital"
    local conceal_runs = 0
    for _, m in ipairs(specs.marks) do
      if m.conceal ~= nil then conceal_runs = conceal_runs + 1 end
    end
    assert.are.equal(6, conceal_runs)  -- bold x2, *ital* x2, _und_ x2
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
