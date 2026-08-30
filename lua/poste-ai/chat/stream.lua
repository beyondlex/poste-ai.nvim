--- Streaming orchestration — the send pipeline:
---   input text → parse @mentions → resolve context blocks → compose LLM
---   message → provider stream → throttled conversation updates → session save.
--- Owns the busy state, cancellation and tail-follow logic.

local config = require("poste-ai.config")
local state = require("poste-ai.state")
local registry = require("poste-ai.provider.registry")
local conversation = require("poste-ai.chat.conversation")
local window = require("poste-ai.chat.window")
local mention = require("poste-ai.chat.mention")
local context_api = require("poste-ai.context_api")

local M = {}

local st = {
  busy = false,
  handle = nil,       -- provider stream handle
  seq = 0,            -- epoch guard: callbacks from older requests are dropped
  follow = true,      -- tail-follow the conversation while streaming
  flush_timer = nil,
  current = nil,      -- { assistant_text, session_msg }
}

local FLUSH_INTERVAL_MS = 80

function M.is_busy() return st.busy end

function M.set_follow(v) st.follow = v and true or false end

--- True when the conversation window shows the last line.
function M.following()
  local win = window.conversation_win()
  if not win then return st.follow end
  return window.at_bottom(win)
end

local function scroll_follow()
  local win = window.conversation_win()
  if not win or not st.follow then return end
  local buf = window.conversation_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
end

local function cancel_flush_timer()
  -- NB: defer_fn returns a uv timer object; `vim.fn.timer_stop` would try to
  -- convert it to a typval and print E5101. Stop it natively instead.
  local t = st.flush_timer
  if t then
    st.flush_timer = nil
    pcall(function()
      if not t:is_closing() then
        t:stop()
        t:close()
      end
    end)
  end
end

local function flush_now()
  cancel_flush_timer()
  if not st.current then return end
  conversation.update_last_assistant(st.current.assistant_text)
  scroll_follow()
end

local function schedule_flush(seq)
  if st.flush_timer or st.seq ~= seq then return end
  st.flush_timer = vim.defer_fn(function()
    st.flush_timer = nil
    if st.seq ~= seq or not st.current then return end
    conversation.update_last_assistant(st.current.assistant_text)
    scroll_follow()
  end, FLUSH_INTERVAL_MS)
end

