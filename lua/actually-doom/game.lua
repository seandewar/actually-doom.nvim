local api = vim.api
local bit = require "bit"
local fn = vim.fn
local fs = vim.fs
local log = vim.log
local ui = vim.ui
local uv = vim.uv

local strbuf = require "actually-doom.strbuf"

local M = {
  --- @enum MenuType
  menu_type = {
    MAIN = 0,
    EPISODE = 1,
    NEW_GAME = 2,
    OPTIONS = 3,
    README1 = 4,
    README2 = 5,
    SOUND = 6,
    LOAD_GAME = 7,
    SAVE_GAME = 8,
  },

  --- @enum IntermissionState
  intermission_state = {
    NONE = -1,
    STAT_COUNT = 0,
    SHOW_NEXT_LOC = 1,
  },

  --- @enum FinaleStage
  finale_stage = {
    TEXT = 0,
    ARTSCREEN = 1,
    CAST = 2,
  },
}

--- @class (exact) PlayerStatus
--- @field health integer
--- @field armour integer
--- @field ready_ammo integer?
--- @field bullets integer
--- @field shells integer
--- @field rockets integer
--- @field cells integer
--- @field max_bullets integer
--- @field max_shells integer
--- @field max_rockets integer
--- @field max_cells integer
--- @field arms table<integer, boolean>
--- @field has_blue_key boolean
--- @field has_yellow_key boolean
--- @field has_red_key boolean

--- @class (exact) PressedKey
--- @field key integer
--- @field shift boolean
--- @field alt boolean
--- @field release_time integer

--- @class (exact) Finale
--- @field stage FinaleStage
--- @field text string

--- @class (exact) Doom
--- @field play_opts PlayOpts
--- @field console Console
--- @field process vim.SystemObj
--- @field sock uv.uv_pipe_t
--- @field send_buf StrBuf
--- @field check_timer uv.uv_timer_t
--- @field check_scheduled boolean?
--- @field pressed_key PressedKey?
--- @field mouse_button_mask integer
--- @field screen Screen?
--- @field player_status PlayerStatus?
--- @field game_msg string
--- @field menu_msg string
--- @field automap_title string
--- @field finale Finale?
--- @field closed boolean?
---
--- @field run function
local Doom = {}

