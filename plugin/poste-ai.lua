-- poste-ai.nvim — AI assistant chat for the Poste plugin family.
-- Zero dependencies beyond Neovim >= 0.10 and curl.
if vim.g.loaded_poste_ai then
  return
end
vim.g.loaded_poste_ai = true

require("poste-ai").setup()
