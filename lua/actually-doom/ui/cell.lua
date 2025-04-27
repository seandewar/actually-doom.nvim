local api = vim.api
local bit = require "bit"
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

--- @class (exact) CellGfx: Gfx
--- @field screen Screen
--- @field pending_pixels string?
--- @field clear_hl_tables_ticker integer
---
--- @field new function
--- @field pixel_index function
--- @field type string
local M = {
  type = "cell",
}

--- @param screen Screen
--- @return CellGfx
function M.new(screen)
  return setmetatable({
    screen = screen,
    clear_hl_tables_ticker = 0,
  }, { __index = M })
end

function M:close()
  -- No-op.
end

-- https://gist.github.com/MicahElliott/719710?permalink_comment_id=1442838#gistcomment-1442838
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
  local cache_key = bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16))
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

--- @param pixels string
function M:refresh(pixels)
  if not self.screen.term_chan then
    return
  end
  if vim.in_fast_event() then
    if not self.pending_pixels then
      vim.schedule(function()
        self:refresh(self.pending_pixels)
        self.pending_pixels = nil
      end)
    end
    self.pending_pixels = pixels
    return
  end

  --- @param x integer (0-indexed)
  --- @param y integer (0-indexed)
  --- @return integer, integer (0-indexed)
  --- @nodiscard
  local function pixel_topleft_pos(x, y)
    local pix_x = math.min(
      math.floor((x / self.screen.term_width) * self.screen.resx),
      self.screen.resx
    )
    local pix_y = math.min(
      math.floor((y / self.screen.term_height) * self.screen.resy),
      self.screen.resy
    )
    return pix_x, pix_y
  end

  local true_colour = api.nvim_get_option_value("termguicolors", {})
    or fn.has "gui_running" == 1

  self.screen:update_term_size()
  local scratch_buf = require("actually-doom.ui").scratch_buf:reset()
  -- Reset attributes, clear screen, clear scrollback, cursor to 0,0.
  scratch_buf:put "\27[m\27[2J\27[3J\27[H"

  for y = 0, self.screen.term_height - 1 do -- 0-indexed
    for x = 0, self.screen.term_width - 1 do -- 0-indexed
      -- Pixel positions are 0-indexed.
      local pix_x, pix_y = pixel_topleft_pos(x, y)
      local pix_x2, pix_y2 = pixel_topleft_pos(x + 1, y + 1)
      pix_x2 = math.min(self.screen.resx - 1, pix_x2)
      pix_y2 = math.min(self.screen.resy - 1, pix_y2)
      local pix_count = (pix_x2 + 1 - pix_x) * (pix_y2 + 1 - pix_y)

      -- Average the colours of all pixels within this cell.
      local r, g, b = 0, 0, 0
      for py = pix_y, pix_y2 do
        for px = pix_x, pix_x2 do
          local pi = M.pixel_index(px, py, self.screen.resx) + 1
          local pr, pg, pb = pixels:byte(pi, pi + 3)
          r = r + pr
          g = g + pg
          b = b + pb
        end
      end
      r = math.min(255, math.floor(r / pix_count + 0.5))
      g = math.min(255, math.floor(g / pix_count + 0.5))
      b = math.min(255, math.floor(b / pix_count + 0.5))

      if true_colour then
        -- Set background RGB "true" colour and write a space.
        scratch_buf:put("\27[48;2;", r, ";", g, ";", b, "m ")
      else
        -- Same as above, but using a near xterm-256 colour instead.
        scratch_buf:put("\27[48;5;", rgb_to_xterm256(r, g, b), "m ")
      end
    end
    if y + 1 < self.screen.term_height then
      scratch_buf:put "\r\n"
    end
  end

  -- When using RGB, it's possible for Nvim to run out of free highlight
  -- attribute entries, causing transparent cells to be drawn (showing the
  -- background colour of the Screen window) after Nvim clears and rebuilds
  -- the attribute tables. We can work around this by forcing a rebuild of the
  -- tables before we send the frame, but this requires LuaJIT.
  if true_colour and ffi then
    self.clear_hl_tables_ticker = self.clear_hl_tables_ticker + 1
    -- Has some performance overhead, and is only needed occasionally.
    if self.clear_hl_tables_ticker >= 30 then
      ffi.C.clear_hl_tables(true)
      self.clear_hl_tables_ticker = 0
    end
  end
  api.nvim_chan_send(self.screen.term_chan, scratch_buf:get())
end

--- @param x integer (0-based)
--- @param y integer (0-based)
--- @param resx integer
--- @return integer (0-based)
--- @nodiscard
function M.pixel_index(x, y, resx)
  return (y * resx + x) * 3
end

return M
