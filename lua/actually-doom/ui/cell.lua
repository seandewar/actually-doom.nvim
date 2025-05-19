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

--- @class (exact) LoadOrSaveGameMenuVars
--- @field save_slots string[]
--- @field save_slot_edit_i integer?

--- @class (exact) OptionsMenuVars
--- @field low_detail boolean
--- @field messages_on boolean
--- @field mouse_sensitivity integer
--- @field screen_size integer

--- @class (exact) SoundMenuVars
--- @field sfx_volume integer
--- @field music_volume integer

--- @class (exact) Menu
--- @field type MenuType
--- @field lumps string[]
--- @field selected_i integer
--- @field vars LoadOrSaveGameMenuVars|OptionsMenuVars|SoundMenuVars|nil

--- @class (exact) Intermission
--- @field state IntermissionState
--- @field kills integer?
--- @field items integer?
--- @field secret integer?
--- @field time integer?
--- @field par integer?

--- @class (exact) CellGfx: Gfx
--- @field screen Screen
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
    frame_text_lines = {},
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

--- @param r integer
--- @param g integer
--- @param b integer
--- @return integer
--- @nodiscard
local function rgb_key(r, g, b)
  return bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16))
end

--- Convert RGB to the closest xterm-256 colour. Excludes the first 16 system
--- colours. Not intended to be super accurate.
--- @param r integer
--- @param g integer
--- @param b integer
--- @return integer
--- @nodiscard
local function rgb_to_xterm256(r, g, b)
  local cache_key = rgb_key(r, g, b)
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
        -- Levels are sorted, so we can return as soon as the difference starts
        -- increasing again.
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

local menu_lump_to_label = {
  -- Main Menu
  M_NGAME = "New Game",
  M_OPTION = "Options",
  M_LOADG = "Load Game",
  M_SAVEG = "Save Game",
  M_RDTHIS = "Read This!",
  M_QUITG = "Quit Game",

  -- Episode Menu; text highly depends on the IWAD, so just use generic labels.
  M_EPI1 = "Episode 1",
  M_EPI2 = "Episode 2",
  M_EPI3 = "Episode 3",
  M_EPI4 = "Episode 4",

  -- New Game Menu
  M_JKILL = "I'm too young to die.",
  M_ROUGH = "Hey, not too rough.",
  M_HURT = "Hurt me plenty.",
  M_ULTRA = "Ultra-Violence.",
  M_NMARE = "Nightmare!",

  -- Options Menu
  M_ENDGAM = "End Game",
  M_MESSG = "Messages:",
  M_DETAIL = "Graphic Detail:",
  M_SCRNSZ = "Screen Size:",
  M_MSENS = "Mouse Sensitivity:",
  M_SVOL = "Sound Volume",

  -- Sound Menu
  M_SFXVOL = "Sfx Volume:",
  M_MUSVOL = "Music Volume:",
}

local menu_type = require("actually-doom").menu_type
local intermission_state = require("actually-doom").intermission_state

local menu_type_to_header_lines = {
  [menu_type.NEW_GAME] = "NEW GAME\n\nChoose Skill Level:",
  [menu_type.EPISODE] = "NEW GAME\n\nWhich Episode?",
  [menu_type.LOAD_GAME] = "LOAD GAME",
  [menu_type.SAVE_GAME] = "SAVE GAME",
  [menu_type.OPTIONS] = "OPTIONS",
  [menu_type.SOUND] = "OPTIONS\n\nSound Volume:",
}

local pause_label = "Pause"
local finished_label = "Finished"
local leaving_label = "Leaving"

