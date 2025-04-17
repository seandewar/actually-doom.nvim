local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

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

--- @alias StrBuf string.buffer
local StrBuf = require "string.buffer"

local M = {}

--- Supported message protocol version for communications with the DOOM process.
--- Bump this after a breaking protocol change.
local supported_proto_version = 0

local script_dir = (function()
  return fn.fnamemodify(debug.getinfo(2, "S").source:sub(2), ":h:p")
end)()

local ns = api.nvim_create_namespace "actually-doom"
local augroup = api.nvim_create_augroup("actually-doom", {})

--- @type table<integer, Doom>
local screen_buf_to_doom = {}

local doomkey_use = 162 -- KEY_USE
local doomkey_fire = 163 -- KEY_FIRE
local doomkey_leftarrow = 172 -- KEY_LEFTARROW
local doomkey_uparrow = 173 -- KEY_UPARROW
local doomkey_rightarrow = 174 -- KEY_RIGHTARROW
local doomkey_downarrow = 175 -- KEY_DOWNARROW
local doomkey_rshift = 182 -- KEY_RSHIFT
local doomkey_ralt = 184 -- KEY_RALT

do
  local special_to_doomkey = {
    [vim.keycode "<BS>"] = 127, -- KEY_BACKSPACE
    [vim.keycode "<Space>"] = doomkey_use,
    -- TODO: though it can be specified, RMB isn't great as it leaves Terminal
    -- mode; and <2-RightMouse> (double-clicking to use, like Vanilla) can't
    -- work for a similar reason.
    [vim.keycode "<RightMouse>"] = doomkey_use,
    [vim.keycode "<Left>"] = doomkey_leftarrow,
    [vim.keycode "<Up>"] = doomkey_uparrow,
    [vim.keycode "<Right>"] = doomkey_rightarrow,
    [vim.keycode "<Down>"] = doomkey_downarrow,
    [vim.keycode "<F1>"] = 187, -- KEY_F1
    [vim.keycode "<F2>"] = 188, -- KEY_F2
    [vim.keycode "<F3>"] = 189, -- KEY_F3
    [vim.keycode "<F4>"] = 190, -- KEY_F4
    [vim.keycode "<F5>"] = 191, -- KEY_F5
    [vim.keycode "<F6>"] = 192, -- KEY_F6
    [vim.keycode "<F7>"] = 193, -- KEY_F7
    [vim.keycode "<F8>"] = 194, -- KEY_F8
    [vim.keycode "<F9>"] = 195, -- KEY_F9
    [vim.keycode "<F10>"] = 196, -- KEY_F10
    [vim.keycode "<F11>"] = 215, -- KEY_F11
    [vim.keycode "<F12>"] = 216, -- KEY_F12
    [vim.keycode "<Home>"] = 199, -- KEY_HOME
    [vim.keycode "<End>"] = 207, -- KEY_END
    [vim.keycode "<PageUp>"] = 201, -- KEY_PGUP
    [vim.keycode "<PageDown>"] = 209, -- KEY_PGDN
    [vim.keycode "<Insert>"] = 210, -- KEY_INS
    [vim.keycode "<Del>"] = 211, -- KEY_DEL
  }

  --- @param key integer
  --- @return boolean
  --- @nodiscard
  local function printable(key)
    return key >= 33 and key <= 126
  end

  --- @param key integer
  --- @return integer, boolean
  --- @nodiscard
  local function lower(key)
    if key >= 65 and key <= 90 then -- A-Z
      return key - 65 + 97, true -- Make it lowercase: k - 'A' + 'a'.
    end
    return key, false
  end

  local left_mouse = vim.keycode "<LeftMouse>"
  local left_release = vim.keycode "<LeftRelease>"

  local function handle_key(doom, key)
    -- Special cases: unlike other terminal "keys", mouse clicks report
    -- push/release events, so we can use their state exactly.
    if key == left_mouse or key == left_release then
      doom:press_key(nil)
      doom:send_key(doomkey_fire, key == left_mouse)
      doom:schedule_check()
      return "" -- Consume the clicks.
    end

    -- I don't think CTRL is used in combination with other keys in Vanilla DOOM
    -- (it was just used for firing), so not bothering to consider it.
    local shift = false
    local alt = false
    local doomkey
    -- Until https://github.com/neovim/neovim/issues/26575 is implemented, we
    -- need to parse keycodes ourselves.
    if #key == 1 and printable(key:byte()) then
      doomkey, shift = lower(key:byte())
    else
      -- Easiest to parse these using the printable representation via keytrans;
      -- it should return modifiers in uppercase, with "M" being used for Alt
      -- (not "A", though both are supported by Nvim).
      local keycode = fn.keytrans(key)
      shift = keycode:find "S%-" ~= nil
      alt = keycode:find "M%-" ~= nil
      key = keycode:match ".*[-<](.+)>" or keycode
      if #key == 1 and printable(key:byte()) then
        doomkey, _ = lower(key:byte()) -- Shift was set from keycode modifiers.
      else
        key = vim.keycode(("<%s>"):format(key))
        doomkey = special_to_doomkey[key]
        if not doomkey and #key == 1 then
          doomkey = key:byte()
        end
      end
    end
    if not doomkey then
      return
    elseif doomkey == 120 then -- x
      -- Can't use the typical Vanilla DOOM CTRL key to fire (as it's only
      -- available as a modifier to other keys), so use X.
      -- TODO: consider doing this by setting the config variable for firing,
      -- though we'll want to move LMB handling to use a mouse click rather than
      -- sending the fire key to avoid breaking it.
      doomkey = doomkey_fire
    end

    if
      doom.pressed_key
      and doomkey >= doomkey_leftarrow
      and doom.pressed_key.shift == shift
      and doom.pressed_key.alt == alt
    then
      -- If the arrow key in the opposite direction was active, just cancel it.
      -- This allows for more precise movement in the terminal.
      local opposite_arrow_doomkey = (doomkey - doomkey_leftarrow + 2) % 4
        + doomkey_leftarrow
      if doom.pressed_key.key == opposite_arrow_doomkey then
        doom:press_key(nil)
        doom:schedule_check()
        return "" -- Nom.
      end
    end

    doom:press_key {
      key = doomkey,
      shift = shift,
      alt = alt,
      release_time = uv.now() + 375,
    }
    doom:schedule_check()
    return "" -- We handled the key, so eat it (yum!)
  end

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
    local ok, rv = pcall(doom.close_on_err, doom, handle_key, doom, key)
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
local Console = {}

