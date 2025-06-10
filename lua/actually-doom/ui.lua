local api = vim.api
local fn = vim.fn
local log = vim.log

local strbuf = require "actually-doom.strbuf"

local M = {
  --- @type table<integer, Doom>
  screen_buf_to_doom = {},
  -- Scratch buffer for holding temporary data to be used for various purposes.
  -- It lives at this scope so the allocated space can be re-used.
  scratch_buf = strbuf.new(),
}

local ns = api.nvim_create_namespace "actually-doom"
local augroup = api.nvim_create_augroup("actually-doom", {})

do
  local ctrl_bs = vim.keycode "<C-Bslash>"
  local ctrl_k = vim.keycode "<C-K>"
  local ctrl_n = vim.keycode "<C-N>"
  local ctrl_o = vim.keycode "<C-O>"
  local ctrl_t = vim.keycode "<C-T>"

  vim.on_key(function(key)
    if api.nvim_get_mode().mode ~= "t" then
      return
    end
    local doom = M.screen_buf_to_doom[api.nvim_get_current_buf()]
    if not doom or doom.closed then
      return
    end

    -- Keys modifiers may not be simplified in Terminal mode (e.g: ^\ received
    -- as K_SPECIAL ... KS_MODIFIER MOD_MASK_CTRL \) as a consequence of Nvim
    -- implementing kitty keyboard protocol support; simplify them.
    key = vim.keycode(fn.keytrans(key))
    if key == ctrl_bs or key == ctrl_n or key == ctrl_o then
      return -- May be used to leave Terminal mode; don't intercept.
    elseif key == ctrl_k then
      doom:enable_kitty(not doom.screen:kitty_gfx())
      return "" -- Nom nom nom
    elseif key == ctrl_t then
      doom.screen:enable_tmux_passthrough(not doom.screen.tmux_passthrough)
      return "" -- *crunch*
    end

    -- Bubbling up the error will cause on_key to unregister our callback, which
    -- is bad as we only register it once, so don't do that.
    local ok, rv = pcall(
      doom.close_on_err,
      doom,
      require("actually-doom.game").Doom.press_vim_key,
      doom,
      key
    )
    return ok and rv or nil
  end, ns)
end

-- In the case where a window switches its buffer, it would be nice to use
-- BufWin{Enter,Leave} instead of BufEnter,WinClosed with simplified logic, but
-- as they rely on the buffer's hidden state they're (unfortunately) influenced
-- by windows in other tabpages.
api.nvim_create_autocmd({ "BufEnter", "WinClosed", "VimEnter" }, {
  group = augroup,
  callback = function(args)
    if vim.tbl_isempty(M.screen_buf_to_doom) then
      return
    end
    local bufs
    if args.event == "WinClosed" then
      local win = assert(tonumber(args.match))
      -- Map windows to their current buffers in-place, skipping the closing
      -- window (without pointlessly creating a new table like vim.tbl_map).
      bufs = api.nvim_tabpage_list_wins(0)
      for i, w in ipairs(bufs) do
        bufs[i] = w ~= win and api.nvim_win_get_buf(w) or -1
      end
    else
      bufs = fn.tabpagebuflist()
    end

    for buf, doom in pairs(M.screen_buf_to_doom) do
      if not doom.closed then
        local old_visible = doom.screen.visible
        doom.screen.visible = vim.list_contains(bufs, buf)

        if not old_visible and doom.screen.visible then
          doom.console:plugin_print("Game visible; redraws ON\n", "Debug")
          doom:send_frame_request()
          doom:schedule_check()
        elseif old_visible and not doom.screen.visible then
          doom.console:plugin_print("Game hidden; redraws OFF\n", "Debug")
        end
      end
    end
  end,
  desc = "[actually-doom.nvim] Pause redraws when screen is not visible",
})

