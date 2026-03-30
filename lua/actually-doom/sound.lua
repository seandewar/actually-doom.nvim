local bit = require "bit"
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

--- @class (exact) ActuallyDoomSound
--- @field console Console
--- @field backend table?
--- @field tmp_dir string?
--- @field warned_missing_backend boolean
--- @field warned_decode boolean
--- @field active table<string, vim.SystemObj>
---
--- @field new function
local M = {}

local backends = {
  {
    exe = "ffplay",
    cmd = function(path)
      return { "ffplay", "-autoexit", "-nodisp", "-loglevel", "quiet", path }
    end,
  },
  {
    exe = "mpv",
    cmd = function(path)
      return {
        "mpv",
        "--no-terminal",
        "--really-quiet",
        "--audio-display=no",
        path,
      }
    end,
  },
  {
    exe = "pw-play",
    cmd = function(path)
      return { "pw-play", path }
    end,
  },
  {
    exe = "paplay",
    cmd = function(path)
      return { "paplay", path }
    end,
  },
  {
    exe = "aplay",
    cmd = function(path)
      return { "aplay", "-q", path }
    end,
  },
  {
    exe = "afplay",
    cmd = function(path)
      return { "afplay", path }
    end,
  },
}

local backend_names = "ffplay, mpv, pw-play, paplay, aplay, afplay"

local function le_u16(n)
  return string.char(bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff))
end

local function le_u32(n)
  return string.char(
    bit.band(n, 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 24), 0xff)
  )
end

local function scale_pcm_u8(pcm, volume)
  if volume >= 127 then
    return pcm
  end

  local scaled = {}
  for i = 1, #pcm do
    local sample = pcm:byte(i) - 128
    sample = math.floor((sample * volume) / 127 + 0.5)
    scaled[i] = string.char(math.max(0, math.min(255, sample + 128)))
  end
  return table.concat(scaled)
end

local function dmx_to_wav(lump, volume)
  if #lump < 8 then
    return nil, "DMX lump too short"
  end

  local format = lump:byte(1) + bit.lshift(lump:byte(2), 8)
  if format ~= 3 then
    return nil, ("Unsupported DMX format: %d"):format(format)
  end

  local sample_rate = lump:byte(3) + bit.lshift(lump:byte(4), 8)
  local sample_count = lump:byte(5)
    + bit.lshift(lump:byte(6), 8)
    + bit.lshift(lump:byte(7), 16)
    + bit.lshift(lump:byte(8), 24)

  local available = #lump - 8
  if sample_count > available then
    sample_count = available
  end
  if sample_rate <= 0 or sample_count <= 0 then
    return nil, "DMX lump has invalid metadata"
  end

  local pcm = lump:sub(9, 8 + sample_count)
  pcm = scale_pcm_u8(pcm, volume)

  local header = table.concat({
    "RIFF",
    le_u32(36 + #pcm),
    "WAVE",
    "fmt ",
    le_u32(16),
    le_u16(1),
    le_u16(1),
    le_u32(sample_rate),
    le_u32(sample_rate),
    le_u16(1),
    le_u16(8),
    "data",
    le_u32(#pcm),
  })

  return header .. pcm
end

local function write_file(path, data)
  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, open_err
  end

  local written, write_err = uv.fs_write(fd, data, -1)
  local closed_ok, close_err = uv.fs_close(fd)
  if not written then
    return nil, write_err
  end
  if not closed_ok then
    return nil, close_err
  end

  return true
end

local function detect_backend()
  for _, backend in ipairs(backends) do
    if fn.executable(backend.exe) == 1 then
      return backend
    end
  end
end

local function cleanup_path(console, path)
  local ok, err = pcall(fs.rm, path)
  if not ok and err then
    console:plugin_print(
      ("Failed to delete temporary sound file: %s\n"):format(err),
      "Warn"
    )
  end
end

--- @param console Console
--- @return ActuallyDoomSound
function M.new(console)
  local tmp_dir_template =
    fs.joinpath(fn.stdpath("run"), "actually-doom-sound.XXXXXX")
  local tmp_dir, mkdtemp_err = uv.fs_mkdtemp(tmp_dir_template)
  if not tmp_dir then
    console:plugin_print(
      ("Failed to create sound temp dir: %s\n"):format(mkdtemp_err),
      "Warn"
    )
  end

  return setmetatable({
    console = console,
    backend = detect_backend(),
    tmp_dir = tmp_dir,
    warned_missing_backend = false,
    warned_decode = false,
    active = {},
  }, { __index = M })
end

function M:play(lump, volume, _sep)
  if not self.backend or not self.tmp_dir then
    if not self.warned_missing_backend then
      self.warned_missing_backend = true
      self.console:plugin_print(
        "Sound effects disabled: no supported audio player was found "
          .. ("(tried %s)\n"):format(backend_names),
        "Warn"
      )
    end
    return
  end

  local wav, decode_err = dmx_to_wav(lump, volume)
  if not wav then
    if not self.warned_decode then
      self.warned_decode = true
      self.console:plugin_print(
        ("Failed to decode a DOOM sound lump: %s\n"):format(decode_err),
        "Warn"
      )
    end
    return
  end

  local path = fs.joinpath(
    self.tmp_dir,
    ("sfx-%d-%d.wav"):format(uv.hrtime(), math.random(0, 0xffff))
  )
  local ok, write_err = write_file(path, wav)
  if not ok then
    self.console:plugin_print(
      ("Failed to write temporary sound file: %s\n"):format(write_err),
      "Warn"
    )
    return
  end

  local ok, proc = pcall(vim.system, self.backend.cmd(path), {}, function()
    self.active[path] = nil
    cleanup_path(self.console, path)
  end)
  if not ok then
    cleanup_path(self.console, path)
    self.console:plugin_print(
      ("Failed to play sound effect: %s\n"):format(proc),
      "Warn"
    )
    return
  end
  self.active[path] = proc
end

function M:close()
  for path, proc in pairs(self.active) do
    pcall(proc.kill, proc, "sigterm")
    self.active[path] = nil
  end

  if self.tmp_dir then
    local ok, err = pcall(fs.rm, self.tmp_dir, { recursive = true })
    if not ok and err then
      self.console:plugin_print(
        ("Failed to delete sound temp dir: %s\n"):format(err),
        "Warn"
      )
    end
  end
end

return M
