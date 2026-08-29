--- OpenAI-compatible chat-completions streaming adapter.
--- Works with OpenAI, DeepSeek, Qwen, Ollama (`/v1`), OpenRouter, vLLM, ...
--- Transport is `curl -N` via `jobstart` (unbuffered stdout → SSE parser).
--- Pure helpers (`build_request`, `extract_delta`, `error_from_body`) are kept
--- separate from the job wiring so they can be unit-tested without I/O.

local sse = require("poste-ai.provider.sse")
local config = require("poste-ai.config")

local M = {}

--- Join a base_url with the chat-completions path.
--- @param base_url string
--- @return string
function M.endpoint(base_url)
  return (base_url:gsub("/+$", "")) .. "/chat/completions"
end

--- Build the curl argument list and request body for a streaming request.
--- @param cfg table provider config (base_url, api_key already resolved)
--- @param opts table { messages, temperature, max_tokens, timeout_ms }
--- @return table args  curl command arguments (without the binary name)
--- @return string body  JSON request body
function M.build_request(cfg, opts)
  local body = {
    model = cfg.model,
    messages = opts.messages,
    stream = true,
  }
  if opts.temperature ~= nil then body.temperature = opts.temperature end
  if opts.max_tokens ~= nil then body.max_tokens = opts.max_tokens end

  local args = {
    "curl", "-sS", "-N",
    "--max-time", tostring(math.max(1, math.ceil((opts.timeout_ms or 120000) / 1000))),
    "-X", "POST",
    "-H", "Content-Type: application/json",
  }
  if cfg.api_key and cfg.api_key ~= "" then
    args[#args + 1] = "-H"
    args[#args + 1] = "Authorization: Bearer " .. cfg.api_key
  end
  args[#args + 1] = "--data-binary"
  args[#args + 1] = "@-"
  args[#args + 1] = M.endpoint(cfg.base_url)
  return args, vim.json.encode(body)
end

--- Extract the text delta from one streamed chat-completion chunk.
--- @param obj table decoded payload
--- @return string|nil
function M.extract_delta(obj)
  local choice = obj and obj.choices and obj.choices[1]
  if not choice or not choice.delta then return nil end
  local content = choice.delta.content
  if type(content) == "string" and content ~= "" then return content end
  return nil
end

--- Extract the finish reason from a streamed chunk, if present.
--- @param obj table
--- @return string|nil
function M.extract_finish(obj)
  local choice = obj and obj.choices and obj.choices[1]
  return choice and choice.finish_reason or nil
end

--- Build a readable error message from a non-SSE JSON error body.
--- @param obj table decoded response body
--- @return string
function M.error_from_body(obj)
  if type(obj) ~= "table" then return tostring(obj) end
  local parts = {}
  local err = obj.error
  if type(err) == "table" then
    if err.message then parts[#parts + 1] = err.message end
    if err.type and err.type ~= "" then parts[#parts + 1] = "(" .. err.type .. ")" end
  elseif type(err) == "string" then
    parts[#parts + 1] = err
  end
  if #parts == 0 and obj.message then parts[#parts + 1] = obj.message end
  if #parts == 0 then parts[#parts + 1] = vim.json.encode(obj) end
  local msg = table.concat(parts, " ")
  if #msg > 300 then msg = msg:sub(1, 300) .. "…" end
  return msg
end

--- Map a curl exit code to a readable failure.
local EXIT_MESSAGES = {
  [6]  = "could not resolve host",
  [7]  = "could not connect",
  [28] = "request timed out",
  [35] = "TLS handshake failed",
  [56] = "connection reset during streaming",
}

--- Start a streaming chat request.
--- @param cfg table provider config (base_url, model, api_key)
--- @param opts table { messages, temperature, max_tokens, timeout_ms }
--- @param handlers table { on_delta(text), on_finish(result), on_error(msg) }
---   result = { content, finish_reason, saw_done, cancelled }
--- @return table handle { job_id, cancel() }
function M.stream(cfg, opts, handlers)
  opts = opts or {}
  local request_cfg = {
    base_url = cfg.base_url,
    model = cfg.model,
    api_key = cfg.api_key or config.api_key(cfg),
  }
  local args, body = M.build_request(request_cfg, opts)

  local acc = {}       -- accumulated content deltas
  local raw = {}       -- non-SSE lines (usually an error body)
  local finish_reason = nil
  local saw_data = false
  local saw_done = false
  local finished = false
  local handle = { cancelled = false, job_id = nil }
  local parser  -- forward declaration: finalize flushes it on exit

  local function safe(fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then vim.schedule(function() vim.notify("poste-ai: " .. tostring(err), vim.log.levels.ERROR, { title = "PosteAI" }) end) end
  end

  local function finalize(result_kind, err_msg)
    if finished then return end
    finished = true
    parser:flush()
    if result_kind == "error" then
      safe(handlers.on_error, err_msg)
      return
    end
    safe(handlers.on_finish, {
      content = table.concat(acc, ""),
      finish_reason = finish_reason,
      saw_done = saw_done,
      cancelled = result_kind == "cancelled",
    })
  end

  parser = sse.new({
    on_data = function(payload)
      saw_data = true
      local ok, obj = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
      if not ok or type(obj) ~= "table" then return end
      local delta = M.extract_delta(obj)
      if delta then
        acc[#acc + 1] = delta
        safe(handlers.on_delta, delta)
      end
      local fr = M.extract_finish(obj)
      if fr and fr ~= "" then finish_reason = fr end
    end,
    on_done = function()
      saw_done = true
    end,
    on_raw = function(line) raw[#raw + 1] = line end,
  })

  local ok_job, job_id = pcall(vim.fn.jobstart, args, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data, _)
      if not data then return end
      for _, chunk in ipairs(data) do
        if chunk then parser:feed(chunk .. "\n") end
      end
    end,
    on_stderr = function(_, data, _)
      if not data then return end
      local msgs = {}
      for _, l in ipairs(data) do
        if l ~= "" then msgs[#msgs + 1] = l end
      end
      if #msgs > 0 then handle.stderr = table.concat(msgs, "\n") end
    end,
    on_exit = function(_, code, _)
      handle.job_id = nil
      if handle.cancelled then
        finalize("cancelled")
      elseif code == 0 then
        if saw_data or #acc > 0 then
          finalize("finish")
        elseif #raw > 0 then
          local body_txt = table.concat(raw, "\n")
          local ok_p, obj = pcall(vim.json.decode, body_txt, { luanil = { object = true, array = true } })
          if ok_p and type(obj) == "table" then
            finalize("error", M.error_from_body(obj))
          else
            finalize("error", "unexpected non-streaming response: " .. body_txt:sub(1, 200))
          end
        else
          finalize("error", "empty response from provider")
        end
      else
        local reason = EXIT_MESSAGES[code] or ("curl exit code " .. code)
        local msg = "request failed: " .. reason
        if #raw > 0 then
          local body_txt = table.concat(raw, "\n")
          local ok_p, obj = pcall(vim.json.decode, body_txt, { luanil = { object = true, array = true } })
          msg = (ok_p and type(obj) == "table") and M.error_from_body(obj) or body_txt:sub(1, 200)
        elseif handle.stderr and handle.stderr ~= "" then
          msg = msg .. " — " .. handle.stderr:sub(1, 200)
        end
        finalize("error", msg)
      end
    end,
  })

  if not ok_job or type(job_id) ~= "number" or job_id <= 0 then
    finalize("error", "failed to start curl (is curl installed?)")
    return handle
  end

  handle.job_id = job_id
  pcall(vim.fn.chansend, job_id, body)
  -- NB: chanclose without a stream closes ALL pipes including stdout, which
  -- would EPIPE curl mid-stream (exit 23). Close only our stdin.
  pcall(vim.fn.chanclose, job_id, "stdin")

  function handle.cancel()
    if handle.job_id then
      handle.cancelled = true
      pcall(vim.fn.jobstop, handle.job_id)
    end
  end

  return handle
end

M._test = {
  endpoint = M.endpoint,
  build_request = M.build_request,
  extract_delta = M.extract_delta,
  extract_finish = M.extract_finish,
  error_from_body = M.error_from_body,
  EXIT_MESSAGES = EXIT_MESSAGES,
}

return M
