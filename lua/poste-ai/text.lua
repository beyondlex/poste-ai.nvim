--- Shared pure-text helpers used by the chat UI modules.

local M = {}

--- Truncate a string so its display width fits `limit` columns, appending
--- "..." (the result never exceeds `limit` display columns). Multi-byte safe.
--- @param text string
--- @param limit number
--- @return string
function M.truncate(text, limit)
  if limit <= 3 then return vim.fn.strcharpart(text, 0, math.max(0, limit - 3)) .. "..." end
  local n = vim.fn.strchars(text)
  for i = 0, n do
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, i)) > limit - 3 then
      return vim.fn.strcharpart(text, 0, math.max(0, i - 1)) .. "..."
    end
  end
  return text
end

return M
