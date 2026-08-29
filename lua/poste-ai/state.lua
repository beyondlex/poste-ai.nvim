--- poste-ai runtime state — cross-cutting flags shared between modules.
--- Session content lives in `chat/session.lua`; window/buffer handles live in
--- `chat/window.lua`. Only truly global flags go here.

local M = {}

--- Currently active context id (e.g. "db") or nil for generic chat.
--- Managed via `poste-ai.context_api`.
M.active_context = nil

--- Buffer that was current when the chat window was opened — the default
--- target for the code-block "append" action.
M.origin_buf = nil

--- Notification title used across the plugin.
M.TITLE = "PosteAI"

return M
