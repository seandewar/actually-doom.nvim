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

--- @param resx integer
--- @param resy integer
--- @param term_input_cb fun(_: string, term: integer, buf: integer, data: string)?
--- @param buf_name string?
--- @return Screen
function Screen.new(resx, resy, term_input_cb, buf_name)
  local screen = setmetatable({
    resx = resx,
    resy = resy,
    blend = true,
  }, { __index = Screen })

  local function create_ui()
    -- It's possible we were closed beforehand if this operation was scheduled.
    if screen.closed then
      return
    end

    screen.buf = api.nvim_create_buf(true, true)
    if buf_name then
      api.nvim_buf_set_name(screen.buf, buf_name)
    end
    screen.term_chan = api.nvim_open_term(screen.buf, {
      on_input = term_input_cb,
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

    screen:update_title()
    screen:redraw()
    api.nvim_command "startinsert"
  end
  -- If in a fast context, we can't create the UI immediately.
  if vim.in_fast_event() then
    vim.schedule(create_ui)
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

  if self.buf and api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_delete(self.buf, { force = true })
  end
end

--- @param x integer (0-based)
--- @param y integer (0-based)
--- @return integer (0-based)
function Screen:pixel_index(x, y)
  return (y * self.resx + x) * 3
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
  local function rgb_to_xterm256(r, g, b)
    local cache_key = b + (g * 256) + (r * 65536)
    if xterm_colour_cache[cache_key] then
      return xterm_colour_cache[cache_key]
    end

    --- @param x integer
    --- @return integer
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

--- @param pixels string?
function Screen:set_pixels(pixels)
  self.pixels = pixels
  self:redraw()
end

--- @param doom Doom?
function Screen:update_title(doom)
  if vim.in_fast_event() or not self.win then
    vim.schedule(function()
      self:update_title(doom)
    end)
    return
  end

  if api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, {
      title = {
        { " " },
        { doom and doom.title or "DOOM" },
        { " " },
        { doom and doom.shift_pressed and " Shift " or "", "CursorLine" },
        { doom and doom.alt_pressed and " Alt " or "", "CursorLine" },
      },
      title_pos = "center",
    })
  end
end

--- @class Doom
--- @field console Console
--- @field process vim.SystemObj
--- @field sock uv.uv_pipe_t
--- @field send_buf StrBuf
--- @field check_timer uv.uv_timer_t
--- @field title string?
--- @field pending_key_releases table<integer, integer>
--- @field shift_pressed boolean?
--- @field alt_pressed boolean?
--- @field screen Screen?
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
    local now = uv.now()
    local next_sched_time = math.huge
    local released_keys = {}
    for doomkey, release_time in pairs(self.pending_key_releases) do
      if now >= release_time then
        self:send_key(doomkey, false)
        -- Don't remove the released key entries yet; it might mess up pairs'
        -- iteration order.
        released_keys[#released_keys + 1] = doomkey
      else
        next_sched_time = math.min(next_sched_time, release_time)
      end
    end
    for _, doomkey in ipairs(released_keys) do
      self.pending_key_releases[doomkey] = nil
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

  doom.console:plugin_print(("DOOM started as PID %d\n\n"):format(sys_rv.pid))
end

--- @type fun(doom: Doom, _: string, chan: integer, buf: integer, data: string)
local term_input_cb
do
  local to_doomkey = {
    -- Single characters use their numeric values as the table key.
    [32] = 162, -- Space; KEY_USE
    [120] = 163, -- x; KEY_FIRE

    -- Escape sequences (and multi-characters) use strings as the table key.
    -- These don't take into account modifiers, but maybe they should.
    ["\27[A"] = 173, -- KEY_UPARROW
    ["\27[B"] = 175, -- KEY_DOWNARROW
    ["\27[C"] = 174, -- KEY_RIGHTARROW
    ["\27[D"] = 172, -- KEY_LEFTARROW
    ["\27OP"] = 187, -- KEY_F1
    ["\27OQ"] = 188, -- KEY_F2
    ["\27OR"] = 189, -- KEY_F3
    ["\27OS"] = 190, -- KEY_F4
    ["\27[15~"] = 191, -- KEY_F5
    ["\27[17~"] = 192, -- KEY_F6
    ["\27[18~"] = 193, -- KEY_F7
    ["\27[19~"] = 194, -- KEY_F8
    ["\27[20~"] = 195, -- KEY_F9
    ["\27[21~"] = 196, -- KEY_F10
    ["\27[23~"] = 215, -- KEY_F11
    ["\27[24~"] = 216, -- KEY_F12
    ["\27[H"] = 199, -- KEY_HOME
    ["\27[5~"] = 201, -- KEY_PGUP
    ["\27[6~"] = 209, -- KEY_PGDN
  }

  term_input_cb = function(doom, _, _, _, data)
    local lines, columns = data:match "^\27%[(%d+);(%d+)R$"
    if lines then
      -- Cursor position report (DSR-CPR); requested by Screen.redraw to get the
      -- size of the terminal.
      --- @cast lines string
      --- @cast columns string
      doom.screen.width = tonumber(columns)
      doom.screen.height = tonumber(lines)
      return
    end

    local doomkey
    if #data == 1 and data:byte() < 128 then
      doomkey = data:byte()
      -- Make uppercase A-Z lowercase.
      if doomkey >= 65 and doomkey <= 90 then
        doomkey = doomkey - 65 + 97 -- key - 'A' + 'a'
      end
      -- Default to the read key.
      doomkey = to_doomkey[doomkey] or doomkey
    else
      doomkey = to_doomkey[data]
    end

    if doomkey then
      -- As terminals don't typically support figuring out whether *just*
      -- Alt/Shift alone is pressed, make them toggleable via different keys.
      if doomkey == 97 then -- a
        doom.alt_pressed = not doom.alt_pressed
        doom:send_key(184, doom.alt_pressed) -- KEY_RALT
        vim.schedule(function()
          doom.screen:update_title(doom)
        end)
      elseif doomkey == 122 then -- z
        doom.shift_pressed = not doom.shift_pressed
        doom:send_key(182, doom.shift_pressed) -- KEY_RSHIFT
        vim.schedule(function()
          doom.screen:update_title(doom)
        end)
      else
        -- Press other keys for a time before automatically releasing them.
        -- When https://github.com/neovim/neovim/issues/27509 lands with the
        -- kitty keyboard protocol key press/release events support, we won't
        -- need to do this for supported terminals.

        -- Reduce push time if Shift is pressed (as it speeds up movement) or
        -- when firing.
        local ms = 375
        if doom.shift_pressed or doomkey == 163 then -- KEY_FIRE
          ms = 250
        end
        doom:send_key(doomkey, true)
        doom.pending_key_releases[doomkey] = uv.now() + ms
      end

      doom:schedule_check()
      return
    end

    -- Schedule to avoid textlock.
    vim.schedule(function()
      doom.console:plugin_print(
        ('Unhandled terminal input: "%s"\n'):format(data),
        "Comment"
      )
    end)
  end
end

--- @param doom Doom
--- @param buf StrBuf
local function recv_msg_loop(doom, buf)
  --- @param n integer
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

  doom.screen = Screen.new(
    resx,
    resy,
    doom:close_on_err_wrap(function(...)
      return term_input_cb(doom, ...)
    end),
    ("actually-doom://screen//%d"):format(doom.process.pid)
  )
  doom:send_frame_request()
  doom:schedule_check()

  --- @type table<integer, fun()>
  local msg_handlers = {
    -- AMSG_FRAME
    [0] = function()
      local len = doom.screen:pixel_index(0, doom.screen.resy)
      doom.screen:set_pixels(read_bytes(len))
      doom:send_frame_request()
      doom:schedule_check()
    end,

    -- AMSG_SET_TITLE
    [1] = function()
      doom.title = read_string()
      doom.console:plugin_print(
        ('AMSG_SET_TITLE: title="%s"\n'):format(doom.title),
        "Comment"
      )
      doom.screen:update_title(doom)
    end,
  }

  while true do
    local msg_type = read8()
    local handler = msg_handlers[msg_type]
    if handler then
      handler()
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
    pending_key_releases = {},
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

--- @return Doom
function M.play()
  local ok, rv = pcall(Doom.run)
  if not ok then
    api.nvim_echo({ { rv } }, true, { err = true })
  end
  return rv
end

return M