--- @return Console
--- @nodiscard
function Console.new()
  local buf = api.nvim_create_buf(true, true)
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  local save_curwin = api.nvim_get_current_win()
  api.nvim_command(("tab %d sbuffer"):format(buf))
  if api.nvim_win_is_valid(save_curwin) then
    -- We'll choose when to enter the new tabpage.
    api.nvim_set_current_win(save_curwin)
  end

  return setmetatable({
    buf = buf,
    last_row = 0,
    last_col = 0,
  }, { __index = Console })
end

function Console:close()
  if vim.in_fast_event() then
    vim.schedule(function()
      self:close()
    end)
    return
  end

  if api.nvim_buf_is_valid(self.buf) then
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
      callback = function(_)
        -- Pretty clear it's from this plugin, so don't bother with the
        -- "[actually-doom.nvim]" prefix; helps avoid hit-ENTER prompts anyway.
        print(
          (
            'DOOM is still running! Use ":tab %dsb" and type "i" to resume, '
            .. 'or ":%dbd!" to quit'
          ):format(screen.buf, screen.buf)
        )
      end,
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

  local buf = StrBuf.new() -- Reuse the allocation if possible.

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

--- @class PressedKey
--- @field key integer
--- @field shift boolean
--- @field alt boolean
--- @field release_time integer

--- @class Doom
--- @field console Console
--- @field process vim.SystemObj
--- @field sock uv.uv_pipe_t
--- @field send_buf StrBuf
--- @field check_timer uv.uv_timer_t
--- @field pressed_key PressedKey?
--- @field screen Screen?
--- @field close_autocmd integer
--- @field closed boolean?
local Doom = {}

function Doom:send_frame_request()
  -- CMSG_WANT_FRAME (no payload)
  self.send_buf:put "\0"
end

