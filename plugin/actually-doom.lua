local api = vim.api
local fn = vim.fn

if fn.has "nvim-0.11" == 0 then
  api.nvim_echo(
    { { "[actually-doom.nvim] Nvim v0.11 or newer is required" } },
    true,
    { err = true }
  )
  return
end

api.nvim_create_user_command("Doom", function(_)
  require("actually-doom").play()
end, { desc = "Play DOOM", bar = true })
