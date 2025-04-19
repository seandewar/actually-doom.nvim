local api = vim.api
local fn = vim.fn
local log = vim.log

local ffi
do
  local ok, rv = pcall(require, "ffi")
  if ok then
    ffi = rv
    ffi.cdef [[
      void clear_hl_tables(bool reinit);
    ]]
  end
end

local M = {
  --- @type table<integer, Doom>
  screen_buf_to_doom = {},
}

local ns = api.nvim_create_namespace "actually-doom"
local augroup = api.nvim_create_augroup("actually-doom", {})

do
  local ctrl_bs = vim.keycode "<C-Bslash>"
  local ctrl_n = vim.keycode "<C-N>"
  local ctrl_o = vim.keycode "<C-O>"

  vim.on_key(function(key, _)
    if api.nvim_get_mode().mode ~= "t" then
      return
    end
    local doom = M.screen_buf_to_doom[api.nvim_get_current_buf()]
    if not doom or doom.closed then
      return
    end
    -- Keys modifiers may not be simplified in Terminal mode (e.g: ^\ received
    -- as K_SPECIAL ... KS_MODIFIER MOD_MASK_CTRL \) as a consequence of
    -- implementing kitty keyboard protocol support; simplify them.
    key = vim.keycode(fn.keytrans(key))
    if key == ctrl_bs or key == ctrl_n or key == ctrl_o then
      return -- May be used to leave Terminal mode; don't intercept.
    end

    -- Bubbling up the error will cause on_key to unregister our callback, which
    -- is bad as we only register it once, so don't do that.
    local ok, rv = pcall(
      doom.close_on_err,
      doom,
      require("actually-doom").Doom.press_vim_key,
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
          doom.console:plugin_print("Game visible; redraws ON\n", "Comment")
          doom:send_frame_request()
          doom:schedule_check()
          doom.screen:redraw()
        elseif old_visible and not doom.screen.visible then
          doom.console:plugin_print("Game hidden; redraws OFF\n", "Comment")
        end
      end
    end
  end,
  desc = "[actually-doom.nvim] Pause redraws when screen is not visible",
})