api.nvim_create_autocmd("WinLeave", {
  group = augroup,
  nested = true,
  callback = function()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_win_get_buf(win)
    local doom = M.screen_buf_to_doom[buf]
    if not doom or doom.closed or win ~= doom.screen.win then
      return
    end
    -- We close the window when leaving because it's confusing when a different
    -- window has focus (the float is large and likely to overlap and hide the
    -- cursor), so no need if the window was made non-floating.
    if api.nvim_win_get_config(win).relative == "" then
      return
    end
    api.nvim_win_close(win, true)
  end,
  desc = "[actually-doom.nvim] Close floating screen window when leaving",
})

--- @param width integer?
--- @param height integer?
--- @return vim.api.keyset.win_config
--- @nodiscard
local function new_screen_win_config(width, height)
  local editor_width = api.nvim_get_option_value("columns", {})
  -- No way to get &cmdheight for a non-current tabpage yet (that isn't hacky).
  local editor_height = api.nvim_get_option_value("lines", {})
    - api.nvim_get_option_value("cmdheight", {})

  width = math.max(1, width or editor_width)
  -- Minus 1 for the title border.
  height = math.max(1, height or (editor_height - 1))

  return {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((editor_width - width) * 0.5)),
    -- Minus 1 for the title border.
    row = math.max(0, math.floor((editor_height - height - 1) * 0.5)),
    style = "minimal",
    border = { "", "─", "", "", "", "", "", "" },
  }
end

-- As there's no way to get the correct &cmdheight of a non-current tabpage,
-- run this on TabEnter too and only resize windows in the current tabpage.
api.nvim_create_autocmd({ "VimResized", "VimEnter", "TabEnter", "OptionSet" }, {
  group = augroup,
  nested = true,
  callback = function(args)
    if vim.tbl_isempty(M.screen_buf_to_doom) then
      return
    end
    -- OptionSet only relevant if &cmdheight was changed, as the float can't
    -- overlap with the command-line area.
    if args.event == "OptionSet" and args.match ~= "cmdheight" then
      return
    end

    local tp = api.nvim_get_current_tabpage()
    for _, doom in pairs(M.screen_buf_to_doom) do
      if
        doom
        and not doom.closed
        and doom.screen.win
        and api.nvim_win_is_valid(doom.screen.win)
        and api.nvim_win_get_tabpage(doom.screen.win) == tp
        and api.nvim_win_get_config(doom.screen.win).relative ~= "" -- Floating.
      then
        api.nvim_win_set_config(doom.screen.win, new_screen_win_config())
      end
    end
  end,
  desc = "[actually-doom.nvim] Resize floating screen windows to fit editor",
})
api.nvim_create_autocmd("WinResized", {
  group = augroup,
  callback = function()
    if vim.tbl_isempty(M.screen_buf_to_doom) then
      return
    end

    for _, win in ipairs(vim.v.event.windows) do
      if
        api.nvim_win_is_valid(win)
        and api.nvim_win_get_config(win).relative ~= "" -- Floating.
      then
        local doom = M.screen_buf_to_doom[api.nvim_win_get_buf(win)]
        if doom and not doom.closed and win == doom.screen.win then
          api.nvim_win_set_config(win, new_screen_win_config())
        end
      end
    end
  end,
  desc = "[actually-doom.nvim] Resize floating screen windows to fit editor",
})

api.nvim_create_autocmd("WinClosed", {
  group = augroup,
  callback = function(args)
    local win = assert(tonumber(args.match))
    local buf = api.nvim_win_get_buf(win)
    local doom = M.screen_buf_to_doom[buf]
    if not doom or doom.closed then
      return
    end
    if doom.screen.win == win then
      doom.screen.win = nil
    end

    -- Window may have been closed *because* the buffer was unloaded, so we
    -- don't want to print the hint in that case. As the unload may have been
    -- scheduled, schedule this 2 event loop ticks later so this happens after.
    vim.schedule(vim.schedule_wrap(function()
      if doom.closed or fn.bufwinnr(buf) ~= -1 then
        return
      end
      -- Pretty clear it's from this plugin, so don't bother with the
      -- "[actually-doom.nvim]" prefix; helps avoid hit-ENTER anyway.
      vim.notify(
        (
          "DOOM is still running! "
          .. 'Use ":%dDoom" to resume, or ":%dbd!" to quit'
        ):format(buf, buf),
        log.levels.INFO
      )
    end))
  end,
  desc = "[actually-doom.nvim] Print hint when all screens in tabpage close",
})

