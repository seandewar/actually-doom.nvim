local api = vim.api
local fn = vim.fn
local log = vim.log

if fn.has "nvim-0.11" == 0 then
  vim.notify(
    "[actually-doom.nvim] Nvim v0.11+ is required",
    log.levels.ERROR
  )
  return
end

if fn.has "linux" == 0 and fn.has "mac" == 0 then
  vim.notify(
    "[actually-doom.nvim] Linux or macOS is required",
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