api.nvim_create_autocmd("WinLeave", {
  group = augroup,
  nested = true,
  callback = function(_)
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
  callback = function(_)
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

--- @class HlExtmark
--- @field id integer
--- @field hl string
--- @field start_row integer 0-indexed.
--- @field start_col integer 0-indexed.

--- @class Console
--- @field doom Doom?
--- @field buf integer
--- @field last_row integer 0-indexed.
--- @field last_col integer 0-indexed.
--- @field last_extmark HlExtmark?
--- @field close_autocmd integer?
local Console = {}

--- @param doom Doom?
--- @return Console
--- @nodiscard
function Console.new(doom)
  local console = setmetatable({
    doom = doom,
    last_row = 0,
    last_col = 0,
    buf = api.nvim_create_buf(true, true),
  }, { __index = Console })
  console:update_buf_name()
  api.nvim_set_option_value("modifiable", false, { buf = console.buf })

  if doom then
    -- Not a global autocmd as we may not have a screen yet when it's called.
    console.close_autocmd = api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      nested = true,
      callback = vim.schedule_wrap(function(args)
        if args.buf == doom.console.buf or args.buf == doom.screen.buf then
          doom.console:plugin_print "Game buffer was unloaded; quitting\n"
          doom:close()
          return true -- Delete this autocmd (close should've done that anyway)
        end
      end),
      desc = "[actually-doom.nvim] Quit game when buffers are unloaded",
    })
  end

  local save_curwin = api.nvim_get_current_win()
  api.nvim_command(("keepjumps tab %d sbuffer"):format(console.buf))
  if api.nvim_win_is_valid(save_curwin) then
    -- We'll choose when to enter the new tabpage.
    api.nvim_set_current_win(save_curwin)
  end
  return console
end

--- @param close_win boolean?
function Console:close(close_win)
  if vim.in_fast_event() then
    vim.schedule(function()
      self:close()
    end)
    return
  end

  if self.close_autocmd then
    api.nvim_del_autocmd(self.close_autocmd)
  end
  if close_win and api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_delete(self.buf, { force = true })
  end
end

function Console:update_buf_name()
  if vim.in_fast_event() then
    vim.schedule(function()
      self:update_buf_name()
    end)
    return
  end

  if api.nvim_buf_is_valid(self.buf) then
    local old_name = api.nvim_buf_get_name(self.buf)
    local new_name = ("actually-doom://console//%d"):format(self.buf)
    if self.doom and self.doom.process then
      new_name = ("%s:%d"):format(new_name, self.doom.process.pid)
    end

    if new_name ~= old_name then
      api.nvim_buf_set_name(self.buf, new_name)
      if old_name ~= "" then
        -- Wipeout the (alternate) buffer that now holds the old name.
        local old_name_buf = fn.bufnr(("^%s$"):format(fn.fnameescape(old_name)))
        if old_name_buf ~= -1 then
          api.nvim_buf_delete(old_name_buf, { force = true })
        end
      end
    end
  end
end

--- @param text string
--- @param hl string?
function Console:print(text, hl)
  if text == "" then
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      self:print(text, hl)
    end)
    return
  end
  if not api.nvim_buf_is_valid(self.buf) then
    return
  end

  -- Avoid side-effects, particularly from OptionSet.
  vim._with({ noautocmd = true }, function()
    api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  end)

  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_text(self.buf, -1, -1, -1, -1, lines)

  -- Faster than using the API, line() or col().
  local prev_last_row = self.last_row
  local prev_last_col = self.last_col
  if #lines == 1 then
    self.last_col = self.last_col + #lines[1]
  elseif #lines > 1 then
    self.last_row = self.last_row + (#lines - 1)
    self.last_col = #lines[#lines]
  end

  if self.last_extmark and self.last_extmark.hl == hl then
    -- Same highlight as the last extmark; extend its range.
    api.nvim_buf_set_extmark(
      self.buf,
      ns,
      self.last_extmark.start_row,
      self.last_extmark.start_col,
      {
        id = self.last_extmark.id,
        hl_group = hl,
        end_row = self.last_row,
        end_col = self.last_col,
      }
    )
  elseif hl then
    -- Last extmark has a different highlight or doesn't exist; can't reuse it.
    local id =
      api.nvim_buf_set_extmark(self.buf, ns, prev_last_row, prev_last_col, {
        hl_group = hl,
        end_row = self.last_row,
        end_col = self.last_col,
      })

    self.last_extmark = {
      id = id,
      hl = hl,
      start_row = prev_last_row,
      start_col = prev_last_col,
    }
  else
    -- No extmark required if not highlighting.
    self.last_extmark = nil
  end

  vim._with({ noautocmd = true }, function()
    api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  end)

  -- Tail console windows on the last line to the output.
  for _, win in ipairs(fn.win_findbuf(self.buf)) do
    local row, col = unpack(api.nvim_win_get_cursor(win))
    if row == self.last_row + 1 then
      api.nvim_win_set_cursor(win, { self.last_row + 1, col })
    end
  end
end

--- @see Console.print
--- @param text string
--- @param hl string? If nil, defaults to "Special"
function Console:plugin_print(text, hl)
  return self:print("[actually-doom.nvim] " .. text, hl or "Special")
end

--- @class Screen
--- @field doom Doom
--- @field title string?
--- @field resx integer
--- @field resy integer
--- @field pixels string?
--- @field blend boolean?
--- @field redraw_scheduled boolean?
--- @field visible boolean?
---
--- @field closed boolean?
--- @field buf integer?
--- @field win integer?
--- @field term_chan integer?
--- @field width integer?
--- @field height integer?
local Screen = {}

--- @param doom Doom
--- @param resx integer
--- @param resy integer
--- @return Screen
--- @nodiscard
function Screen.new(doom, resx, resy)
  local screen = setmetatable({
    doom = doom,
    resx = resx,
    resy = resy,
    blend = true,
  }, { __index = Screen })

  local function create_ui()
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
          -- Cursor position report (DSR-CPR) requested by Screen.redraw to get
          -- the current size of the terminal.
          --- @cast lines string
          --- @cast columns string
          screen.width = tonumber(columns)
          screen.height = tonumber(lines)
        end
      end),
      force_crlf = false,
    })
    -- Hide the cursor, disable line wrapping.
    api.nvim_chan_send(screen.term_chan, "\27[?25l\27?7l")
    -- Disable the scrollback buffer as much as we can.
    api.nvim_set_option_value("scrollback", 1, { buf = screen.buf })

    screen:goto_win()
  end
  -- If in a fast context, we can't create the UI immediately.
  if vim.in_fast_event() then
    vim.schedule(doom:close_on_err_wrap(create_ui))
  else
    create_ui()
  end

  return screen
