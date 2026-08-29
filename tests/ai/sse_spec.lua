describe("poste-ai.provider.sse", function()
  local sse = require("poste-ai.provider.sse")

  describe("classify_line", function()
    it("classifies data lines", function()
      assert.are.equal("data", sse.classify_line('data: {"x":1}'))
      assert.are.equal('{"x":1}', (select(2, sse.classify_line('data: {"x":1}'))))
    end)

    it("classifies data without a space after the colon", function()
      local kind, payload = sse.classify_line("data:tight")
      assert.are.equal("data", kind)
      assert.are.equal("tight", payload)
    end)

    it("classifies the [DONE] sentinel", function()
      assert.are.equal("done", sse.classify_line("data: [DONE]"))
      assert.are.equal("done", sse.classify_line("data:[DONE]"))
    end)

    it("classifies comments, known fields and raw lines", function()
      assert.are.equal("comment", sse.classify_line(": keepalive"))
      assert.are.equal("skip", sse.classify_line("event: ping"))
      assert.are.equal("skip", sse.classify_line(""))
      assert.are.equal("raw", sse.classify_line('{"error":"not sse"}'))
    end)
  end)

  describe("feed", function()
    local function collect(chunks)
      local events = { data = {}, done = 0, raw = {}, comments = {} }
      local p = sse.new({
        on_data = function(payload) table.insert(events.data, payload) end,
        on_done = function() events.done = events.done + 1 end,
        on_raw = function(line) table.insert(events.raw, line) end,
        on_comment = function(line) table.insert(events.comments, line) end,
      })
      for _, c in ipairs(chunks) do p:feed(c) end
      p:flush()
      return events
    end

    it("emits one event per complete data line", function()
      local ev = collect({ 'data: {"a":1}\n\ndata: {"b":2}\n\n' })
      assert.are.equal(2, #ev.data)
      assert.are.equal('{"a":1}', ev.data[1])
      assert.are.equal('{"b":2}', ev.data[2])
    end)

    it("reassembles chunks split mid-line", function()
      local ev = collect({ 'data: {"a"', ':1}\n\ndata: [DO', "NE]\n" })
      assert.are.equal(1, #ev.data)
      assert.are.equal('{"a":1}', ev.data[1])
      assert.are.equal(1, ev.done)
    end)

    it("handles CRLF line endings", function()
      local ev = collect({ "data: x\r\n\r\n" })
      assert.are.equal(1, #ev.data)
      assert.are.equal("x", ev.data[1])
    end)

    it("routes non-SSE lines to on_raw (error bodies)", function()
      local ev = collect({ '{"error":{"message":"bad key"}}' })
      assert.are.equal(0, #ev.data)
      assert.are.equal(1, #ev.raw)
      assert.are.equal('{"error":{"message":"bad key"}}', ev.raw[1])
    end)

    it("reports comments and skips known fields", function()
      local ev = collect({ ": ping\n", "event: add\n", "data: y\n" })
      assert.are.equal(1, #ev.comments)
      assert.are.equal(1, #ev.data)
    end)

    it("keeps partial lines buffered until more input arrives", function()
      local count = 0
      local p = sse.new({ on_data = function() count = count + 1 end })
      p:feed("data: hel")
      assert.are.equal(0, count)
      assert.are.equal("data: hel", p:pending())
      p:feed("lo\n")
      assert.are.equal(1, count)
      assert.are.equal("", p:pending())
    end)

    it("flush processes a trailing line without a newline", function()
      local ev = collect({ '{"json":true}' })
      assert.are.equal(1, #ev.raw)
    end)
  end)
end)