--- Schedules a check to happen in approximately `ms` milliseconds from now.
--- If a check is already scheduled, reschedule it if `ms` is sooner.
--- @param ms integer? If nil, schedule for the next event loop iteration.
function Doom:schedule_check(ms)
  local function check_cb()
    local next_sched_time = math.huge
    local now = uv.now()

    if self.pressed_key then
      if now >= self.pressed_key.release_time then
        self:press_key(nil)
      else
        next_sched_time =
          math.min(next_sched_time, self.pressed_key.release_time)
      end
    end

    self:flush_send()
    if next_sched_time < math.huge then
      -- As some time may have passed, use the updated now time.
      self:schedule_check(next_sched_time - uv.now())
    end
  end

  ms = ms and math.max(0, ms) or 0
  local due_in = self.check_timer:get_due_in()
  if due_in == 0 or due_in > ms then
    assert(self.check_timer:start(ms, 0, self:close_on_err_wrap(check_cb)))
  end
end

--- @param doomkey integer
--- @param pressed boolean
function Doom:send_key(doomkey, pressed)
  -- CMSG_PRESS_KEY
  self.send_buf:put("\1", string.char(doomkey), pressed and "\1" or "\0")
end

--- @param info PressedKey?
function Doom:press_key(info)
  if self.pressed_key then
    if not info or self.pressed_key.key ~= info.key then
      self:send_key(self.pressed_key.key, false)
    end
    if not info or self.pressed_key.shift ~= info.shift then
      self:send_key(doomkey_rshift, false)
    end
    if not info or self.pressed_key.alt ~= info.alt then
      self:send_key(doomkey_ralt, false)
    end
    self.pressed_key = nil
  end

  if info then
    self:send_key(info.key, true)
    if info.shift then
      self:send_key(doomkey_rshift, true)
    end
    if info.alt then
      self:send_key(doomkey_ralt, true)
    end
    self.pressed_key = info
  end
end

