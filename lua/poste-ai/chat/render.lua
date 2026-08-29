--- Markdown rendering layer for the chat conversation buffer.
--- The conversation buffer always holds raw markdown (copy semantics stay
--- exact); this module computes highlight extmark specs over it. "Rendered"
--- vs "source" view is simply whether the extmarks are applied, so streaming
--- never rewrites buffer lines — no flicker by construction.
---
--- V1 supports: fenced code blocks (bg + fence/lang styling), headings,
--- horizontal rules, blockquotes, list bullets and inline code. Bold/italic
--- and tables are left as plain text.

local M = {}

--- Scan lines and produce highlight specs.
--- @param lines string[] raw markdown lines
--- @return table specs { marks = {{row,col,length,group,hl_mode}}, bg_ranges = {{start,end_,group}}, code_blocks = {{start,end_,lang,text}} }
---   rows are 0-based relative to the first input line; `end_` is inclusive.
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
      marks[#marks + 1] = { row = open_row, col = 0, length = #line, group = "PosteAiCodeFence" }
      if close_row <= n - 1 then
        marks[#marks + 1] = { row = close_row, col = 0, length = #(lines[close_row + 1] or ""), group = "PosteAiCodeFence" }
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
    elseif line:match("^%s*(%-%-%-+)%s*$") or line:match("^%s*(%*%*%*+)%s*$") or line:match("^%s*(___)%s*$") then
      marks[#marks + 1] = { row = i - 1, col = 0, length = #line, group = "PosteAiHr" }
    elseif line:match("^%s*>") then
      marks[#marks + 1] = { row = i - 1, col = 0, length = #line, group = "PosteAiQuote" }
    else
      -- list bullets / ordered numbers
      local col = line:match("^%s*()([%-%*%+])%s")
      if col then
        marks[#marks + 1] = { row = i - 1, col = col - 1, length = 1, group = "PosteAiBullet" }
      else
        local num = line:match("^%s*(%d+)%.%s")
        if num then
          local ncol = line:match("^%s*()%d+%.%s")
          marks[#marks + 1] = { row = i - 1, col = ncol - 1, length = #num + 1, group = "PosteAiBullet" }
        end
      end
      -- inline code spans (skip fence lines)
      local pos = 1
      while true do
        local s, e = line:find("`[^`]+`", pos)
        if not s then break end
        marks[#marks + 1] = { row = i - 1, col = s, length = e - s - 1, group = "PosteAiInlineCode" }
        pos = e + 1
      end
    end
  end

  return { marks = marks, bg_ranges = bg_ranges, code_blocks = code_blocks }
end

M._test = { specs = M.specs }

return M
