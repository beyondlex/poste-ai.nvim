-- Minimal Neovim configuration for running poste-ai tests.
-- Used as -u script (actual vimrc replacement). poste-ai has no dependencies,
-- so only the repo itself is added to the runtimepath.

vim.opt.runtimepath:append(".")

package.path = package.path
  .. ";./tests/?.lua"
  .. ";./tests/?/init.lua"
