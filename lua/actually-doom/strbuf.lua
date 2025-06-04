--- Minimal shim of LuaJIT's string.buffer library to support Nvims using PUC
--- Lua. Doesn't aim to implement the full API; just the things I use.
---
--- Naturally uses the real string.buffer library instead if it's available, but
--- exposes only the methods actually implemented for PUC to avoid oopsies.
---
--- As Lua 5.1 doesn't have a metamethod for "#", provides a len method instead.
---
--- Nvim actually has its own shim via require("vim._stringbuffer"), but it's
--- for internal use only and implements more than I need (plus, I'd rather not
--- deal with breakage if it's changed, which is why I've written this one).

--- @alias StrBuf StrBufJit|StrBufPuc

do
  local ok, rv = pcall(require, "string.buffer")
  if ok then
    --- @class (exact) StrBufJit
    --- @field inner string.buffer
    ---
    --- @field new function
    local M = {}

    --- @param size integer?
    --- @return StrBufJit
    --- @nodiscard
    function M.new(size)
      return setmetatable({ inner = rv.new(size) }, { __index = M })
    end

    --- @return StrBufJit
    function M:reset()
      self.inner:reset()
      return self
    end

    --- @return integer
    --- @nodiscard
    function M:len()
      return #self.inner
    end

    --- @param data string|integer
    --- @param ...? string|integer
    --- @return StrBufJit
    function M:put(data, ...)
      self.inner:put(data, ...)
      return self
    end

    --- @param format string
    --- @param ... any
    --- @return StrBufJit
    function M:putf(format, ...)
      self.inner:putf(format, ...)
      return self
    end

    --- @param ...? integer
    --- @return string ...
    --- @nodiscard
    function M:get(...)
      return self.inner:get(...)
    end

    return M
  end
end

--- @class (exact) StrBufPuc
--- @field chunks string[]
--- @field slen integer
---
--- @field new function
local M = {}

--- @return StrBufPuc
--- @nodiscard
function M.new(_)
  return setmetatable({}, { __index = M }):reset()
end

--- @return StrBufPuc
function M:reset()
  self.chunks = {}
  self.slen = 0
  return self
end

--- @return integer
--- @nodiscard
function M:len()
  return self.slen
end

--- @param data string|integer
--- @param ...? string|integer
--- @return StrBufPuc
function M:put(data, ...)
  for _, chunk in ipairs { data, ... } do
    self.chunks[#self.chunks + 1] = tostring(chunk)
    self.slen = self.slen + #self.chunks[#self.chunks]
  end
  return self
end

--- @param format string
--- @param ... any
--- @return StrBufPuc
function M:putf(format, ...)
  return self:put(format:format(...))
end

--- @param ...? integer
--- @return string ...
--- @nodiscard
function M:get(...)
  local lens = { ... }
  lens = #lens == 0 and { self.slen } or lens

  -- Cba to implement a ring buffer (dunno how efficient it'd be from PUC
  -- anyway); easier to merge the chunks and slice it into the return values.
  local merged = table.concat(self.chunks)
  local start_i = 1
  local rvs = {}
  for _, len in ipairs(lens) do
    rvs[#rvs + 1] = merged:sub(start_i, start_i + len - 1)
    start_i = start_i + len
  end

  self.chunks = { merged:sub(start_i) }
  self.slen = #self.chunks[1]
  return unpack(rvs)
end

return M
