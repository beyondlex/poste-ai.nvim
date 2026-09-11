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

--- Truncate at a BYTE budget without splitting a UTF-8 character: the cut
--- point backs up over continuation bytes. (No ellipsis appended.)
--- Provider error bodies and @file context blocks arrive here sized in bytes;
--- a plain `sub` cut sent invalid UTF-8 whenever the boundary fell inside a
--- multibyte character.
--- @param s string
--- @param max_bytes number
--- @return string
function M.utf8_safe_cut(s, max_bytes)
  if #s <= max_bytes then return s end
  local cut = max_bytes
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end -- not a continuation byte
    cut = cut - 1
  end
  return s:sub(1, cut)
end

return M
