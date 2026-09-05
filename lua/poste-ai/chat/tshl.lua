--- Treesitter syntax highlighting for fenced code blocks.
--- Parses block text off-screen via `vim.treesitter.get_string_parser` and
--- maps highlight-query captures to extmark specs. Pure logic + a result
--- cache; any failure (parser or query missing — e.g. `sql` is often absent)
--- yields `{}` so callers silently fall back to the block background.

local M = {}

local LANG_ALIASES = {
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  console = "bash",
  js = "javascript",
  ts = "typescript",
  jsx = "javascript",
  tsx = "typescript",
  py = "python",
  rb = "ruby",
  yml = "yaml",
  md = "markdown",
  plaintext = "",
  text = "",
  txt = "",
}

local cache = {}    -- lang .. "\0" .. text → specs
local cache_n = 0
-- Streaming re-renders the growing block once per flush tick, each with a
-- slightly different full text; without a cap the cache would keep one copy
-- of every intermediate block until nvim exits.
local CACHE_MAX = 256

--- Normalize an infostring language to a treesitter language name.
--- @return string|nil nil when the language should not be highlighted
local function resolve_lang(lang)
  lang = (lang or ""):lower()
  if LANG_ALIASES[lang] ~= nil then lang = LANG_ALIASES[lang] end
  if lang == "" then return nil end
  return lang
end

--- Compute highlight specs for a code block.
--- @param text string raw block text (no fence lines)
--- @param lang string infostring from the opening fence
--- @return table specs {{row,col,end_row,end_col,group}} — 0-based, relative
---   to the first line of `text`
function M.specs(text, lang)
  if not text or text == "" then return {} end
  lang = resolve_lang(lang)
  if not lang then return {} end

  local key = lang .. "\0" .. text
  if cache[key] then return cache[key] end
  if cache_n >= CACHE_MAX then
    cache = {}
    cache_n = 0
  end
  cache_n = cache_n + 1
  cache[key] = {}  -- pessimistic: failures stay cached too

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then return cache[key] end
  local ok_parse, trees = pcall(function()
    parser:parse(true)
    return parser:trees()
  end)
  if not ok_parse or not trees or #trees == 0 then return cache[key] end
  local ok_q, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok_q or not query then return cache[key] end

  local specs = {}
  local nlines = #vim.split(text, "\n", { plain = true })
  for _, tree in ipairs(trees) do
    for id, node, metadata in query:iter_captures(tree:root(), text, 0, -1) do
      local capture = query.captures[id]
      local srow, scol, erow, ecol = node:range()
      if metadata and metadata[id] and metadata[id].range then
        local r = metadata[id].range
        srow, scol, erow, ecol = r[1], r[2], r[3], r[4]
      end
      if srow <= erow and erow <= nlines - 1 then
        local group = "@" .. capture .. "." .. lang
        if vim.fn.hlexists(group) ~= 1 then group = "@" .. capture end
        specs[#specs + 1] = { row = srow, col = scol, end_row = erow, end_col = ecol, group = group }
      end
    end
  end
  cache[key] = specs
  return specs
end

M._test = {
  specs = M.specs,
  resolve_lang = resolve_lang,
  _cache = function() return cache end,
  _reset = function() cache = {} cache_n = 0 end,
}

return M
