local api = vim.api
local fn = vim.fn

if
  fn.has "nvim-0.11" == 0
  or fn.has "linux" == 0
  or not pcall(require, "string.buffer")
then
  api.nvim_echo({
    {
      '[actually-doom.nvim] Nvim v0.11+ on Linux with "string.buffer" library '
        .. "support is required",
    },
  }, true, { err = true })
  return
end

api.nvim_create_user_command("Doom", function(_)
  require("actually-doom").play()
end, { desc = "Play DOOM", bar = true })
