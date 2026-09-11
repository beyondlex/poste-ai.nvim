--- @ mention engine. Parses "@token" references out of chat input, provides
--- completion candidates, and resolves refs into markdown context blocks.
--- Registered contexts match their own tokens first (e.g. "my-conn/mydb");
--- anything unmatched falls back to file references, with an optional line
--- range: "@src/app.lua(10-20)".

local context_api = require("poste-ai.context_api")
local state = require("poste-ai.state")
local text_util = require("poste-ai.text")

local M = {}

--- Strip trailing sentence punctuation from a mention token. Closing parens
--- are kept — line-range refs like "file.lua(1-2)" need them.
local function clean_token(token)
  return (token:gsub("[%.,%]%}%!%?]+$", ""))
end

--- Parse a token into a file ref, or nil.
local function file_ref(token)
  local path, l1, l2 = token:match("^(.+)%((%d+)%-(%d+)%)$")
  if not path then
    -- single-line range form "@path(10)" — exactly what range_mention emits
    -- for a one-line visual selection; l2 == l1
    path, l1 = token:match("^(.+)%((%d+)%)$")
    l2 = l1
  end
  if not path then path = token end
  if path == "" then return nil end
  local resolved = M._resolve_path(path)
  if not resolved then return nil end
  local ref = { type = "file", path = path, abspath = resolved, token = token }
  if l1 then ref.l1 = tonumber(l1) ref.l2 = tonumber(l2) end
  return ref
end