--- History messages for the provider from persisted session messages.
local function history_messages(session_msgs)
  local out = {}
  for _, m in ipairs(session_msgs) do
    if m.role == "user" or m.role == "assistant" then
      local content = m.content or m.text or ""
      if content ~= "" then out[#out + 1] = { role = m.role, content = content } end
    end
  end
  return out
end

--- Finalize the in-flight request exactly once. `err` non-nil renders an
--- error block; `result.cancelled` renders a note instead.
local function finalize(seq, err, result)
  if st.seq ~= seq then return end
  result = result or {}
  st.current = st.current or { assistant_text = "" }
  flush_now()
  local session = require("poste-ai.chat.session")
  local cur = session.current()

  if st.current.session_msg then
    st.current.session_msg.text = st.current.assistant_text
    st.current.session_msg.ts = os.time()
  end

  if err then
    conversation.append_error(err)
    st.current.session_msg.errored = true
  elseif result.cancelled then
    conversation.append_note("· cancelled")
  end

  st.busy = false
  st.handle = nil
  cur.updated_at = os.time()
  pcall(session.save, cur)
  st.current = nil
  window.update_winbar()
  scroll_follow()
end

--- Send a user message. `text` is the raw input (mentions included).
--- Returns false when the request was rejected (empty or busy).
--- @param text string
--- @return boolean
function M.send(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return false end
  if st.busy then
    vim.notify("poste-ai: still streaming — press Esc or :PosteAICancel first", vim.log.levels.WARN, { title = state.TITLE })
    return false
  end

  local cfg, cfg_err = config.resolve_provider()
  if not cfg then
    conversation.append_error(cfg_err)
    window.update_winbar()
    return false
  end

  local session = require("poste-ai.chat.session")
  local cur = session.current()

  -- mentions → context blocks; the context may also contribute an implicit
  -- auto_context block (e.g. an auto-injected schema) ahead of them
  local refs = mention.parse(text)
  local scope_snapshot = require("poste-ai.chat.scope").snapshot()
  local spec_now = context_api.active()
  local auto_ctx = spec_now and type(spec_now.auto_context) == "function" and spec_now.auto_context or nil

  local function compose(auto_md)
    mention.resolve_all(refs, function(blocks_md)
      local blocks = {}
      if auto_md and auto_md ~= "" then blocks[#blocks + 1] = auto_md end
      if blocks_md and blocks_md ~= "" then blocks[#blocks + 1] = blocks_md end
      local user_content = text
      if #blocks > 0 then user_content = text .. "\n\n" .. table.concat(blocks, "\n\n") end

      local user_msg = {
        role = "user", text = text, content = user_content, ts = os.time(), refs = refs,
        scope = require("poste-ai.chat.scope").snapshot(),
      }
      cur.messages[#cur.messages + 1] = user_msg

      conversation.append_user(text)
      conversation.begin_assistant(cfg.model)
      local session_msg = { role = "assistant", text = "", model = cfg.model }
      cur.messages[#cur.messages + 1] = session_msg
      st.current = { assistant_text = "", session_msg = session_msg }

      local messages = { { role = "system", content = context_api.system_prompt() } }
      vim.list_extend(messages, history_messages(cur.messages))

      local req = {
        messages = messages,
        temperature = config.config.request.temperature,
        max_tokens = config.config.request.max_tokens,
        timeout_ms = config.config.request.timeout_ms,
      }

      local adapter, adapter_err = registry.get(cfg)
      if not adapter then
        finalize(st.seq, adapter_err or "no provider adapter")
        return
      end

      st.busy = true
      st.seq = st.seq + 1
      local seq = st.seq
      window.update_winbar()
      scroll_follow()

      local ok_stream, handle = pcall(adapter.stream, cfg, req, {
        on_delta = function(delta)
          if st.seq ~= seq or not st.current then return end
          st.current.assistant_text = st.current.assistant_text .. delta
          schedule_flush(seq)
        end,
        on_finish = function(result)
          if st.seq ~= seq or not st.current then return end
          if result and result.content and result.content ~= "" then
            st.current.assistant_text = result.content
          end
          finalize(seq, nil, result)
        end,
        on_error = function(err)
          if st.seq ~= seq or not st.current then return end
          finalize(seq, err, nil)
        end,
      })
      if not ok_stream then
        finalize(seq, "stream failed: " .. tostring(handle))
        return
      end
      st.handle = handle
    end)
  end

  if type(auto_ctx) ~= "function" then
    compose(nil)
    return true
  end

  -- the auto context is async (introspection etc.); 10s guard like mentions
  local done = false
  local timer = vim.defer_fn(function()
    if done then return end
    done = true
    compose(nil)
  end, 10000)
  local ok_ctx, ctx_err = pcall(auto_ctx, text, scope_snapshot, function(md)
    if done then return end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function() compose(type(md) == "string" and md or nil) end)
  end)
  if not ok_ctx and not done then
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.notify("poste-ai: auto context failed: " .. tostring(ctx_err),
      vim.log.levels.WARN, { title = state.TITLE })
    compose(nil)
  end
  return true
end

--- Submit whatever is in the input buffer (clears it on success).
--- Slash commands ("/new", "/connections", ...) are intercepted and executed
--- instead of being sent to the LLM.
function M.submit_from_input()
  local slash = require("poste-ai.chat.slash")
  local text = window.input_text()
  if (text:gsub("%s", "")) == "" then return end
  window.open()  -- no-op when open; creates panes when the user closed them
  if slash.submit(text) then
    -- argument-mode popups keep the input (the user still filters/picks);
    -- executed commands have already cleaned it up themselves
    if not require("poste-ai.chat.popup").is_open() then
      slash.reset()
      window.clear_input()
    end
    return
  end
  if M.send(text) then
    window.clear_input()
    slash.reset()
  end
end

--- Cancel the in-flight request (no-op when idle).
function M.cancel()
  if not st.busy or not st.handle then return end
  st.handle.cancel()
end

--- Hard reset of streaming state (used by tests / recovery).
function M.force_reset()
  if st.handle then pcall(function() st.handle.cancel() end) end
  cancel_flush_timer()
  st.busy = false
  st.handle = nil
  st.current = nil
  st.seq = st.seq + 1
  window.update_winbar()
end

M._test = {
  state = st,
  history_messages = history_messages,
  finalize = finalize,
}

return M