function Doom:flush_send()
  if #self.send_buf == 0 then
    return
  end

  local data = self.send_buf:get()
  --- @param err string?
  local function handle_err(err)
    if err then
      self.console:plugin_print(
        ("Failed to send %d byte(s); quitting: %s\n"):format(#data, err),
        "ErrorMsg"
      )
      self:close()
    end
  end
  local _, err = self.sock:write(data, handle_err)
  handle_err(err)
end

--- @param doom Doom
--- @param sock_path string
local function init_process(doom, sock_path)
  --- @param msg_hl string?
  --- @return fun(err: nil|string, data: string|nil)
  --- @nodiscard
  local function new_out_cb(msg_hl)
    return function(err, data)
      if err then
        doom.console:plugin_print(
          ("Stream error: %s\n"):format(err),
          "ErrorMsg"
        )
      elseif data then
        doom.console:print(data, msg_hl)
      end
    end
  end

  --- @param out vim.SystemCompleted
  local exit_cb = function(out)
    doom.console:print "\n"
    doom.console:plugin_print(
      ("DOOM (PID %d) exited with code %d\n"):format(doom.process.pid, out.code),
      out.code ~= 0 and "ErrorMsg" or nil
    )
    doom:close()
  end

  local sys_ok, sys_rv = pcall(vim.system, {
    fs.joinpath(script_dir, "../../doom/build/actually_doom"),
    "-listen",
    sock_path,
    "-iwad",
    fs.joinpath(script_dir, "../../doom/DOOM1.WAD"),
  }, {
    stdout = new_out_cb(),
    stderr = new_out_cb "WarningMsg",
  }, exit_cb)

  if not sys_ok then
    error(("[actually-doom.nvim] Failed to run DOOM: %s"):format(sys_rv), 0)
  end
  doom.process = sys_rv

  doom.console:plugin_print(
    ("DOOM started as PID %d\n"):format(sys_rv.pid)
      .. "To forcefully quit DOOM, unload the console or screen buffer "
      .. '(e.g: ":bunload!", ":bdelete!", ":bwipeout!")\n\n'
  )
end

--- @param doom Doom
--- @param buf StrBuf
local function recv_msg_loop(doom, buf)
  --- @param n integer (0 gives an empty string)
  --- @return string
  local function read_bytes(n)
    while n > #buf do
      coroutine.yield()
    end
    return buf:get(n)
  end

  --- @return integer
  local function read8()
    return read_bytes(1):byte()
  end
  --- @return integer
  local function read16()
    local a, b = read_bytes(2):byte(1, 2)
    return a + (b * 256)
  end
  --- @return integer
  local function read32()
    local a, b, c, d = read_bytes(4):byte(1, 4)
    return a + (b * 256) + (c * 65536) + (d * 16777216)
  end
  --- @return string
  local function read_string()
    return read_bytes(read16())
  end

  local proto_version = read32()
  local resx = read16()
  local resy = read16()
  doom.console:plugin_print(
    ("AMSG_INIT: proto_version=%d resx=%d resy=%d\n"):format(
      proto_version,
      resx,
      resy
    ),
    "Comment"
  )

  if proto_version ~= supported_proto_version then
    doom.console:plugin_print(
      (
        "DOOM process reports incompatible message protocol version %d "
        .. "(expected %d); please rebuild the DOOM executable. Quitting\n"
      ):format(proto_version, supported_proto_version),
      "ErrorMsg"
    )
    doom:close()
    return
  end

  doom.screen = Screen.new(doom, resx, resy)
  doom:send_frame_request()
  doom:schedule_check()

  --- @type table<integer, fun(): boolean?>
  local msg_handlers = {
    -- AMSG_FRAME
    [0] = function()
      local len = doom.screen:pixel_index(0, doom.screen.resy)
      doom.screen.pixels = read_bytes(len)
      doom.screen:redraw()
      doom:send_frame_request()
      doom:schedule_check()
    end,

    -- AMSG_SET_TITLE
    [1] = function()
      doom.screen.title = read_string()
      doom.console:plugin_print(
        ('AMSG_SET_TITLE: title="%s"\n'):format(doom.screen.title),
        "Comment"
      )
      doom.screen:update_title()
    end,

    -- AMSG_QUIT
    [2] = function()
      doom.console:plugin_print "DOOM process disconnected; quitting\n"
      doom:close()
      return true -- Quit receive loop.
    end,
  }

  while true do
    local msg_type = read8()
    local handler = msg_handlers[msg_type]
    if handler then
      if handler() then
        return -- Handlers can return truthy to quit the loop.
      end
    else
      doom.console:plugin_print(
        ("Received unknown message type: %d; quitting\n"):format(msg_type),
        "ErrorMsg"
      )
      doom:close()
      return
    end
  end
end

--- @param doom Doom
--- @param sock_path string
local function init_connection(doom, sock_path)
  doom.sock = assert(uv.new_pipe())
  local tries_left = 20
  local schedule_connect -- Late assignment so connect_cb can call it.

  --- @param conn_err nil|string
  local function connect_cb(conn_err)
    if conn_err then
      tries_left = tries_left - 1
      doom.console:plugin_print(
        (
          "Failed to connect to the DOOM process: %s "
          .. "(%d attempt(s) left)\n"
        ):format(conn_err, tries_left),
        "WarningMsg"
      )
      if tries_left <= 0 then
        doom.console:plugin_print(
          "No connection attempts remaining; giving up\n",
          "ErrorMsg"
        )
        doom:close()
        return
      end

      schedule_connect(1000)
      return
    end

    doom.console:plugin_print "Connected to the DOOM process\n"
    local recv_buf = StrBuf.new(256)
    local recv_co = coroutine.create(recv_msg_loop)
    -- Pass the initial arguments.
    assert(coroutine.resume(recv_co, doom, recv_buf))

    --- @param read_err nil|string
    --- @param data string|nil
    assert(doom.sock:read_start(doom:close_on_err_wrap(function(read_err, data)
      if read_err then
        doom.console:plugin_print(
          ("Read error; quitting: %s\n"):format(read_err),
          "ErrorMsg"
        )
        doom:close()
        return
      elseif not data then
        return -- No error, but reached EOF.
      end

      recv_buf:put(data)
      assert(coroutine.resume(recv_co))
    end)))
  end

  --- @param ms integer
  schedule_connect = function(ms)
    -- Forward the libuv errors from trying to schedule the operations so that
    -- they count as a failed connection attempt.
    local _, err = doom.check_timer:start(ms, 0, function()
      local _, err =
        doom.sock:connect(sock_path, doom:close_on_err_wrap(connect_cb))
      if err then
        connect_cb(err) -- Forward the error.
      end
    end)

    if err then
      connect_cb(err) -- Forward the error.
    end
  end

  schedule_connect(500)
end

--- @return Doom
function Doom.run()
  local doom = setmetatable({
    check_timer = assert(uv.new_timer()),
    send_buf = StrBuf.new(256),
    console = Console.new(),
  }, { __index = Doom })

  local sock_path = ("/run/user/%d/actually-doom.%d.%d"):format(
    uv.getuid(),
    uv.os_getpid(),
    uv.hrtime()
  )
  local ok, rv = pcall(init_process, doom, sock_path)
  if not ok then
    -- Error starting DOOM. Not using close_on_err here, as we don't want a
    -- verbose emsg, and we close the console as we don't expect much there yet.
    doom:close(true)
    error(rv, 0)
  end

  doom:close_on_err(function()
    doom.close_autocmd = api.nvim_create_autocmd("BufUnload", {
      group = augroup,
      callback = vim.schedule_wrap(function(args)
        if args.buf == doom.console.buf or args.buf == doom.screen.buf then
          doom.console:plugin_print "Game buffer was unloaded; quitting\n"
          doom:close()
          return true -- Delete this autocmd (close should've done that anyway)
        end
      end),
    })

    doom.console:set_buf_name(
      ("actually-doom://console//%d"):format(doom.process.pid)
    )
    local console_wins = fn.win_findbuf(doom.console.buf)
    if #console_wins > 0 then
      api.nvim_set_current_win(console_wins[1])
    end

    init_connection(doom, sock_path)
  end)

  return doom
end

--- @param close_console boolean?
function Doom:close(close_console)
  if self.closed then
    return
  end
  self.closed = true

  -- Non-nil fields may be nil if we're called during initialization.
  if self.check_timer then
    self.check_timer:stop()
    self.check_timer:close()
  end
  if self.sock then
    self.sock:close() -- Also closes pending requests and such.
  end
  if self.process then
    self.process:kill "sigterm" -- Try a clean shutdown.
  end
  if self.close_autocmd then
    if vim.in_fast_event() then
      vim.schedule(function()
        api.nvim_del_autocmd(self.close_autocmd)
      end)
    else
      api.nvim_del_autocmd(self.close_autocmd)
    end
  end
  if self.screen then
    self.screen:close()
  end
  if close_console and self.console then
    self.console:close()
  end
end

--- Call `f`, but print to the console and call [`Doom.close`](lua://Doom.close)
--- upon an unhandled error and re-throw it.
---
--- This should only be used when errors are unexpected, like logic errors.
--- Errors communicating with the DOOM process should not throw errors that are
--- handled by this.
---
--- @param f function
--- @param ... any arguments to pass to `f`
--- @return any ...
function Doom:close_on_err(f, ...)
  --- Allows us to return multiple values from `f`.
  --- @return integer, table
  --- @nodiscard
  local function pack(...)
    return select("#", ...), { ... }
  end

  local args = { ... }
  local nargs = select("#", ...) -- Can't use #args; args may have nils.
  local ok, nrvs_or_err, rvs = xpcall(function()
    return pack(f(unpack(args, 1, nargs)))
  end, debug.traceback)

  if not ok then
    -- In case we're textlocked.
    -- TODO: honestly, textlock restrictions can screw us in other places; in
    -- general I don't feel great about the error handling in this plugin,
    -- probably best to simplify it all somehow.
    vim.schedule(function()
      self.console:plugin_print(
        ("Quitting after unexpected error: %s\n"):format(nrvs_or_err),
        "ErrorMsg"
      )
      self:close()
    end)
    error(nrvs_or_err, 0) -- The double traceback is unfortunate.
  end
  return unpack(rvs, 1, nrvs_or_err)
end

--- @see Doom.close_on_err
--- @param f function
--- @return function
--- @nodiscard
function Doom:close_on_err_wrap(f)
  return function(...)
    return self:close_on_err(f, ...)
  end
end

--- @return Doom?
function M.play()
  local ok, rv = pcall(Doom.run)
  if not ok then
    api.nvim_echo({ { rv } }, true, { err = true })
    return nil
  end
  return rv
end

return M
