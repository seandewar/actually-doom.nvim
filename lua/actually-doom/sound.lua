local bit = require "bit"
local fn = vim.fn

--- @class (exact) ActuallyDoomSound
--- @field console Console
--- @field backend {exe: string, cmd: string[]}?
--- @field warned_missing_backend boolean
--- @field warned_decode boolean
---
--- @field new function
local M = {}

local backends = {
  { exe = "ffplay", cmd = { "ffplay", "-autoexit", "-nodisp", "-loglevel", "quiet", "-i", "pipe:0" } },
  { exe = "mpv", cmd = { "mpv", "--no-terminal", "--really-quiet", "--audio-display=no", "-" } },
  { exe = "pw-play", cmd = { "pw-play", "-" } },
  { exe = "paplay", cmd = { "paplay", "-" } },
  { exe = "aplay", cmd = { "aplay", "-q", "-" } },
  { exe = "afplay", cmd = { "afplay", "-" } },
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

  local pcm = scale_pcm_u8(lump:sub(9, 8 + sample_count), volume)
  return table.concat({
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
    pcm,
  })
end

local function detect_backend()
  for _, backend in ipairs(backends) do
    if fn.executable(backend.exe) == 1 then
      return backend
    end
  end
end

--- @param console Console
--- @return ActuallyDoomSound
function M.new(console)
  return setmetatable({
    console = console,
    backend = detect_backend(),
    warned_missing_backend = false,
    warned_decode = false,
  }, { __index = M })
end

function M:play(lump, volume)
  if not self.backend then
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

  local ok, err = pcall(vim.system, self.backend.cmd, { stdin = wav }, function()
  end)
  if not ok then
    self.console:plugin_print(
      ("Failed to play sound effect: %s\n"):format(err),
      "Warn"
    )
  end
end

return M
