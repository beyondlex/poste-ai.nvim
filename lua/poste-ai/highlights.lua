--- Highlight groups for poste-ai. All groups have theme-aware fallback links;
--- re-applied on ColorScheme so links follow the active colorscheme.

local M = {}

local LINKS = {
  PosteAiUserLabel = "Title",
  PosteAiAssistantLabel = "Comment",
  PosteAiErrorLabel = "ErrorMsg",
  PosteAiErrorText = "DiagnosticError",
  PosteAiNote = "Comment",
  PosteAiCodeFence = "Comment",
  PosteAiCodeLang = "Special",
  PosteAiCodeBlock = "CursorLine",
  PosteAiHeading = "Title",
  PosteAiHr = "Comment",
  PosteAiQuote = "Comment",
  PosteAiBullet = "Special",
  PosteAiInlineCode = "Special",
  PosteAiBold = "Bold",
  PosteAiItalic = "Italic",
  PosteAiMention = "Special",
  PosteAiInputBorder = "Special",
  PosteAiWinbar = "Comment",
  PosteAiSpinner = "Special",
}

function M.setup()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link })
  end
  -- DiagnosticError may not exist in all colorschemes
  if vim.api.nvim_get_hl(0, { name = "PosteAiErrorText" }).link == "DiagnosticError" then
    local diag = vim.api.nvim_get_hl(0, { name = "DiagnosticError" })
    if not diag or vim.tbl_isempty(diag) then
      vim.api.nvim_set_hl(0, "PosteAiErrorText", { link = "ErrorMsg" })
    end
  end
end

M._test = { LINKS = LINKS }

return M
