--- Markdown rendering layer for the chat conversation buffer.
--- The conversation buffer always holds raw markdown (copy semantics stay
--- exact); this module computes highlight extmark specs over it. "Rendered"
--- vs "source" view is simply whether the extmarks are applied, so streaming
--- never rewrites buffer lines — no flicker by construction.
---
--- Markdown markers (fences, heading hashes, bullets, quote carets, inline
--- code backticks, bold/italic markers) carry a `conceal` replacement string;
--- conceal is display-only, so yanks still contain the raw markdown.
---
--- V1 supports: fenced code blocks (bg + fence/lang styling), headings,
--- horizontal rules, blockquotes, list bullets, inline code, bold/italic.
--- Tables are left as plain text.

local M = {}

--- Scan lines and produce highlight specs.
--- @param lines string[] raw markdown lines
--- @return table specs { marks = {{row,col,length,group,conceal?}}, bg_ranges = {{start,end_,group}}, code_blocks = {{start,end_,lang,text}} }
---   rows are 0-based relative to the first input line; `end_` is inclusive.
---   `conceal`, when present, is the replacement text ("" hides the range).
function M.specs(lines)
  local marks = {}
  local bg_ranges = {}
  local code_blocks = {}
  local n = #lines

  local i = 0
  while i < n do
    i = i + 1
    local line = lines[i]

    -- Fenced code blocks
    local fence, lang = line:match("^%s*(%`%`%`+)%s*([%w%-%_]*)%s*$")
    if fence then
      local open_row = i - 1
      local close_row = nil
      local j = i
      while j < n do
        j = j + 1
        if lines[j]:match("^%s*(%`%`%`+)%s*$") then
          close_row = j - 1
          break
        end
      end
      if close_row then
        i = close_row + 1
      else
        -- unterminated fence (mid-stream): everything to the end is code;
        -- close_row is virtual (one past the last line)
        close_row = n
        i = n
      end
      marks[#marks + 1] = { row = open_row, col = 0, length = #line, group = "PosteAiCodeFence", conceal = "" }
      if close_row <= n - 1 then
        local close_line = lines[close_row + 1] or ""
        marks[#marks + 1] = { row = close_row, col = 0, length = #close_line, group = "PosteAiCodeFence", conceal = "" }
      end
      if lang ~= "" then
        local col = line:find(lang, 1, true)
        if col then
          marks[#marks + 1] = { row = open_row, col = col - 1, length = #lang, group = "PosteAiCodeLang" }
        end
      end
      if close_row > open_row + 1 then
        bg_ranges[#bg_ranges + 1] = { start = open_row + 1, end_ = close_row - 1, group = "PosteAiCodeBlock" }
        local code = {}
        for k = open_row + 2, close_row do code[#code + 1] = lines[k] end
        code_blocks[#code_blocks + 1] = {
          start = open_row + 1, end_ = close_row - 1,
          lang = lang, text = table.concat(code, "\n"),
        }
      else
        code_blocks[#code_blocks + 1] = { start = open_row + 1, end_ = open_row, lang = lang, text = "" }
      end
    elseif line:match("^%s*#+%s+") then
      marks[#marks + 1] = { row = i - 1, col = 0, length = #line, group = "PosteAiHeading" }
      local hash, sp = line:match("^%s*()#+()%s")
      if hash then
        marks[#marks + 1] = { row = i - 1, col = hash - 1, length = sp - hash + 1, group = "PosteAiHeading", conceal = "" }
      end
    elseif line:match("^%s*(%-%-%-+)%s*$") or line:match("^%s*(%*%*%*+)%s*$") or line:match("^%s*(___)%s*$") then
      marks[#marks + 1] = { row = i - 1, col = 0, length = #line, group = "PosteAiHr" }
    elseif line:match("^%s*>") then
      marks[#marks + 1] = { row = i - 1, col = 0, length = #line, group = "PosteAiQuote" }
      local qfrom, qto = line:match("^%s*()>()%s")
      if qfrom then
        marks[#marks + 1] = { row = i - 1, col = qfrom - 1, length = qto - qfrom + 1, group = "PosteAiQuote", conceal = "" }
      end
    else
      -- list bullets / ordered numbers
      local col = line:match("^%s*()([%-%*%+])%s")
      if col then
        marks[#marks + 1] = { row = i - 1, col = col - 1, length = 2, group = "PosteAiBullet", conceal = "•" }
      else
        local num = line:match("^%s*(%d+)%.%s")
        if num then
          local ncol = line:match("^%s*()%d+%.%s")
          marks[#marks + 1] = { row = i - 1, col = ncol - 1, length = #num + 1, group = "PosteAiBullet" }
        end
      end
      -- inline code spans (skip fence lines): highlight inner text, hide ticks.
      -- Their ranges are recorded so the emphasis scans below treat markdown
      -- markers inside backticks as literal text (`` `**not bold**` `` stays
      -- literal — no bold marks, no concealed asterisks).
      local taken = {}  -- 1-based occupied intervals on this line
      local function contained(a, b)
        for _, iv in ipairs(taken) do
          if iv[1] <= a and b <= iv[2] then return true end
        end
        return false
      end
      local pos = 1
      while true do
        local s, e = line:find("`[^`]+`", pos)
        if not s then break end
        marks[#marks + 1] = { row = i - 1, col = s, length = e - s - 1, group = "PosteAiInlineCode" }
        marks[#marks + 1] = { row = i - 1, col = s - 1, length = 1, group = "PosteAiInlineCode", conceal = "" }
        marks[#marks + 1] = { row = i - 1, col = e - 1, length = 1, group = "PosteAiInlineCode", conceal = "" }
        taken[#taken + 1] = { s, e }
        pos = e + 1
      end
      -- bold / italic: highlight inner span, hide the marker runs
      pos = 1
      while true do
        local s, e = line:find("%*%*[^%s%*][^%*]*%*%*", pos)
        if not s then break end
        if not contained(s, e) then
          marks[#marks + 1] = { row = i - 1, col = s + 1, length = e - s - 3, group = "PosteAiBold" }
          marks[#marks + 1] = { row = i - 1, col = s - 1, length = 2, group = "PosteAiBold", conceal = "" }
          marks[#marks + 1] = { row = i - 1, col = e - 2, length = 2, group = "PosteAiBold", conceal = "" }
          taken[#taken + 1] = { s, e }
        end
        pos = e + 1
      end
      local function free(a, b)
        for _, iv in ipairs(taken) do
          if a <= iv[2] and b >= iv[1] then return false end
        end
        return true
      end
      for _, pat in ipairs({ "%*[^%s%*][^%*]*%*", "_[^%s_][^_]*_" }) do
        pos = 1
        while true do
          local s, e = line:find(pat, pos)
          if not s then break end
          if not contained(s, e) and free(s, e) then
            marks[#marks + 1] = { row = i - 1, col = s, length = e - s - 1, group = "PosteAiItalic" }
            marks[#marks + 1] = { row = i - 1, col = s - 1, length = 1, group = "PosteAiItalic", conceal = "" }
            marks[#marks + 1] = { row = i - 1, col = e - 1, length = 1, group = "PosteAiItalic", conceal = "" }
            taken[#taken + 1] = { s, e }
          end
          pos = e + 1
        end
      end
    end
  end

  return { marks = marks, bg_ranges = bg_ranges, code_blocks = code_blocks }
end

M._test = { specs = M.specs }

return M
