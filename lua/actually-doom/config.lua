local fn = vim.fn

local M = {
  --- @class (exact) ActuallyConfig
  --- @field game PlayOpts?
  --- @field build RebuildOpts?
  config = {
    game = {},
    build = {},
  },
}

-- Custom merge functions for tbl_*extend are only available since Nvim v0.12.
if fn.has "nvim-0.12" == 1 then
  --- @param config ActuallyConfig?
  function M.setup(config)
    M.config = vim.tbl_deep_extend(function(_, _, val)
      return val ~= vim.NIL and val or nil
    end, M.config, config or {})
  end
else
  --- @param config ActuallyConfig?
  function M.setup(config)
    M.config = vim.tbl_deep_extend("force", M.config, config or {})

    --- @param t table
    local function remove_nils(t)
      for k, v in pairs(t) do
        if v == vim.NIL then
          t[k] = nil -- Setting to nil while iterating is OK (see `:h next()`)
        elseif type(v) == "table" and not vim.islist(v) then
          remove_nils(v)
        end
      end
    end
    remove_nils(M.config)
  end
end

return M