api.nvim_set_hl(0, "DoomConsoleError", {
  default = true,
  link = "ErrorMsg",
})
api.nvim_set_hl(0, "DoomConsoleWarn", {
  default = true,
  link = "WarningMsg",
})
api.nvim_set_hl(0, "DoomConsolePlugin", {
  default = true,
  link = "Special",
})
api.nvim_set_hl(0, "DoomConsoleDebug", {
  default = true,
  link = "Comment",
})

--- @class (exact) Console
--- @field doom Doom?
--- @field buf integer
--- @field close_autocmd integer?
---
--- @field new function
local Console = {}

--- @param console Console
local function update_console_buf_name(console)
  if not api.nvim_buf_is_valid(console.buf) then
    return
  end

  local old_name = api.nvim_buf_get_name(console.buf)
  local new_name = ("actually-doom://console//%d"):format(console.buf)
  if console.doom and console.doom.process then
    new_name = ("%s:%d"):format(new_name, console.doom.process.pid)
  end

  if new_name ~= old_name then
    api.nvim_buf_set_name(console.buf, new_name)
    if old_name ~= "" then
      -- Wipeout the (alternate) buffer that now holds the old name.
      local old_name_buf = fn.bufnr(("^%s$"):format(fn.fnameescape(old_name)))
      if old_name_buf ~= -1 then
        api.nvim_buf_delete(old_name_buf, { force = true })
      end
    end
  end
end

--- @return Console
--- @nodiscard
function Console.new()
  local console = setmetatable({
    last_row = 0,
    last_col = 0,
    buf = api.nvim_create_buf(true, true),
  }, { __index = Console })

  api.nvim_set_option_value("modifiable", false, { buf = console.buf })
  api.nvim_command(("tab %d sbuffer"):format(console.buf))
  update_console_buf_name(console)
  return console
end

function Console:close()
  if self.close_autocmd then
    api.nvim_del_autocmd(self.close_autocmd)
  end
end