--- @param pixels string
--- @param menu Menu?
--- @param intermission Intermission?
--- @param draw_game_msgs boolean?
--- @param draw_menu_msgs boolean?
--- @param draw_automap_title boolean?
--- @param draw_status_bar boolean?
--- @param draw_pause boolean?
function M:refresh(
  pixels,
  menu,
  intermission,
  draw_game_msgs,
  draw_menu_msgs,
  draw_automap_title,
  draw_status_bar,
  draw_pause
)
  if not self.screen.term_chan then
    return
  end

  --- @param x integer (0-indexed)
  --- @param y integer (0-indexed)
  --- @return integer, integer (0-indexed)
  --- @nodiscard
  local function pixel_topleft_pos(x, y)
    local pix_x = math.min(
      math.floor((x / self.screen.term_width) * self.screen.res_x),
      self.screen.res_x
    )
    local pix_y = math.min(
      math.floor((y / self.screen.term_height) * self.screen.res_y),
      self.screen.res_y
    )
    return pix_x, pix_y
  end

  local true_colour = api.nvim_get_option_value("termguicolors", {})
    or fn.has "gui_running" == 1

  self.screen:update_term_size()
  local scratch_buf = require("actually-doom.ui").scratch_buf:reset()
  -- Reset attributes, clear screen, clear scrollback, cursor to 1,1.
  scratch_buf:put "\27[m\27[2J\27[3J\27[H"

  local prev_colour
  for y = 0, self.screen.term_height - 1 do -- 0-indexed
    for x = 0, self.screen.term_width - 1 do -- 0-indexed
      -- Pixel positions are 0-indexed.
      local pix_x, pix_y = pixel_topleft_pos(x, y)
      local pix_x2, pix_y2 = pixel_topleft_pos(x + 1, y + 1)
      pix_x2 = math.min(self.screen.res_x - 1, pix_x2)
      pix_y2 = math.min(self.screen.res_y - 1, pix_y2)
      local pix_count = (pix_x2 + 1 - pix_x) * (pix_y2 + 1 - pix_y)

      -- Average the colours of all pixels within this cell.
      local r, g, b = 0, 0, 0
      for py = pix_y, pix_y2 do
        for px = pix_x, pix_x2 do
          local pi = M.pixel_index(px, py, self.screen.res_x) + 1
          local pr, pg, pb = pixels:byte(pi, pi + 3)
          r = r + pr
          g = g + pg
          b = b + pb
        end
      end
      r = math.min(255, math.floor(r / pix_count + 0.5))
      g = math.min(255, math.floor(g / pix_count + 0.5))
      b = math.min(255, math.floor(b / pix_count + 0.5))
      local colour = true_colour and rgb_key(r, g, b)
        or rgb_to_xterm256(r, g, b)

      -- Only emit an escape sequence if the colour changed.
      if colour ~= prev_colour then
        if true_colour then
          -- Set background RGB "true" colour.
          scratch_buf:put("\27[48;2;", r, ";", g, ";", b, "m")
        else
          -- Set background xterm-256 colour.
          scratch_buf:put("\27[48;5;", colour, "m")
        end
        prev_colour = colour
      end
      scratch_buf:put " "
    end
    if y + 1 < self.screen.term_height then
      scratch_buf:put "\r\n"
    end
  end

  local doom = self.screen.doom
  local player_status = doom.player_status
  if draw_status_bar and player_status then
    -- Set background colour to xterm #3a3a3a.
    scratch_buf:put "\27[48;5;237m"
    -- Cursor to last line.
    -- Foreground colour to xterm pure white, write label, foreground colour
    -- to xterm pure red, write health percentage.
    scratch_buf:putf(
      "\27[%uH\27[38;5;231m Health \27[38;5;196m%3d%% ",
      self.screen.term_height,
      player_status.health
    )
    if self.screen.term_height > 1 then
      -- Same as above, but line up and writing armour percentage.
      scratch_buf:putf(
        "\27[%uH\27[38;5;231m Armor  \27[38;5;196m%3d%% ",
        self.screen.term_height - 1,
        player_status.armour
      )
    end
    if player_status.ready_ammo and self.screen.term_height > 2 then
      -- Same as above, but line up and writing ammo count for equipped weapon.
      scratch_buf:putf(
        "\27[%uH\27[38;5;231m Ammo    \27[38;5;196m%3d ",
        self.screen.term_height - 2,
        player_status.ready_ammo
      )
    end

    local function write_ammo_type_count(row, label, ammo, max_ammo)
      assert(row >= 0 and row < 4 and #label == 4)
      if self.screen.term_height - 4 + row > 0 then
        scratch_buf:putf(
          -- Cursor to right, at least 4 lines (ammo type count) above last.
          -- Foreground colour to xterm pure white, write label.
          -- Foreground colour to xterm pure yellow, write counts.
          "\27[%u;%uH\27[38;5;231m %s \27[38;5;226m%3d / %3d ",
          self.screen.term_height - 4 + row,
          -- Length of " Bull XXX / XXX ", minus one.
          self.screen.term_width - 15,
          label,
          ammo,
          max_ammo
        )
      end
    end
    write_ammo_type_count(
      0,
      "Bull",
      player_status.bullets,
      player_status.max_bullets
    )
    write_ammo_type_count(
      1,
      "Shel",
      player_status.shells,
      player_status.max_shells
    )
    write_ammo_type_count(
      2,
      "Rckt",
      player_status.rockets,
      player_status.max_rockets
    )
    write_ammo_type_count(
      3,
      "Cell",
      player_status.cells,
      player_status.max_cells
    )

    -- Cursor to right side of last line.
    scratch_buf:put(
      "\27[",
      self.screen.term_height,
      ";",
      -- Length of " 234567     XXX ", minus one.
      self.screen.term_width - 15,
      "H "
    )
    for i = 1, #player_status.arms do -- Slots numbered 2-7.
      -- Foreground colour to xterm pure yellow or #121212, write slot number.
      scratch_buf:put(
        "\27[38;5;",
        player_status.arms[i] and 226 or 233,
        "m",
        i + 1
      )
    end

    scratch_buf:put(
      "     ",
      -- Foreground colour to xterm pure blue or #121212, write symbol.
      "\27[38;5;",
      player_status.has_blue_key and 21 or 233,
      "m●",
      -- Foreground colour to xterm pure yellow or #121212, write symbol.
      "\27[38;5;",
      player_status.has_yellow_key and 226 or 233,
      "m●",
      -- Foreground colour to xterm pure red or #121212, write symbol.
      "\27[38;5;",
      player_status.has_red_key and 196 or 233,
      "m● "
    )
  end

  --- @param len integer
  --- @param max_len integer
  local function center(len, max_len)
    return math.max(1, math.floor((max_len - len) / 2) + 1)
  end

  --- @param msg string
  --- @param start_row integer? If nil, vertically center to terminal height.
  local function write_multiline_centered(msg, start_row)
    local lines = vim.split(msg, "\n", { plain = true })
    start_row = start_row or center(#lines, self.screen.term_height)
    scratch_buf:put("\27[", start_row, "H")

    for _, line in ipairs(lines) do
      if line ~= "" then
        local col = center(#line, self.screen.term_width)
        scratch_buf:put("\27[", col, "G", line)
      end
      scratch_buf:put "\n"
    end
  end

  local function write_msg_attribs()
    -- Set background colour to xterm pure black, foreground to xterm pure red.
    scratch_buf:put "\27[48;5;16m\27[38;5;196m"
  end

  if
    menu
    or intermission
    or draw_automap_title
    or draw_game_msgs
    or draw_menu_msgs
    or draw_pause
  then
    write_msg_attribs()
  end

  if intermission and not menu then
    local level_name = assert(doom.automap_title)
    if intermission.state == intermission_state.STAT_COUNT then
      local start_row = center(9, self.screen.term_height)
      -- Foreground colour to xterm pure white, write level name, restore
      -- foreground to xterm pure red, write label.
      scratch_buf:put(
        "\27[38;5;231m\27[",
        start_row,
        ";",
        center(#level_name, self.screen.term_width),
        "H",
        level_name,
        "\n\27[38;5;196m\27[",
        center(#finished_label, self.screen.term_width),
        "G",
        finished_label
      )

      -- Number of characters in the longest line: "Secret:   XXX%"
      local label_start_col = center(14, self.screen.term_width)
      -- "Secret:   ", but minus 1 as columns are already 1-based.
      local value_min_col = label_start_col + 9
      -- "XX:XX", but an exclusive column index.
      local value_end_col = value_min_col + 5

      --- @param value integer?
      local function write_percent(value)
        if value then
          -- "XXX%", "XX%" or "X%"
          local value_len = value < 10 and 2 or value < 100 and 3 or 4
          local start_col = math.max(value_min_col, value_end_col - value_len)
          scratch_buf:put("\27[", start_col, "G", value, "%")
        end
      end

      --- @param total_secs integer?
      local function write_time(total_secs)
        if total_secs then
          local mins = math.floor(total_secs / 60)
          local secs = total_secs % 60
          local value_len = mins > 0 and 5 or 3 -- "XX:XX" or ":XX"
          local start_col = math.max(value_min_col, value_end_col - value_len)
          scratch_buf:put("\27[", start_col, "G")

          if mins > 0 then
            scratch_buf:putf("%0.2u", mins)
          end
          scratch_buf:putf(":%0.2u", secs)
        end
      end

      scratch_buf:put("\n\n\27[", label_start_col, "GKills:")
      write_percent(intermission.kills)

      scratch_buf:put("\n\27[", label_start_col, "GItems:")
      write_percent(intermission.items)

      scratch_buf:put("\n\27[", label_start_col, "GSecret:")
      write_percent(intermission.secret)

      scratch_buf:put("\n\n\27[", label_start_col, "GTime:")
      write_time(intermission.time)

      scratch_buf:put("\n\27[", label_start_col, "GPar:")
      write_time(intermission.par)
    else
      -- TODO: should say the next level we're entering, but this is easier.
      -- Write label, foreground to xterm pure white, write level name, restore
      -- foreground to xterm pure red.
      scratch_buf:put(
        "\27[;",
        center(#leaving_label, self.screen.term_width),
        "H",
        leaving_label,
        "\27[38;5;231m\27[2;",
        center(#level_name, self.screen.term_width),
        "H",
        level_name,
        "\27[38;5;196m"
      )
    end
  end
  if draw_automap_title then
    local row = math.max(1, self.screen.term_height - 3)
    scratch_buf:put("\27[", row, "H", doom.automap_title)
  end
  if draw_game_msgs then
    scratch_buf:put("\27[H", doom.game_msg)
  end
  if menu then
    local labels = {}
    local max_label_len = 0

    if menu.type == menu_type.SAVE_GAME or menu.type == menu_type.LOAD_GAME then
      local vars = menu.vars --[[@as LoadOrSaveGameMenuVars]]
      for i, slot in ipairs(vars.save_slots) do
        labels[i] = ("Slot %d: %s%s"):format(
          i,
          slot,
          i == vars.save_slot_edit_i and "_" or ""
        )
        max_label_len = math.max(max_label_len, #labels[i])
      end
    else
      for i, lump in ipairs(menu.lumps) do
        labels[i] = menu_lump_to_label[lump] or lump
        max_label_len = math.max(max_label_len, #labels[i])
      end
    end

    local start_row = center(#menu.lumps, self.screen.term_height)
    local header = menu_type_to_header_lines[menu.type]
    if header then
      local line_count = 1 + select(2, header:gsub("\n", ""))
      write_multiline_centered(header, math.max(1, start_row - line_count - 1))
    end
    scratch_buf:put("\27[", start_row, "H")

    --- @param value integer
    --- @param width integer
    local function write_thermo(value, width)
      -- Set background colour to xterm #3a3a3a
      scratch_buf:put "\27[48;5;237m"

      if value > 0 then
        -- Set foreground colour to xterm #121212, write track symbols.
        scratch_buf:put "\27[38;5;233m"
        for _ = 0, value - 1 do
          scratch_buf:put "─"
        end
      end

      -- Set foreground colour to xterm pure yellow, write knob symbol.
      scratch_buf:put "\27[38;5;226m■"

      if value < width - 1 then
        -- Set foreground colour to xterm #121212, write track symbols.
        scratch_buf:put "\27[38;5;233m"
        for _ = value, width - 2 do
          scratch_buf:put "─"
        end
      end

      write_msg_attribs()
    end

    local label_start_col = center(max_label_len, self.screen.term_width)
    if menu.vars then
      -- Extra room for the thermos and crap.
      label_start_col = math.max(1, label_start_col - 6)
    end
    local function move_to_value_col()
      scratch_buf:put("\27[", label_start_col + max_label_len + 1, "G")
    end

    for i, label in ipairs(labels) do
      if label ~= "" then
        if i == menu.selected_i then
          scratch_buf:put("\27[", math.max(1, label_start_col - 4), "G💀 ")
        end
        scratch_buf:put("\27[", label_start_col, "G", label)

        local lump = menu.lumps[i]
        if lump == "M_MESSG" then
          local vars = menu.vars --[[@as OptionsMenuVars]]
          move_to_value_col()
          scratch_buf:put(vars.messages_on and "ON" or "OFF")
        elseif lump == "M_DETAIL" then
          local vars = menu.vars --[[@as OptionsMenuVars]]
          move_to_value_col()
          scratch_buf:put(vars.low_detail and "LOW" or "HIGH")
        elseif lump == "M_SCRNSZ" then
          local vars = menu.vars --[[@as OptionsMenuVars]]
          move_to_value_col()
          write_thermo(vars.screen_size, 9)
        elseif lump == "M_MSENS" then
          local vars = menu.vars --[[@as OptionsMenuVars]]
          move_to_value_col()
          write_thermo(vars.mouse_sensitivity, 10)
        elseif lump == "M_SFXVOL" then
          local vars = menu.vars --[[@as SoundMenuVars]]
          move_to_value_col()
          write_thermo(vars.sfx_volume, 16)
        elseif lump == "M_MUSVOL" then
          local vars = menu.vars --[[@as SoundMenuVars]]
          move_to_value_col()
          write_thermo(vars.music_volume, 16)
        end
      end
      scratch_buf:put "\n"
    end
  end
  if draw_menu_msgs then
    write_multiline_centered(doom.menu_msg)
  end
  if draw_pause then
    scratch_buf:put(
      "\27[;",
      center(#pause_label, self.screen.term_width),
      "H",
      pause_label
    )
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
--- @param res_x integer
--- @return integer (0-based)
--- @nodiscard
function M.pixel_index(x, y, res_x)
  return (y * res_x + x) * 3
end

return M