--- Locate a mentioned file: relative to cwd first, then the directory of the
--- origin buffer, then absolute.
function M._resolve_path(path)
  if path:sub(1, 1) == "/" then
    return vim.loop.fs_stat(path) and path or nil
  end
  local candidates = { vim.fn.getcwd() .. "/" .. path }
  local origin = state.origin_buf
  if origin and vim.api.nvim_buf_is_valid(origin) then
    local name = vim.api.nvim_buf_get_name(origin)
    if name ~= "" then
      candidates[#candidates + 1] = vim.fn.fnamemodify(name, ":h") .. "/" .. path
    end
  end
  for _, cand in ipairs(candidates) do
    if vim.loop.fs_stat(cand) then return cand end
  end
  return nil
end

--- Parse all mentions out of a message. Contexts match first, files second.
--- Duplicate tokens are collapsed.
--- @param text string
--- @return table refs { {type="context",context,token,data} | {type="file",path,...} }
function M.parse(text)
  local refs, seen = {}, {}
  local pos = 1
  while true do
    local s, e = text:find("@[%S]+", pos)
    if not s then break end
    pos = e + 1
    local token = clean_token(text:sub(s + 1, e))
    if token ~= "" and not seen[token] then
      seen[token] = true
      local ref = nil
      for _, id in ipairs(context_api.list()) do
        local spec = context_api.get(id)
        if spec and spec.mention and type(spec.mention.match) == "function" then
          local ok, matched = pcall(spec.mention.match, token)
          if ok and matched then
            ref = { type = "context", context = id, token = token, data = matched }
            break
          end
        end
      end
      if not ref then ref = file_ref(token) end
      if ref then refs[#refs + 1] = ref end
    end
  end
  return refs
end

local EXT_LANG = {
  sql = "sql", lua = "lua", py = "python", js = "javascript", ts = "typescript",
  go = "go", rs = "rust", toml = "toml", md = "markdown", json = "json",
  sh = "bash", vim = "vim", c = "c", h = "c", cpp = "cpp", rb = "ruby",
  java = "java", yml = "yaml", yaml = "yaml", html = "html", css = "css",
}

local function lang_for(path)
  return EXT_LANG[path:match("%.(%w+)$")] or ""
end

local MAX_BLOCK_CHARS = 8000

--- Render one ref as a markdown context block. Sync for files; contexts
--- resolve via their callback.
--- @param ref table
--- @param cb function(block_md, err)
local function resolve_ref(ref, cb)
  if ref.type == "file" then
    local ok, lines = pcall(vim.fn.readfile, ref.abspath)
    if not ok or type(lines) ~= "table" then
      cb(nil, "unreadable: " .. ref.path)
      return
    end
    local l1, l2 = ref.l1, ref.l2
    if l1 or l2 then
      if l1 and l2 and l1 > l2 then l1, l2 = l2, l1 end  -- @f(50-10) typo
      l1 = math.max(1, l1 or 1)
      l2 = math.min(#lines, l2 or #lines)
      lines = vim.list_slice(lines, l1, l2)
    end
    local header = ("### @%s"):format(ref.token)
    if l1 then header = header .. (" (lines %d-%d)"):format(l1, l2) end
    local body = table.concat(lines, "\n")
    if #body > MAX_BLOCK_CHARS then
      -- char-safe cut at the byte budget: a plain sub split multibyte
      -- characters and sent invalid UTF-8 to the provider
      body = text_util.utf8_safe_cut(body, MAX_BLOCK_CHARS) .. "\n… (truncated)"
    end
    local lang = lang_for(ref.path)
    cb(header .. "\n```" .. lang .. "\n" .. body .. "\n```", nil)
    return
  end

  local spec = context_api.get(ref.context)
  if not spec or not spec.mention or type(spec.mention.resolve) ~= "function" then
    cb(nil, "no resolver for @" .. ref.token)
    return
  end
  local ok, err = pcall(spec.mention.resolve, ref.data, function(md, rerr)
    cb(md, rerr)
  end)
  if not ok then cb(nil, "resolver failed: " .. tostring(err)) end
end

--- Resolve a list of refs into combined markdown context blocks. Always calls
--- back exactly once; unresolved refs are noted inline rather than failing.
--- @param refs table
--- @param cb function(blocks_md)
function M.resolve_all(refs, cb)
  if #refs == 0 then cb("") return end
  local blocks = {}
  local remaining = #refs
  local finished = false
  local function done()
    if finished then return end
    finished = true
    cb(table.concat(blocks, "\n\n"))
  end
  for i, ref in ipairs(refs) do
    local timer = vim.defer_fn(function()
      if blocks[i] == nil then
        blocks[i] = ("### @%s\n(unavailable: timed out)"):format(ref.token)
        remaining = remaining - 1
        if remaining <= 0 then done() end
      end
    end, 10000)
    resolve_ref(ref, function(md, err)
      -- NB: stop the uv timer natively; vim.fn.timer_stop would print E5101
      pcall(function()
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end)
      if blocks[i] ~= nil then return end  -- timed out earlier
      if err or not md then
        blocks[i] = ("### @%s\n(unavailable: %s)"):format(ref.token, tostring(err or "empty"))
      else
        blocks[i] = md
      end
      remaining = remaining - 1
      if remaining <= 0 then done() end
    end)
  end
end

--- File mention for a buffer line range (visual-select flow).
--- @param buf number
--- @param l1 number 1-based
--- @param l2 number 1-based inclusive
--- @return string|nil "@path(l1-l2)"
function M.range_mention(buf, l1, l2)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil end
  local rel = vim.fn.fnamemodify(name, ":.")
  if rel:sub(1, 1) == "/" then rel = name end
  if l1 > l2 then l1, l2 = l2, l1 end
  if l1 == l2 then return ("@%s(%d)"):format(rel, l1) end
  return ("@%s(%d-%d)"):format(rel, l1, l2)
end

--- Gather completion candidates for a "@prefix" in the input buffer and open
--- the popup. Context candidates come first, files second (capped).
--- @param prefix string text typed after the @
--- @param startcol number 1-based column the popup replaces from
function M.complete(prefix, startcol)
  local items = {}
  local remaining = #context_api.list()
  local fired = false
  local function fire()
    if fired then return end
    fired = true
    -- files (only when no context claimed the prefix, or always appended)
    local ok_files, files = pcall(vim.fn.getcompletion, prefix, "file")
    if ok_files and type(files) == "table" then
      for i, f in ipairs(files) do
        if i > 30 then break end
        items[#items + 1] = { word = f, menu = "[file]" }
      end
    end
    if #items > 0 then
      vim.fn.complete(startcol, items)
    end
  end

  local contexts = context_api.list()
  if #contexts == 0 then fire() return end
  for _, id in ipairs(contexts) do
    local spec = context_api.get(id)
    if spec and spec.mention and type(spec.mention.complete) == "function" then
      local ok = pcall(spec.mention.complete, prefix, function(cands)
        remaining = remaining - 1
        if type(cands) == "table" then
          for _, c in ipairs(cands) do
            items[#items + 1] = { word = c.label or c, menu = c.description or ("[@" .. id .. "]") }
          end
        end
        if remaining <= 0 then fire() end
      end)
      if not ok then remaining = remaining - 1 end
    else
      remaining = remaining - 1
    end
  end
  if remaining <= 0 then fire() end
  -- safety: if callbacks never arrive, don't leave the popup pending forever
  vim.defer_fn(function() fire() end, 500)
end

M._test = {
  clean_token = clean_token,
  file_ref = file_ref,
  parse = M.parse,
  range_mention = M.range_mention,
}

return M
