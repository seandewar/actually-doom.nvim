local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local has_bear = fn.executable('bear') == 1

-- Set &makeprg appropriately for compiling a debug build of actually-doom into
-- the usual actually-doom.nvim stdpath("data") directory.
api.nvim_create_autocmd({ "BufNewFile", "BufReadPost" }, {
  group = api.nvim_create_augroup("actually-doom.nvim-exrc", {}),
  pattern = "*/doom/*.{c,h}",
  callback = function(_)
    vim.cmd.compiler "make"
    vim.bo.makeprg = ("%smake -j%d -C %s OUTDIR=%s"):format(
      has_bear and "bear -- " or "",
      uv.available_parallelism(),
      fn.shellescape(fs.abspath "doom"),
      fn.shellescape(fs.joinpath(fn.stdpath "data", "actually-doom.nvim"))
    )
  end,
})