--- @param doom Doom
function Console:set_doom(doom)
  assert(not self.doom)
  self.doom = doom
  update_console_buf_name(self)

  -- Not a global autocmd as we may not have a screen yet when it's called.
  self.close_autocmd = api.nvim_create_autocmd("BufUnload", {
    group = augroup,
    nested = true,
    callback = vim.schedule_wrap(function(args)
      if
        args.buf == doom.console.buf
        or (doom.screen and args.buf == doom.screen.buf)
      then
        doom.console:plugin_print "Game buffer was unloaded; quitting\n"
        doom:close()
        return true -- Delete this autocmd (close should've done that anyway)
      end
    end),
    desc = "[actually-doom.nvim] Quit game when buffers are unloaded",
  })
end

--- @param text string
--- @param console_hl string?
function Console:print(text, console_hl)
  if text == "" then
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      self:print(text, console_hl)
    end)
    return
  end
  if not api.nvim_buf_is_loaded(self.buf) then
    return
  end
  console_hl = console_hl and ("DoomConsole" .. console_hl) or nil

  -- Avoid side-effects, particularly from OptionSet.
  -- Not using vim._with here to avoid breakage when it graduates. Also not
  -- saving/restoring &eventignore as I can't be bothered to handle the
  -- possibility of Lua errors bailing out before restoring it. I'm lazy >:(
  api.nvim_command(
    ("noautocmd call setbufvar(%d, '&modifiable', 1)"):format(self.buf)
  )

  -- Previously we cached the details of the last extmark and the position of
  -- end of the buffer, but as it's possible for those to be invalidated (e.g:
  -- naughty plugins messing with the buffer), it's easier to just not do that.
  local last_line_row = math.max(0, api.nvim_buf_line_count(self.buf) - 1)
  local last_line_len
  local hl_extmark

  if console_hl then
    last_line_len = #api.nvim_buf_get_lines(self.buf, -2, -1, true)[1]
    hl_extmark =
      api.nvim_buf_get_extmarks(self.buf, ns, -1, { last_line_row, 0 }, {
        limit = 1,
        type = "highlight",
        details = true,
      })[1] --[[@as vim.api.keyset.get_extmark_item?]]
    if
      hl_extmark
      and (
        hl_extmark[4].end_col ~= last_line_len
        or hl_extmark[4].hl_group ~= console_hl
      )
    then
      hl_extmark = nil -- Extmark not at the end of the buffer.
    end
  end

  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_text(self.buf, -1, -1, -1, -1, lines)
  local new_last_line_row = math.max(0, api.nvim_buf_line_count(self.buf) - 1)

  if hl_extmark or console_hl then
    local new_last_line_len = #api.nvim_buf_get_lines(self.buf, -2, -1, true)[1]
    if hl_extmark then
      -- Same highlight as the last extmark; extend its range.
      api.nvim_buf_set_extmark(self.buf, ns, hl_extmark[2], hl_extmark[3], {
        id = hl_extmark[1],
        hl_group = console_hl,
        end_row = new_last_line_row,
        end_col = new_last_line_len,
      })
    else
      -- Last extmark has different highlight or doesn't exist; can't reuse it.
      api.nvim_buf_set_extmark(self.buf, ns, last_line_row, last_line_len, {
        hl_group = console_hl,
        end_row = new_last_line_row,
        end_col = new_last_line_len,
      })
    end
  end

  api.nvim_command(
    ("noautocmd call setbufvar(%d, '&modifiable', 0)"):format(self.buf)
  )

  -- Tail console windows on the last line to the output.
  -- nvim_buf_set_text does not automatically scroll windows, even if it changes
  -- the cursor position to be outside of it.
  for _, win in ipairs(fn.win_findbuf(self.buf)) do
    local row, col = unpack(api.nvim_win_get_cursor(win))
    if row == new_last_line_row + 1 then
      api.nvim_win_set_cursor(win, { new_last_line_row + 1, col })
    end
  end
end

--- @see Console.print
--- @param text string
--- @param console_hl string? If nil, defaults to "Plugin"
function Console:plugin_print(text, console_hl)
  return self:print("[actually-doom.nvim] " .. text, console_hl or "Plugin")
end

--- @class (exact) Gfx
--- @field new fun(Screen, ...): Gfx
--- @field close fun(Gfx)
--- @field type string

--- @class (exact) NullGfx: Gfx
--- @field type string
local NullGfx = {
  type = "null",
}

function NullGfx:close()
  -- No-op.
end

--- @class (exact) Screen
--- @field doom Doom
--- @field title string?
--- @field res_x integer
--- @field res_y integer
--- @field visible boolean?
--- @field tmux_passthrough boolean
--- @field gfx Gfx
--- @field closed boolean?
---
--- @field buf integer?
--- @field win integer?
--- @field term_chan integer?
--- @field term_width integer?
--- @field term_height integer?
---
--- @field new function
local Screen = {}