--- @param buf StrBuf
--- @param s string
--- @return StrBuf
local function put_string(buf, s)
  assert(#s <= 0xffff)
  return buf:put(
    string.char(bit.band(#s, 0xff)),
    string.char(bit.rshift(#s, 8)),
    s
  )
end

function Doom:send_frame_request()
  -- CMSG_WANT_FRAME (no payload)
  self.send_buf:put "\0"
end

--- @param name string
--- @param value string
function Doom:send_set_config_var(name, value)
  -- CMSG_SET_CONFIG_VAR
  self.send_buf:put "\3"
  put_string(self.send_buf, name)
  put_string(self.send_buf, value)
end

-- Corresponds to the DOOM key codes defined in doomkeys.h.
-- Non-exhaustive; contains those only referenced by us.
--- @enum DoomKey
local doomkey = {
  BACKSPACE = 127,
  USE = 162,
  FIRE = 163,
  LEFTARROW = 172,
  UPARROW = 173,
  RIGHTARROW = 174,
  DOWNARROW = 175,
  RSHIFT = 182,
  RALT = 184,
  F1 = 187,
  F2 = 188,
  F3 = 189,
  F4 = 190,
  F5 = 191,
  F6 = 192,
  F7 = 193,
  F8 = 194,
  F9 = 195,
  F10 = 196,
  F11 = 215,
  F12 = 216,
  HOME = 199,
  END = 207,
  PGUP = 201,
  PGDN = 209,
  INS = 210,
  DEL = 211,
}

--- Schedules a check to happen in approximately `ms` milliseconds from now.
--- If a check is already scheduled, reschedule it if `ms` is sooner.
--- @param ms integer? If nil, schedule for the next event loop iteration.
function Doom:schedule_check(ms)
  local function check_cb()
    self.check_scheduled = false
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
  -- check_scheduled exists to differentiate between an expired check_timer and
  -- one that's expiring on the next event loop tick, which both return a due
  -- time of 0.
  if not self.check_scheduled or self.check_timer:get_due_in() > ms then
    assert(self.check_timer:start(ms, 0, self:close_on_err_wrap(check_cb)))
    self.check_scheduled = true
  end
end

--- @param dkey integer
--- @param pressed boolean
function Doom:send_key(dkey, pressed)
  -- CMSG_PRESS_KEY
  self.send_buf:put("\1", string.char(dkey), pressed and "\1" or "\0")
end

function Doom:send_mouse_buttons()
  -- CMSG_PRESS_KEY, but using PK_MOUSEBUTTONS to indicate a mouse button mask.
  self.send_buf:put("\1", string.char(self.mouse_button_mask), "\255")
end

--- @param info PressedKey?
function Doom:press_key(info)
  if self.pressed_key then
    -- Always unpress the key, even if it's the same key being pressed again.
    -- This makes movement in the terminal more responsive.
    self:send_key(self.pressed_key.key, false)

    if self.pressed_key.shift and not (info or {}).shift then
      self:send_key(doomkey.RSHIFT, false)
    end
    if self.pressed_key.alt and not (info or {}).alt then
      self:send_key(doomkey.RALT, false)
    end
  end

  if info then
    -- Similar to above, always press the key to make things more responsive in
    -- the terminal. In particular, this improves responsiveness in the menu.
    self:send_key(info.key, true)

    if info.shift and not (self.pressed_key or {}).shift then
      self:send_key(doomkey.RSHIFT, true)
    end
    if info.alt and not (self.pressed_key or {}).alt then
      self:send_key(doomkey.RALT, true)
    end
  end
  self.pressed_key = info
end

do
  --- @type table<string, DoomKey>
  local special_to_doomkey = {
    [vim.keycode "<BS>"] = doomkey.BACKSPACE,
    [vim.keycode "<Space>"] = doomkey.USE,
    [vim.keycode "<Left>"] = doomkey.LEFTARROW,
    [vim.keycode "<Up>"] = doomkey.UPARROW,
    [vim.keycode "<Right>"] = doomkey.RIGHTARROW,
    [vim.keycode "<Down>"] = doomkey.DOWNARROW,
    [vim.keycode "<F1>"] = doomkey.F1,
    [vim.keycode "<F2>"] = doomkey.F2,
    [vim.keycode "<F3>"] = doomkey.F3,
    [vim.keycode "<F4>"] = doomkey.F4,
    [vim.keycode "<F5>"] = doomkey.F5,
    [vim.keycode "<F6>"] = doomkey.F6,
    [vim.keycode "<F7>"] = doomkey.F7,
    [vim.keycode "<F8>"] = doomkey.F8,
    [vim.keycode "<F9>"] = doomkey.F9,
    [vim.keycode "<F10>"] = doomkey.F10,
    [vim.keycode "<F11>"] = doomkey.F11,
    [vim.keycode "<F12>"] = doomkey.F12,
    [vim.keycode "<Home>"] = doomkey.HOME,
    [vim.keycode "<End>"] = doomkey.END,
    [vim.keycode "<PageUp>"] = doomkey.PGUP,
    [vim.keycode "<PageDown>"] = doomkey.PGDN,
    [vim.keycode "<Insert>"] = doomkey.INS,
    [vim.keycode "<Del>"] = doomkey.DEL,
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

  local mouse_button_bit = {
    ["Left"] = 1,
    ["Right"] = 2,
    ["Middle"] = 4,
  }

  --- @param key string
  function Doom:press_vim_key(key)
    local keycode = fn.keytrans(key)
    local mouse_prefix_i = keycode:find("Mouse>", 1, true)
      or keycode:find("Release>", 1, true)
    if mouse_prefix_i then
      -- Unlike other terminal "keys", mouse buttons report push/release events,
      -- which is nice. :-]
      local button = keycode:sub(1, mouse_prefix_i - 1):match ".*[-<](%w+)"
      local button_bit = mouse_button_bit[button]
      local pressed = keycode:byte(mouse_prefix_i) == 77 -- M(ouse)

      local old_mask = self.mouse_button_mask
      if pressed then
        self.mouse_button_mask = bit.bor(self.mouse_button_mask, button_bit)
      else
        self.mouse_button_mask =
          bit.band(self.mouse_button_mask, bit.bnot(button_bit))
      end

      if self.mouse_button_mask ~= old_mask then
        self:press_key(nil)
        self:send_mouse_buttons()
        self:schedule_check()
      end
      -- Consume the clicks. Especially important for quashing Nvim's default
      -- handling of double/multi clicks.
      return ""
    end

    -- I don't think CTRL is used in combination with other keys in Vanilla DOOM
    -- (it was just used for firing), so not bothering to consider it.
    local shift = false
    local alt = false
    local dkey
    -- Until https://github.com/neovim/neovim/issues/26575 is implemented, we
    -- need to parse keycodes ourselves.
    if #keycode == 1 then
      dkey, shift = lower(key:byte())
    else
      -- Easiest to parse these using the printable representation via keytrans;
      -- it should return modifiers in uppercase, with "M" being used for Alt
      -- (not "A", though both are supported by Nvim).
      shift = keycode:find("S-", 1, true) ~= nil
      alt = keycode:find("M-", 1, true) ~= nil
      key = keycode:match ".*[-<](.+)>" or keycode
      if #key == 1 and printable(key:byte()) then
        dkey = lower(key:byte()) -- Shift was set from keycode modifiers.
      else
        key = vim.keycode(("<%s>"):format(key))
        dkey = special_to_doomkey[key]
        if not dkey and #key == 1 then
          dkey = key:byte()
        end
      end
    end
    if not dkey then
      return
    end

    if
      self.pressed_key
      and dkey >= doomkey.LEFTARROW
      and self.pressed_key.shift == shift
      and self.pressed_key.alt == alt
    then
      -- If the arrow key in the opposite direction was active, just cancel it.
      -- This allows for more precise movement in the terminal.
      local opposite_arrow_doomkey = bit.band(dkey - doomkey.LEFTARROW + 2, 3)
        + doomkey.LEFTARROW
      if self.pressed_key.key == opposite_arrow_doomkey then
        self:press_key(nil)
        self:schedule_check()
        return "" -- Nom.
      end
    end

    -- TODO: doesn't always work well for the plasma gun or chain gun, but the
    -- default of 375 isn't awful.
    self:press_key {
      key = dkey,
      shift = shift,
      alt = alt,
      release_time = uv.now() + (self.play_opts.key_hold_ms or 375),
    }
    self:schedule_check()
    return "" -- We handled the key, so eat it (yum!)
  end
end

--- @param on boolean? If nil, detect kitty support and enable conditionally.
function Doom:enable_kitty(on)
  -- TODO: these checks are icky; simplify or remove them; also split the UI
  -- handles portion of Screen into an optional object that's nil when the UI
  -- creation is still scheduling
  if self.closed then
    return
  end
  if not self.screen or not self.screen.buf then
    vim.schedule(function()
      self:enable_kitty(on)
    end)
    return
  end

  --- @param name string?
  local function send_frame_shm_name(name)
    -- CMSG_SET_FRAME_SHM_NAME
    self.send_buf:put "\2"
    put_string(self.send_buf, name or "")
  end

  local should_detect = on == nil
    and fn.has "termux" == 0
    -- Only if we actually have a TUI lol.
    and vim.iter(api.nvim_list_uis()):find(function(u)
      return u.chan == 1 and u.stdout_tty
    end)
  local detect_cb = should_detect
      and function(kitty_gfx, result)
        if result ~= "OK" then
          self.console:plugin_print(
            (
              "kitty detection failed: %s\n"
              .. 'See ":help actually-doom-kitty" for advice\n'
            ):format(result),
            "Warn"
          )
          self:enable_kitty(false)
          return
        end

        if kitty_gfx == self.screen:kitty_gfx() then
          self.console:plugin_print "kitty graphics detected! Turning ON\n"
          kitty_gfx.detect = nil
        end
      end
    or nil

  if (on or detect_cb) and not self.screen:kitty_gfx() then
    if detect_cb then
      self.console:plugin_print "Detecting kitty graphics support...\n"
    else
      self.console:plugin_print "kitty graphics protocol ON\n"
    end

    -- NOTE: macOS doesn't like colons in shm names
    local shm_name = ("/actually-doom-%d"):format(self.process.pid)
    send_frame_shm_name(shm_name)
    self:send_set_config_var("detached_ui", "0")
    self:schedule_check()
    self.screen:set_gfx(require "actually-doom.ui.kitty", shm_name)
    self.screen:kitty_gfx().detect = detect_cb
  elseif not on and not self.screen:cell_gfx() then
    self.console:plugin_print "kitty graphics protocol OFF\n"

    send_frame_shm_name()
    self:send_set_config_var("detached_ui", "1")
    self:schedule_check()
    self.screen:set_gfx(require "actually-doom.ui.cell")
  end
end

function Doom:flush_send()
  if self.send_buf:len() == 0 then
    return
  end

  local data = self.send_buf:get()
  --- @param err string?
  local function handle_err(err)
    if err then
      self.console:plugin_print(
        ("Failed to send %d byte(s); quitting: %s\n"):format(#data, err),
        "Error"
      )
      self:close()
    end
  end
  local _, err = self.sock:write(data, handle_err)
  handle_err(err)
end

--- @param doom Doom
--- @param exe_path string
--- @param sock_path string
local function init_process(doom, exe_path, sock_path)
  --- @param console_hl string?
  --- @return fun(err: nil|string, data: string|nil)
  --- @nodiscard
  local function new_out_cb(console_hl)
    return function(err, data)
      if err then
        doom.console:plugin_print(("Stream error: %s\n"):format(err), "Error")
      elseif data then
        doom.console:print(data, console_hl)
      end
    end
  end

  local cmd = {
    exe_path,
    "-listen",
    sock_path,
    "-iwad",
    doom.play_opts.iwad_path,
  }
  vim.list_extend(cmd, doom.play_opts.extra_args or {})

  local sys_ok, sys_rv = pcall(vim.system, cmd, {
    cwd = fs.dirname(exe_path),
    stdout = new_out_cb(),
    stderr = new_out_cb "Warn",
  }, function(out)
    doom.console:print "\n"
    doom.console:plugin_print(
      ("DOOM (PID %d) exited with code %d\n"):format(doom.process.pid, out.code),
      out.code ~= 0 and "Error" or nil
    )
    doom:close()
  end)

  if not sys_ok then
    error(("Failed to run DOOM: %s"):format(sys_rv), 0)
  end
  doom.process = sys_rv

  doom.console:plugin_print(
    ("DOOM started as PID %d\n"):format(sys_rv.pid)
      .. "To forcefully quit DOOM, unload the console or screen buffer "
      .. '(e.g: ":bunload!", ":bdelete!", ":bwipeout!")\n\n'
  )
end

--- @async
--- @param doom Doom
--- @param buf StrBuf
local function recv_msg_loop(doom, buf)
  --- @param n integer (0 gives an empty string)
  --- @return string
  --- @nodiscard
  local function read_bytes(n)
    while n > buf:len() do
      coroutine.yield()
    end
    return buf:get(n)
  end

  --- @return integer
  local function read_u8()
    return read_bytes(1):byte()
  end
  --- @return integer
  local function read_i8()
    return bit.arshift(bit.lshift(read_u8(), 8), 8) -- Sign extendo!
  end
  --- @return integer
  local function read_u16()
    local a, b = read_bytes(2):byte(1, 2)
    return bit.bor(a, bit.lshift(b, 8))
  end
  --- @return integer
  local function read_i16()
    return bit.arshift(bit.lshift(read_u16(), 16), 16) -- Sign extendo!
  end
  --- @return integer
  local function read_u32()
    local a, b, c, d = read_bytes(4):byte(1, 4)
    return bit.bor(a, bit.lshift(b, 8), bit.lshift(c, 16), bit.lshift(d, 24))
  end
  --- @return integer
  local function read_i32()
    return bit.arshift(bit.lshift(read_u32(), 32), 32) -- Sign extendo!
  end
  --- @return string
  local function read_string()
    return read_bytes(read_u16())
  end

  local res_x = read_u16()
  local res_y = read_u16()
  doom.console:plugin_print(
    ("AMSG_INIT: res_x=%d res_y=%d\n"):format(res_x, res_y),
    "Debug"
  )

  doom.screen = require("actually-doom.ui").Screen.new(doom, res_x, res_y)
  doom:enable_kitty(doom.play_opts.kitty_graphics)

  -- Can't use the typical Vanilla DOOM CTRL key to fire (as it's only available
  -- as a modifier for other keys), so use X.
  doom:send_set_config_var("key_fire", "45") -- DOS scancode for x.
  doom:send_frame_request()
  doom:schedule_check()

  -- TODO: merge AMSG_FRAME_DRAW_MENU with AMSG_FRAME so we don't need this.
  --       same for intermission and finale crap
  local menu --- @type Menu?
  local intermission --- @type Intermission?
  local finale_text_len = 0 --- @type integer

  --- @type table<integer, fun(): boolean?>
  local msg_handlers = {
    -- AMSG_FRAME
    [0] = function()
      local len = require("actually-doom.ui.cell").pixel_index(
        0,
        doom.screen.res_y,
        doom.screen.res_x
      )

      local pixels = read_bytes(len)
      local enabled_dui_bits = read_u8()

      local cell_gfx = doom.screen:cell_gfx()
      if cell_gfx then
        vim.schedule(function()
          cell_gfx:refresh(
            pixels,
            menu,
            intermission,
            finale_text_len,
            bit.band(enabled_dui_bits, 1) ~= 0,
            bit.band(enabled_dui_bits, 2) ~= 0,
            bit.band(enabled_dui_bits, 4) ~= 0,
            bit.band(enabled_dui_bits, 8) ~= 0,
            bit.band(enabled_dui_bits, 16) ~= 0
          )
          -- TODO: hack
          menu = nil
          intermission = nil
          finale_text_len = 0
        end)
      end

      if doom.screen.visible then
        doom:send_frame_request()
        doom:schedule_check()
      end
    end,

    -- AMSG_PLAYER_STATUS
    [5] = function()
      local health = read_i16()
      local armour = read_i16()
      local ready_ammo = read_i16()
      local bullets = read_i16()
      local shells = read_i16()
      local rockets = read_i16()
      local cells = read_i16()
      local max_bullets = read_i16()
      local max_shells = read_i16()
      local max_rockets = read_i16()
      local max_cells = read_i16()
      local arms_bits = read_u8()
      local key_bits = read_u8()

      doom.player_status = {
        health = health,
        armour = armour,
        ready_ammo = ready_ammo >= 0 and ready_ammo or nil,
        bullets = bullets,
        shells = shells,
        rockets = rockets,
        cells = cells,
        max_bullets = max_bullets,
        max_shells = max_shells,
        max_rockets = max_rockets,
        max_cells = max_cells,
        arms = {
          bit.band(arms_bits, 1) ~= 0,
          bit.band(arms_bits, 2) ~= 0,
          bit.band(arms_bits, 4) ~= 0,
          bit.band(arms_bits, 8) ~= 0,
          bit.band(arms_bits, 16) ~= 0,
          bit.band(arms_bits, 32) ~= 0,
        },
        has_blue_key = bit.band(key_bits, 1) ~= 0,
        has_yellow_key = bit.band(key_bits, 2) ~= 0,
        has_red_key = bit.band(key_bits, 4) ~= 0,
      }
    end,

    -- AMSG_GAME_MESSAGE
    [4] = function()
      doom.game_msg = read_string()
      doom.console:plugin_print(
        ('AMSG_GAME_MESSAGE: msg="%s"\n'):format(doom.game_msg),
        "Debug"
      )
    end,

    -- AMSG_MENU_MESSAGE
    [6] = function()
      doom.menu_msg = read_string()
      doom.console:plugin_print(
        ('AMSG_MENU_MESSAGE: msg="%s"\n'):format(doom.menu_msg),
        "Debug"
      )
    end,

    -- AMSG_AUTOMAP_TITLE
    [7] = function()
      doom.automap_title = read_string()
      doom.console:plugin_print(
        ('AMSG_AUTOMAP_TITLE: title="%s"\n'):format(doom.automap_title),
        "Debug"
      )
    end,

    -- AMSG_FINALE_TEXT
    [10] = function()
      doom.finale = {
        stage = read_u8(),
        text = read_string(),
      }
    end,

    -- AMSG_FRAME_MENU
    [8] = function()
      local type = read_u8()
      local lumps = {}
      for i = 1, read_u16() do
        lumps[i] = read_string()
      end
      local selected_i = read_u8() + 1 -- Adjust to 1-indexed.

      local vars
      if type == M.menu_type.LOAD_GAME or type == M.menu_type.SAVE_GAME then
        local save_slots = {}
        for i = 1, read_u16() do
          save_slots[i] = read_string()
        end
        local save_slot_edit_i = read_i8() + 1 -- Adjust to 1-indexed.

        vars = {
          save_slots = save_slots,
          save_slot_edit_i = save_slot_edit_i > 0 and save_slot_edit_i or nil,
        } --[[@as LoadOrSaveGameMenuVars]]
      elseif type == M.menu_type.OPTIONS then
        local toggle_bits = read_u8()
        local mouse_sensitivity = read_i8()
        local screen_size = read_i8()

        vars = {
          low_detail = bit.band(toggle_bits, 1) ~= 0,
          messages_on = bit.band(toggle_bits, 2) ~= 0,
          mouse_sensitivity = mouse_sensitivity,
          screen_size = screen_size,
        } --[[@as OptionsMenuVars]]
      elseif type == M.menu_type.SOUND then
        vars = {
          sfx_volume = read_i8(),
          music_volume = read_i8(),
        } --[[@as SoundMenuVars]]
      end

      local cell_gfx = doom.screen:cell_gfx()
      if cell_gfx then
        menu = {
          type = type,
          lumps = lumps,
          selected_i = selected_i,
          vars = vars,
        }
      end
    end,

    -- AMSG_FRAME_INTERMISSION
    [9] = function()
      local state = read_i8()

      local kills = -1
      local items = -1
      local secret = -1
      local time = -1
      local par = -1
      if state == M.intermission_state.STAT_COUNT then
        kills = read_i32()
        items = read_i32()
        secret = read_i32()
        time = read_i32()
        par = read_i32()
      end

      local cell_gfx = doom.screen:cell_gfx()
      if cell_gfx then
        intermission = {
          state = state,
          kills = kills >= 0 and kills or nil,
          items = items >= 0 and items or nil,
          secret = secret >= 0 and secret or nil,
          time = time >= 0 and time or nil,
          par = par >= 0 and par or nil,
        }
      end
    end,

    -- AMSG_FRAME_FINALE
    [11] = function()
      local text_len = read_u16()

      local cell_gfx = doom.screen:cell_gfx()
      if cell_gfx then
        finale_text_len = text_len
      end
    end,

    -- AMSG_FRAME_SHM_READY
    [3] = function()
      local kitty_gfx = doom.screen:kitty_gfx()
      if kitty_gfx then
        vim.schedule(function()
          kitty_gfx:refresh()
        end)
      end

      if doom.screen.visible then
        doom:send_frame_request()
        doom:schedule_check()
      end
    end,

    -- AMSG_SET_TITLE
    [1] = function()
      doom.screen.title = read_string()
      doom.console:plugin_print(
        ('AMSG_SET_TITLE: title="%s"\n'):format(doom.screen.title),
        "Debug"
      )
      vim.schedule(function()
        doom.screen:update_title()
      end)
    end,

    -- AMSG_QUIT
    [2] = function()
      doom.console:plugin_print "DOOM process disconnected; quitting\n"
      doom:close()
      return true -- Quit receive loop.
    end,
  }

  while true do
    local msg_type = read_u8()
    local handler = msg_handlers[msg_type]
    if handler then
      if handler() then
        return -- Handlers can return truthy to quit the loop.
      end
    else
      doom.console:plugin_print(
        ("Received unknown message type: %d; quitting\n"):format(msg_type),
        "Error"
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
        "Warn"
      )
      if tries_left <= 0 then
        doom.console:plugin_print(
          "No connection attempts remaining; giving up\n",
          "Error"
        )
        doom:close()
        return
      end

      schedule_connect(1000)
      return
    end

    doom.console:plugin_print "Connected to the DOOM process\n"
    local recv_buf = strbuf.new(256)
    local recv_co = coroutine.create(recv_msg_loop)
    -- Pass the initial arguments.
    assert(coroutine.resume(recv_co, doom, recv_buf))

    --- @param read_err nil|string
    --- @param data string|nil
    assert(doom.sock:read_start(doom:close_on_err_wrap(function(read_err, data)
      if read_err then
        doom.console:plugin_print(
          ("Read error; quitting: %s\n"):format(read_err),
          "Error"
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

--- @param console Console
--- @param exe_path string
--- @param opts PlayOpts
--- @return Doom?
function Doom.run(console, exe_path, opts)
  local doom = setmetatable({
    console = console,
    play_opts = opts,
    check_timer = assert(uv.new_timer()),
    send_buf = strbuf.new(256),
    mouse_button_mask = 0,
    game_msg = "",
    menu_msg = "",
    automap_title = "",
  }, { __index = Doom })

  -- Less verbose Doom.close_on_err and doesn't include a stack trace.
  local function close_on_err_quieter(...)
    local ok, rv = pcall(...)
    if not ok then
      doom.console:plugin_print(rv, "Error")
      doom:close()
      error(rv, 0)
    end
    return rv
  end

  local sock_path = fs.joinpath(
    fn.stdpath "run",
    ("actually-doom.%d.%d"):format(uv.os_getpid(), uv.hrtime())
  )
  close_on_err_quieter(init_process, doom, exe_path, sock_path)

  doom:close_on_err(function()
    doom.console:set_doom(doom)
    init_connection(doom, sock_path)
  end)

  return doom
end

function Doom:close()
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
  -- Close console before the screen so it doesn't print the "buffer was
  -- unloaded" message from us closing the screen.
  if self.console then
    vim.schedule(function()
      self.console:close()
    end)
  end
  if self.screen then
    self.screen:close()
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
        "Error"
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

--- @class (exact) PlayOpts
--- @field iwad_path string?
--- @field kitty_graphics boolean?
--- @field tmux_passthrough boolean?
--- @field extra_args string[]?
--- @field key_hold_ms integer?

--- @param opts PlayOpts?
function M.play(opts)
  opts = vim.tbl_extend(
    "force",
    require("actually-doom.config").config.game,
    opts or {}
  ) --[[@as PlayOpts]]

  local function play_iwad()
    if not opts.iwad_path then
      return
    end

    local console = require("actually-doom.ui").Console.new()
    local build = require "actually-doom.build"
    build.rebuild {
      console = console,
      result_cb = function(ok, _)
        if not ok then
          local msg = "[actually-doom.nvim] DOOM build failed!"
          if api.nvim_buf_is_loaded(console.buf) then
            msg = ('%s See console for details via ":%db!"'):format(
              msg,
              console.buf
            )
          end
          vim.notify(msg, log.levels.ERROR)
          return
        end

        local doom_ok, doom_rv = Doom.run(console, build.exe_install_path, opts)
        if not doom_ok then
          vim.notify(
            ("[actually-doom.nvim] %s"):format(doom_rv),
            log.levels.ERROR
          )
        end
      end,
    }
  end

  if opts.iwad_path then
    play_iwad()
    return
  end

  local function input_path()
    ui.input({
      prompt = "Enter IWAD path: ",
      default = fn.fnamemodify("", ":~"),
      completion = "file",
    }, function(path)
      opts.iwad_path = fs.normalize(fs.abspath(path))
      play_iwad()
    end)
  end

  --- @type (string|true)[]
  local choices = api.nvim_get_runtime_file("iwad/*", true)
  if #choices == 0 then
    input_path()
    return
  end
  choices[#choices + 1] = true -- Input custom path.

  ui.select(choices, {
    prompt = "Select IWAD file: ",
    format_item = function(item)
      return item ~= true and fn.fnamemodify(item, ":~")
        or "From custom path…"
    end,
  }, function(choice, _)
    if choice == true then
      input_path()
    else
      opts.iwad_path = choice and fs.normalize(fs.abspath(choice)) or nil
      play_iwad()
    end
  end)
end

--- @param args vim.api.keyset.create_user_command.command_args
function M.play_cmd(args)
  local iwad_path = args.fargs[1]

  if not args.bang then
    local doom_ui = require "actually-doom.ui"
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

      local doom = doom_ui.screen_buf_to_doom[screen_buf]
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
        .iter(pairs(doom_ui.screen_buf_to_doom))
        :fold(0, function(acc, buf, doom)
          return not doom.closed and math.max(acc, buf) or acc
        end)
    end

    if screen_buf > 0 then
      doom_ui.screen_buf_to_doom[screen_buf].screen:goto_win()
      return
    end
  end

  local ok, rv = pcall(M.play, { iwad_path = iwad_path })
  if not ok then
    vim.notify(("[actually-doom.nvim] %s"):format(rv), log.levels.ERROR)
  end
end

M.Doom = Doom
return M
