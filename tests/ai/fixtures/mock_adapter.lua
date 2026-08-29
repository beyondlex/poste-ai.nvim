--- Mock provider adapter for stream tests. Emits configured chunks on
--- timers so cancellation can be exercised mid-stream.

local M = {}

M.state = {
  chunks = { "Hello", " world" },
  delay_ms = 10,
  requests = {},
}

function M.reset(chunks, delay_ms)
  M.state.chunks = chunks or { "Hello", " world" }
  M.state.delay_ms = delay_ms or 10
  M.state.requests = {}
end

--- @param handlers table { on_delta, on_finish, on_error }
function M.stream(cfg, opts, handlers)
  M.state.requests[#M.state.requests + 1] = { cfg = cfg, opts = opts }
  local handle = { cancelled = false }
  local acc = {}
  local i = 0

  local function step()
    if handle.cancelled then
      handlers.on_finish({ content = table.concat(acc, ""), cancelled = true })
      return
    end
    i = i + 1
    local chunk = M.state.chunks[i]
    if chunk == nil then
      handlers.on_finish({ content = table.concat(acc, ""), finish_reason = "stop" })
      return
    end
    acc[#acc + 1] = chunk
    handlers.on_delta(chunk)
    vim.defer_fn(step, M.state.delay_ms)
  end

  vim.defer_fn(step, M.state.delay_ms)
  handle.cancel = function() handle.cancelled = true end
  return handle
end

return M
