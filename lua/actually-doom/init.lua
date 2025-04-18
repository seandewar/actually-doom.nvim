local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {
  -- Corresponds to the DOOM key codes defined in doomkeys.h.
  -- Non-exhaustive; contains those only referenced by us.
  key = {
    use = 162,
    fire = 163,
    leftarrow = 172,
    uparrow = 173,
    rightarrow = 174,
    downarrow = 175,
    rshift = 182,
    ralt = 184,
    f1 = 187,
    f2 = 188,
    f3 = 189,
    f4 = 190,
    f5 = 191,
    f6 = 192,
    f7 = 193,
    f8 = 194,
    f9 = 195,
    f10 = 196,
    f11 = 215,
    f12 = 216,
    home = 199,
    ["end"] = 207,
    pgup = 201,
    pgdn = 209,
    ins = 210,
    del = 211,
  },
}

--- Supported message protocol version for communications with the DOOM process.
--- Bump this after a breaking protocol change.
local supported_proto_version = 0

local script_dir = (function()
  return fn.fnamemodify(debug.getinfo(2, "S").source:sub(2), ":h:p")
end)()

--- @class PressedKey
--- @field key integer
--- @field shift boolean
--- @field alt boolean
--- @field release_time integer

--- @class Doom
--- @field console Console
--- @field process vim.SystemObj
--- @field sock uv.uv_pipe_t
--- @field send_buf string.buffer
--- @field check_timer uv.uv_timer_t
--- @field pressed_key PressedKey?
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
      self:send_key(M.key.rshift, false)
    end
    if not info or self.pressed_key.alt ~= info.alt then
      self:send_key(M.key.ralt, false)
    end
    self.pressed_key = nil
  end

  if info then
    self:send_key(info.key, true)
    if info.shift then
      self:send_key(M.key.rshift, true)
    end
    if info.alt then
      self:send_key(M.key.ralt, true)
    end
    self.pressed_key = info
  end
end

do
  local special_to_doomkey = {
    [vim.keycode "<BS>"] = M.key.backspace,
    [vim.keycode "<Space>"] = M.key.use,
    -- TODO: though it can be specified, RMB isn't great as it leaves Terminal
    -- mode; and <2-RightMouse> (double-clicking to use, like Vanilla) can't
    -- work for a similar reason.
    [vim.keycode "<RightMouse>"] = M.key.use,
    [vim.keycode "<Left>"] = M.key.leftarrow,
    [vim.keycode "<Up>"] = M.key.uparrow,
    [vim.keycode "<Right>"] = M.key.rightarrow,
    [vim.keycode "<Down>"] = M.key.downarrow,
    [vim.keycode "<F1>"] = M.key.f1,
    [vim.keycode "<F2>"] = M.key.f2,
    [vim.keycode "<F3>"] = M.key.f3,
    [vim.keycode "<F4>"] = M.key.f4,
    [vim.keycode "<F5>"] = M.key.f5,
    [vim.keycode "<F6>"] = M.key.f6,
    [vim.keycode "<F7>"] = M.key.f7,
    [vim.keycode "<F8>"] = M.key.f8,
    [vim.keycode "<F9>"] = M.key.f9,
    [vim.keycode "<F10>"] = M.key.f10,
    [vim.keycode "<F11>"] = M.key.f11,
    [vim.keycode "<F12>"] = M.key.f12,
    [vim.keycode "<Home>"] = M.key.home,
    [vim.keycode "<End>"] = M.key["end"],
    [vim.keycode "<PageUp>"] = M.key.pgup,
    [vim.keycode "<PageDown>"] = M.key.pgdn,
    [vim.keycode "<Insert>"] = M.key.ins,
    [vim.keycode "<Del>"] = M.key.del,
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

  --- @param key string
  function Doom:press_vim_key(key)
    -- Special cases: unlike other terminal "keys", mouse clicks report
    -- push/release events, so we can use their state exactly.
    if key == left_mouse or key == left_release then
      self:press_key(nil)
      self:send_key(M.key.fire, key == left_mouse)
      self:schedule_check()
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
      doomkey = M.key.fire
    end

    if
      self.pressed_key
      and doomkey >= M.key.leftarrow
      and self.pressed_key.shift == shift
      and self.pressed_key.alt == alt
    then
      -- If the arrow key in the opposite direction was active, just cancel it.
      -- This allows for more precise movement in the terminal.
      local opposite_arrow_doomkey = (doomkey - M.key.leftarrow + 2) % 4
        + M.key.leftarrow
      if self.pressed_key.key == opposite_arrow_doomkey then
        self:press_key(nil)
        self:schedule_check()
        return "" -- Nom.
      end
    end

    self:press_key {
      key = doomkey,
      shift = shift,
      alt = alt,
      release_time = uv.now() + 375,
    }
    self:schedule_check()
    return "" -- We handled the key, so eat it (yum!)
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

  local sys_ok, sys_rv = pcall(vim.system, {
    fs.joinpath(script_dir, "../../doom/build/actually_doom"),
    "-listen",
    sock_path,
    "-iwad",
    fs.joinpath(script_dir, "../../doom/DOOM1.WAD"),
  }, {
    stdout = new_out_cb(),
    stderr = new_out_cb "WarningMsg",
  }, function(out)
    doom.console:print "\n"
    doom.console:plugin_print(
      ("DOOM (PID %d) exited with code %d\n"):format(doom.process.pid, out.code),
      out.code ~= 0 and "ErrorMsg" or nil
    )
    doom:close()
  end)

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
--- @param buf string.buffer
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

  doom.screen = require("actually-doom.ui").Screen.new(doom, resx, resy)
  if doom.screen.visible then
    doom:send_frame_request()
    doom:schedule_check()
  end

  --- @type table<integer, fun(): boolean?>
  local msg_handlers = {
    -- AMSG_FRAME
    [0] = function()
      local len = doom.screen:pixel_index(0, doom.screen.resy)
      doom.screen.pixels = read_bytes(len)
      if doom.screen.visible then
        doom.screen:redraw()
        doom:send_frame_request()
        doom:schedule_check()
      end
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
    local recv_buf = require("string.buffer").new(256)
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
    send_buf = require("string.buffer").new(256),
  }, { __index = Doom })
  doom.console = require("actually-doom.ui").Console.new(doom)

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
    doom.console.doom = doom
    doom.console:update_buf_name()
    local console_wins = fn.win_findbuf(doom.console.buf)
    if #console_wins > 0 then
      api.nvim_set_current_win(console_wins[1])
    end

    init_connection(doom, sock_path)
  end)

  return doom
end

--- @param close_console_win boolean?
function Doom:close(close_console_win)
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
    self.console:close(close_console_win)
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

M.Doom = Doom
return M
