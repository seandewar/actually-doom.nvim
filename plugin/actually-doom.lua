local api = vim.api
local fn = vim.fn
local log = vim.log

if
  fn.has "nvim-0.11" == 0
  or fn.has "linux" == 0
  or not pcall(require, "string.buffer")
then
  vim.notify(
    '[actually-doom.nvim] Nvim v0.11+ on Linux with "string.buffer" library '
      .. "support is required",
    log.levels.ERROR
  )
  return
end

api.nvim_create_user_command("Doom", function(args)
  local iwad_path = args.fargs[1]

  if not args.bang then
    local ui = require "actually-doom.ui"
    local screen_buf = args.count
    if screen_buf ~= 0 then
      -- Jump to the buffer number specified as the count. Fail if it's invalid.
      if not api.nvim_buf_is_valid(screen_buf) then
        vim.notify(
          ("[actually-doom.nvim] Buffer %d does not exist"):format(screen_buf),
          log.levels.ERROR
        )
        return
      end

      local doom = ui.screen_buf_to_doom[screen_buf]
      if not doom or doom.closed then
        vim.notify(
          ("[actually-doom.nvim] No screen exists for buffer %d"):format(
            screen_buf
          ),
          log.levels.ERROR
        )
        return
      end
    elseif not iwad_path then
      -- Jump to the highest-numbered (most recently created) screen buffer.
      screen_buf = vim
        .iter(pairs(ui.screen_buf_to_doom))
        :fold(0, function(acc, buf, doom)
          return not doom.closed and math.max(acc, buf) or acc
        end)
    end

    if screen_buf > 0 then
      ui.screen_buf_to_doom[screen_buf].screen:goto_win()
      return
    end
  end

  require("actually-doom").play(iwad_path)
end, {
  desc = "Play DOOM",
  bang = true,
  count = true,
  nargs = "?",
  complete = "file",
  bar = true,
})
