--- @class (exact) ActuallyConfig
--- @field game PlayOpts?
--- @field build RebuildOpts?

local M = {
  --- @type ActuallyConfig
  config = {
    game = {},
    build = {},
  },
}

--- @param config ActuallyConfig?
function M.setup(config)
  M.config = vim.tbl_extend("force", M.config, config or {})
end

return M
