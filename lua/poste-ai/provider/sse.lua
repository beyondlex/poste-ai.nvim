--- SSE (Server-Sent Events) line parser for streaming LLM responses.
--- Pure logic with no I/O: `new()` returns a stateful parser fed chunks from a
--- curl subprocess; `feed()` invokes handlers for every complete event. The
--- leftover partial line stays buffered until the next feed or `flush()`.

local M = {}

local Parser = {}
Parser.__index = Parser

--- Create a parser. `handlers`:
---   on_data(payload)  — each `data:` line's payload (before "[DONE]" check)
---   on_done()         — the `data: [DONE]` sentinel
---   on_raw(line)      — any complete line that is not a recognized SSE field
---                       (used to capture non-SSE bodies, e.g. JSON errors)
---   on_comment(line)  — `:` keep-alive comments
function M.new(handlers)
  return setmetatable({ _buf = "", _handlers = handlers or {} }, Parser)
end

--- Classify one complete SSE line. Exported for direct unit testing.
--- @param line string a line without its trailing newline
--- @return string kind "data"|"done"|"raw"|"comment"|"skip"
--- @return string payload
function M.classify_line(line)
  if line:sub(1, 1) == ":" then return "comment", "" end
  if line:sub(1, 6) == "data: " then
    local payload = line:sub(7)
    if payload == "[DONE]" then return "done", "" end
    return "data", payload
  end
  if line:sub(1, 5) == "data:" then
    local payload = line:sub(6):match("^%s*(.-)%s*$")
    if payload == "[DONE]" then return "done", "" end
    return "data", payload
  end
  -- Recognized-but-unused SSE fields
  if line:sub(1, 6) == "event:" or line:sub(1, 3) == "id:" or line:sub(1, 6) == "retry:" then
    return "skip", ""
  end
  if line:match("^%s*$") then return "skip", "" end
  return "raw", line
end

function Parser:dispatch(kind, payload)
  local h = self._handlers
  if kind == "data" and h.on_data then h.on_data(payload)
  elseif kind == "done" and h.on_done then h.on_done()
  elseif kind == "comment" and h.on_comment then h.on_comment(payload)
  elseif kind == "raw" and h.on_raw then h.on_raw(payload)
  end
end

--- Feed a raw chunk (may contain any number of lines, or half of one).
--- @param chunk string
function Parser:feed(chunk)
  self._buf = self._buf .. chunk
  while true do
    local nl = self._buf:find("\n")
    if not nl then break end
    local line = self._buf:sub(1, nl - 1)
    self._buf = self._buf:sub(nl + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    local kind, payload = M.classify_line(line)
    self:dispatch(kind, payload)
  end
end

--- Process whatever is left in the buffer (call when the stream ends without a
--- trailing newline, e.g. a non-SSE JSON error body).
function Parser:flush()
  local line = self._buf
  self._buf = ""
  if line == "" then return end
  if line:sub(-1) == "\r" then line = line:sub(1, -2) end
  local kind, payload = M.classify_line(line)
  self:dispatch(kind, payload)
end

--- Bytes still buffered (for diagnostics/tests).
function Parser:pending() return self._buf end

return M