--- @param doom Doom
--- @param res_x integer
--- @param res_y integer
--- @return Screen
--- @nodiscard
function Screen.new(doom, res_x, res_y)
  local screen = setmetatable({
    doom = doom,
    res_x = res_x,
    res_y = res_y,
    gfx = NullGfx,
  }, { __index = Screen })

  if doom.play_opts.tmux_passthrough == nil and os.getenv "TMUX" then
    doom.console:plugin_print("$TMUX set, enabling tmux passthrough\n", "Debug")
    screen:enable_tmux_passthrough(true)
  else
    screen:enable_tmux_passthrough(doom.play_opts.tmux_passthrough)
  end

  vim.schedule(function()
    -- It's possible we were closed beforehand if this operation was scheduled.
    if screen.closed or doom.closed then
      return
    end

    screen.buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(
      screen.buf,
      ("actually-doom://screen//%d"):format(doom.process.pid)
    )
    M.screen_buf_to_doom[screen.buf] = doom

    screen.term_chan = api.nvim_open_term(screen.buf, {
      on_input = doom:close_on_err_wrap(function(_, _, _, data)
        local lines, columns = data:match "^\27%[(%d+);(%d+)R$"
        if lines then
          -- Cursor position report (DSR-CPR) requested by
          -- screen:update_term_size to get the current size of the terminal.
          --- @cast lines string
          --- @cast columns string
          screen.term_width = tonumber(columns)
          screen.term_height = tonumber(lines)
        end
      end),
      force_crlf = false,
    })
    -- Hide the cursor, disable line wrapping.
    api.nvim_chan_send(screen.term_chan, "\27[?25l\27[?7l")
    -- Disable the scrollback buffer as much as we can.
    api.nvim_set_option_value("scrollback", 1, { buf = screen.buf })

    screen:goto_win()
  end)

  return screen
end

function Screen:close()
  self.closed = true
  self.gfx:close()

  if self.buf then
    M.screen_buf_to_doom[self.buf] = nil
    vim.schedule(function()
      if api.nvim_buf_is_valid(self.buf) then
        api.nvim_buf_delete(self.buf, { force = true })
      end
    end)
  end
end

--- @param on boolean
function Screen:enable_tmux_passthrough(on)
  self.doom.console:plugin_print(
    ("tmux passthrough %s\n"):format(on and "ON" or "OFF")
  )
  self.tmux_passthrough = on
end

--- @param gfx Gfx
function Screen:set_gfx(gfx, ...)
  self.gfx:close()
  self.gfx = gfx.new(self, ...)
end

--- @return CellGfx?
--- @nodiscard
function Screen:cell_gfx()
  return self.gfx.type == "cell" and self.gfx --[[@as CellGfx]]
    or nil
end

--- @return KittyGfx?
--- @nodiscard
function Screen:kitty_gfx()
  return self.gfx.type == "kitty" and self.gfx --[[@as KittyGfx]]
    or nil
end

function Screen:goto_win()
  if self.closed or self.doom.closed then
    return
  end
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_set_current_win(self.win)
    api.nvim_command "startinsert"
    return
  end

  -- Create a new window.
  local win_config = new_screen_win_config()
  self.win = api.nvim_open_win(self.buf, true, win_config)

  api.nvim_set_option_value("winfixbuf", true, { win = self.win })
  api.nvim_set_option_value("wrap", false, { win = self.win })

  self:update_title()
  api.nvim_command "startinsert"
end

--- @param seq string
--- @return string
--- @nodiscard
function Screen:passthrough_escape(seq)
  if self.tmux_passthrough then
    -- Escape embedded ESCs by doubling them.
    return ("\27Ptmux;%s\27\\"):format(seq:gsub("\27", "\27\27"))
  end
  return seq
end

function Screen:update_term_size()
  if self.closed then
    return
  end

  -- Get its size by moving the cursor to the bottom-right and then query its
  -- position (DSR).
  api.nvim_chan_send(self.term_chan, "\27[99999;99999H\27[6n")

  -- Sizes should be set immediately from the on_input callback originally
  -- passed to nvim_open_term.
  assert(self.term_width)
  assert(self.term_height)
end

function Screen:update_title()
  if not self.win then
    return
  end

  local title = self.title or "DOOM"
  if api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_set_var(self.buf, "term_title", title)
  end
  if api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, {
      title = { { " " }, { title }, { " " } },
      title_pos = "center",
    })
  end
end

M.Console = Console
M.Screen = Screen
return M
