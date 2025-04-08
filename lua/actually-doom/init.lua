local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

local script_dir = (function()
  return fn.fnamemodify(debug.getinfo(2, "S").source:sub(2), ":h:p")
end)()

local ns = api.nvim_create_namespace "actually-doom"

--- @class HlExtmark
--- @field id integer
--- @field hl string
--- @field start_row integer
--- @field start_col integer

--- @class Console
--- @field buf integer
--- @field last_row integer
--- @field last_col integer
--- @field last_extmark HlExtmark?
local Console = {}

--- @return Console
--- @nodiscard
function Console.new()
  local buf = api.nvim_create_buf(true, true)
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  local save_curwin = api.nvim_get_current_win()
  vim.cmd(("tab %d sbuffer"):format(buf))
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
end

--- @see Console.print
--- @param text string
--- @param hl string? If nil, defaults to "Special"
function Console:plugin_print(text, hl)
  return self:print("[actually-doom.nvim] " .. text, hl or "Special")
end

--- @class Doom
--- @field console Console
--- @field process vim.SystemObj
--- @field closed boolean?
--- @field sock uv.uv_pipe_t
---
--- @field connect_timer uv.uv_timer_t?
--- @field connect_request uv.uv_connect_t?
local Doom = {}

--- @param doom Doom
--- @param sock_path string
local function init_process(doom, sock_path)
  --- @param msg_hl string?
  --- @return fun(err: nil|string, data: string|nil)
  --- @nodiscard
  local function new_on_out_func(msg_hl)
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
  local on_exit = function(out)
    doom.console:print "\n"
    doom.console:plugin_print(
      ("DOOM (PID %d) exited with code %d\n"):format(doom.process.pid, out.code),
      out.code ~= 0 and "ErrorMsg" or nil
    )
    doom:close()
  end

  local sys_ok, sys_rv = pcall(vim.system, {
    fs.joinpath(script_dir, "../../doom/build/doomgeneric_actually"),
    "-listen",
    sock_path,
  }, {
    stdout = new_on_out_func(),
    stderr = new_on_out_func "WarningMsg",
  }, on_exit)

  if not sys_ok then
    error(("[actually-doom.nvim] Failed to run DOOM: %s"):format(sys_rv), 0)
  end
  doom.process = sys_rv

  doom.console:plugin_print(("DOOM started as PID %d\n\n"):format(sys_rv.pid))
end

--- @param doom Doom
--- @param sock_path string
local function init_connection(doom, sock_path)
  doom.sock = assert(uv.new_pipe())
  local tries_left = 20
  local schedule_connect -- Late assignment so connect_cb can call it.

  --- @param err string?
  local function connect_cb(err)
    doom.connect_request = nil
    if err then
      tries_left = tries_left - 1
      doom.console:plugin_print(
        ("Failed to connect to the DOOM process: %s (%d attempt(s) left)\n"):format(
          err,
          tries_left
        ),
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
    -- TODO
  end

  doom.connect_timer = assert(uv.new_timer())
  --- @param ms integer
  schedule_connect = function(ms)
    local _, err = doom.connect_timer:start(ms, 0, function()
      local request, err = doom.sock:connect(sock_path, connect_cb)
      if err then
        connect_cb(err) -- Forward the error.
      end
      doom.connect_request = request
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
    console = Console.new(),
  }, { __index = Doom })

  local sock_path = ("/run/user/%d/actually-doom.%d.%d"):format(
    uv.getuid(),
    uv.os_getpid(),
    uv.hrtime()
  )
  local ok, rv = pcall(init_process, doom, sock_path)
  if not ok then
    doom:close(true)
    error(rv, 0)
  end

  -- DOOM process running at this point, so don't close the console when
  -- cleaning up if something goes awry, as there might be important messages.
  ok, rv = pcall(function()
    doom.console:set_buf_name(
      ("actually-doom://console//%d"):format(doom.process.pid)
    )
    local console_wins = fn.win_findbuf(doom.console.buf)
    if #console_wins > 0 then
      api.nvim_set_current_win(console_wins[1])
    end

    init_connection(doom, sock_path)
  end)
  if not ok then
    doom:close()
    error(rv, 0)
  end

  return doom
end

--- @param close_console boolean?
function Doom:close(close_console)
  if self.closed then
    return
  end
  self.closed = true

  -- Non-nil fields may be nil if we're called during initialization.
  if self.connect_request then
    self.connect_request:cancel()
  end
  if self.connect_timer then
    self.connect_timer:stop()
    self.connect_timer:close()
  end
  if self.sock then
    self.sock:close()
  end
  if self.process then
    self.process:kill "sigterm" -- Try a clean shutdown.
  end
  if close_console and self.console then
    self.console:close()
  end
end

function M.play()
  local ok, rv = pcall(Doom.run)
  if not ok then
    api.nvim_echo({ { rv } }, true, { err = true })
  end
end

return M