end

function Screen:close()
  self.closed = true
  if vim.in_fast_event() then
    vim.schedule(function()
      self:close()
    end)
    return
  end

  if self.buf then
    M.screen_buf_to_doom[self.buf] = nil
    if api.nvim_buf_is_valid(self.buf) then
      api.nvim_buf_delete(self.buf, { force = true })
    end
  end
end

function Screen:goto_win()
  if self.closed or self.doom.closed then
    return
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      self:goto_win()
    end)
    return
  end
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_set_current_win(self.win)
    api.nvim_command "startinsert"
    return
  end

  -- Create a new window.
  local win_config = new_screen_win_config()
  self.width = win_config.width
  self.height = win_config.height
  self.win = api.nvim_open_win(self.buf, true, win_config)

  api.nvim_set_option_value("winfixbuf", true, { win = self.win })
  api.nvim_set_option_value("wrap", false, { win = self.win })

  self:update_title()
  api.nvim_command "startinsert"
end

do
  -- From https://gist.github.com/MicahElliott/719710?permalink_comment_id=1442838#gistcomment-1442838
  -- Keep this sorted.
  local cube_levels = { 0, 95, 135, 175, 215, 255 }
  -- DOOM generally only uses a limited palette, so caching the result of
  -- rgb_to_xterm256 brings a performance uplift.
  local xterm_colour_cache = {}

  --- Convert RGB to the closest xterm-256 colour. Excludes the first 16 system
  --- colours. Not intended to be super accurate.
  --- @param r integer
  --- @param g integer
  --- @param b integer
  --- @return integer
  --- @nodiscard
  local function rgb_to_xterm256(r, g, b)
    local cache_key = b + (g * 256) + (r * 65536)
    if xterm_colour_cache[cache_key] then
      return xterm_colour_cache[cache_key]
    end

    --- @param x integer
    --- @return integer
    --- @nodiscard
    local function nearest_cube_idx(x)
      local min_diff = math.abs(x - cube_levels[1])
      for i = 2, #cube_levels do
        local diff = math.abs(x - cube_levels[i])
        if diff >= min_diff then
          -- Levels are sorted, so we can return as soon as the difference
          -- starts increasing again.
          return i - 1
        end
        min_diff = diff
      end
      return #cube_levels
    end

    --- @param r2 integer
    --- @param b2 integer
    --- @param g2 integer
    --- @return integer
    --- @nodiscard
    local function dist_sq(r2, g2, b2)
      return (r - r2) ^ 2 + (g - g2) ^ 2 + (b - b2) ^ 2
    end

    -- Cube colour.
    local ri = nearest_cube_idx(r)
    local gi = nearest_cube_idx(g)
    local bi = nearest_cube_idx(b)
    local cube_dist = dist_sq(cube_levels[ri], cube_levels[gi], cube_levels[bi])

    -- Grayscale (232–255): 24 shades from levels 8-238 (in increments of 10).
    local brightness = math.floor((r + g + b) / 3) -- Average brightness.
    local gray_i = math.floor((brightness - 8) / 10 + 0.5)
    gray_i = math.max(0, math.min(23, gray_i))
    -- Clamp to number of shades. (0-indexed)
    local gray_level = 8 + gray_i * 10
    local gray_dist = dist_sq(gray_level, gray_level, gray_level)

    local colour
    if gray_dist < cube_dist then
      colour = 232 + gray_i -- Gray is closer.
    else
      colour = 16 + 36 * (ri - 1) + 6 * (gi - 1) + (bi - 1) -- Cube is closer.
    end
    xterm_colour_cache[cache_key] = colour
    return colour
  end

  local buf = require("string.buffer").new() -- Reuse allocation if possible.

  function Screen:redraw()
    if not self.visible or not self.term_chan then
      return
    end
    if vim.in_fast_event() then
      if not self.redraw_scheduled then
        self.redraw_scheduled = true
        vim.schedule(function()
          self.redraw_scheduled = false
          self:redraw()
        end)
      end
      return
    end

    if self.pixels then
      local true_colour = api.nvim_get_option_value("termguicolors", {})
        or fn.has "gui_running" == 1

      --- @param x integer (0-indexed)
      --- @param y integer (0-indexed)
      --- @return integer, integer (0-indexed)
      --- @nodiscard
      local function pixel_topleft_pos(x, y)
        local pix_x =
          math.min(math.floor((x / self.width) * self.resx), self.resx)
        local pix_y =
          math.min(math.floor((y / self.height) * self.resy), self.resy)
        return pix_x, pix_y
      end

      -- Cursor to 0,0.
      buf:put "\27[H"

      for y = 0, self.height - 1 do -- 0-indexed
        for x = 0, self.width - 1 do -- 0-indexed
          -- Pixel positions are 0-indexed.
          local pix_x, pix_y = pixel_topleft_pos(x, y)
          local r, g, b
          if self.blend then
            -- Blend all pixels within this cell.
            local pix_x2, pix_y2 = pixel_topleft_pos(x + 1, y + 1)
            pix_x2 = math.min(self.resx - 1, pix_x2)
            pix_y2 = math.min(self.resy - 1, pix_y2)
            local pix_count = (pix_x2 + 1 - pix_x) * (pix_y2 + 1 - pix_y)
            r, g, b = 0, 0, 0
            for py = pix_y, pix_y2 do
              for px = pix_x, pix_x2 do
                local pi = self:pixel_index(px, py) + 1
                local pb, pg, pr = self.pixels:byte(pi, pi + 3)
                r = r + pr
                g = g + pg
                b = b + pb
              end
            end

            r = math.min(255, math.floor(r / pix_count + 0.5))
            g = math.min(255, math.floor(g / pix_count + 0.5))
            b = math.min(255, math.floor(b / pix_count + 0.5))
          else
            -- Just use the pixel at the top-left.
            local pix_i = self:pixel_index(pix_x, pix_y) + 1
            b, g, r = self.pixels:byte(pix_i, pix_i + 3)
          end

          if true_colour then
            -- Set background RGB "true" colour and write a space.
            buf:put("\27[48;2;", r, ";", g, ";", b, "m ")
          else
            -- Same as above, but using a near xterm-256 colour instead.
            buf:put("\27[48;5;", rgb_to_xterm256(r, g, b), "m ")
          end
        end

        if y + 1 < self.height then
          buf:put "\r\n"
        end
      end

      -- When using RGB, it's possible for Nvim to run out of free highlighting
      -- attribute entries, causing transparent cells to be drawn (showing the
      -- background colour of the Screen window) after Nvim clears and rebuilds
      -- the attribute tables. We can work around this by forcing a rebuild of
      -- the tables before we send the frame, but this requires LuaJIT.
      if true_colour and ffi then
        ffi.C.clear_hl_tables(true)
      end
    else
      -- Reset attributes, clear screen, clear scrollback.
      buf:put "\27[0m\27[2J\27[3J"
    end

    -- Get the size of the terminal by moving the cursor to the bottom-right and
    -- then querying its position (DSR). This is so we can detect resizes.
    buf:put "\27[99999;99999H\27[6n"

    api.nvim_chan_send(self.term_chan, buf:get())
  end
end

--- @param x integer (0-based)
--- @param y integer (0-based)
--- @return integer (0-based)
--- @nodiscard
function Screen:pixel_index(x, y)
  return (y * self.resx + x) * 3
end

function Screen:update_title()
  if vim.in_fast_event() or not self.win then
    vim.schedule(function()
      self:update_title()
    end)
    return
  end

  if api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, {
      title = {
        { " " },
        { self.title or "DOOM" },
        { " " },
      },
      title_pos = "center",
    })
  end
end

M.Console = Console
M.Screen = Screen
return M
