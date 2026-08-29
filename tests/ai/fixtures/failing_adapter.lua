--- Mock provider adapter that always errors — used for the error-path test.

local M = {}

function M.stream(_cfg, _opts, handlers)
  vim.defer_fn(function()
    handlers.on_error("mock exploded")
  end, 10)
  return { cancel = function() end }
end

return M
