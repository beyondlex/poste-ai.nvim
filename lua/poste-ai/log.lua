--- AI round-trip logging — records every request sent to a model and the
--- finished streamed response as JSONL under
--- `stdpath("data")/poste-ai/logs/`. Enabled with `opts.log`; all I/O is
--- guarded so a logging failure can never break a request.

local config = require("poste-ai.config")

local M = {}

local function dir()
  return vim.fn.stdpath("data") .. "/poste-ai/logs"
end

local function file_for_day()
  return dir() .. "/requests-" .. vim.fn.strftime("%Y-%m-%d") .. ".jsonl"
end

--- Append one JSONL record. No-op unless logging is enabled.
--- @param kind string "request"|"response"
--- @param data table record fields
function M.write(kind, data)
  if not config.config.log then return end
  local rec = { ts = os.date("%Y-%m-%dT%H:%M:%S%z"), kind = kind }
  for k, v in pairs(data) do rec[k] = v end
  local ok, encoded = pcall(vim.json.encode, rec)
  if not ok then return end
  pcall(vim.fn.mkdir, dir(), "p")
  pcall(vim.fn.writefile, { encoded }, file_for_day(), "a")
end

--- Record an outgoing request.
--- @param data table { endpoint, model, messages, temperature, max_tokens, timeout_ms }
function M.request(data)
  M.write("request", data)
end

--- Record a finished response (success or error).
--- @param data table { model, finish_reason, content, saw_done, cancelled, error, raw }
function M.response(data)
  M.write("response", data)
end

M._test = { write = M.write }

return M