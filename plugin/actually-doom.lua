local api = vim.api
local fn = vim.fn
local log = vim.log

if fn.has "nvim-0.11" == 0 or fn.has "linux" == 0 then
  vim.notify(
    "[actually-doom.nvim] Nvim v0.11+ on Linux is required",
    log.levels.ERROR
  )
  return
end

api.nvim_create_user_command("Doom", function(...)
  return require("actually-doom.game").play_cmd(...)
end, {
  desc = "Play DOOM",
  bang = true,
  count = true,
  nargs = "?",
  complete = "file",
  bar = true,
})
