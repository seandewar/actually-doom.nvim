local api = vim.api
local fn = vim.fn

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

local M = {}

local ns = api.nvim_create_namespace "actually-doom"
local augroup = api.nvim_create_augroup("actually-doom", {})

--- @type table<integer, Doom>
local screen_buf_to_doom = {}

do
  local ctrl_bs = vim.keycode "<C-Bslash>"
  local ctrl_n = vim.keycode "<C-N>"
  local ctrl_o = vim.keycode "<C-O>"

  vim.on_key(function(key, _)
    if api.nvim_get_mode().mode ~= "t" then
      return
    end
    local doom = screen_buf_to_doom[api.nvim_get_current_buf()]
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

--- @class HlExtmark
--- @field id integer
--- @field hl string
--- @field start_row integer 0-indexed.
--- @field start_col integer 0-indexed.

--- @class Console
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
  local console = {
    last_row = 0,
    last_col = 0,
    buf = api.nvim_create_buf(true, true),
  }
  api.nvim_set_option_value("modifiable", false, { buf = console.buf })

  if doom then
    console.close_autocmd = api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      callback = vim.schedule_wrap(function(args)
        if args.buf == doom.console.buf or args.buf == doom.screen.buf then
          doom.console:plugin_print "Game buffer was unloaded; quitting\n"
          doom:close()
          return true -- Delete this autocmd (close should've done that anyway)
        end
      end),
    })
  end

  local save_curwin = api.nvim_get_current_win()
  api.nvim_command(("keepjumps tab %d sbuffer"):format(console.buf))
  if api.nvim_win_is_valid(save_curwin) then
    -- We'll choose when to enter the new tabpage.
    api.nvim_set_current_win(save_curwin)
  end

  return setmetatable(console, { __index = Console })
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

--- @param name string
function Console:set_buf_name(name)
  if vim.in_fast_event() then
    vim.schedule(function()
      self:set_buf_name(name)
    end)
    return
  end

  if api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_set_name(self.buf, name)
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
    screen_buf_to_doom[screen.buf] = doom

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

    local screen_width = api.nvim_get_option_value("columns", {})
    local screen_height = api.nvim_get_option_value("lines", {})
      - api.nvim_get_option_value("cmdheight", {})

    -- Minus 2 for the borders.
    screen.width = math.max(1, math.floor(screen_width - 2))
    screen.height = math.max(1, math.floor(screen_height - 2))
    -- Disable the scrollback buffer as much as we can.
    api.nvim_set_option_value("scrollback", 1, { buf = screen.buf })

    screen.win = api.nvim_open_win(screen.buf, true, {
      relative = "editor",
      width = screen.width,
      height = screen.height,
      -- Minus 2 for the borders.
      col = math.max(0, math.floor((screen_width - screen.width - 2) * 0.5)),
      row = math.max(0, math.floor((screen_height - screen.height - 2) * 0.5)),
      style = "minimal",
      border = "rounded",
    })
    api.nvim_set_option_value("winfixbuf", true, { win = screen.win })
    api.nvim_set_option_value("wrap", false, { win = screen.win })
    api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      once = true,
      pattern = tostring(screen.win),
      -- Window may have been closed *because* the buffer was unloaded, so we
      -- don't want to print the hint in that case. As the unload may be
      -- scheduled, schedule this twice so the unload happens before.
      callback = vim.schedule_wrap(vim.schedule_wrap(function(_)
        if not doom.closed then
          -- Pretty clear it's from this plugin, so don't bother with the
          -- "[actually-doom.nvim]" prefix; helps avoid hit-ENTER anyway.
          print(
            (
              'DOOM is still running! Use ":tab %dsb" and type "i" to resume, '
              .. 'or ":%dbd!" to quit'
            ):format(screen.buf, screen.buf)
          )
        end
      end)),
    })

    screen:update_title()
    screen:redraw()
    api.nvim_command "startinsert"
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
    screen_buf_to_doom[self.buf] = nil
    if api.nvim_buf_is_valid(self.buf) then
      api.nvim_buf_delete(self.buf, { force = true })
    end
  end
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
    if not self.term_chan then
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
    if fn.bufwinnr(self.buf) == -1 then
      -- TODO: even better if we don't request frames at all in this case
      return -- Buffer not shown in this tabpage.
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
