local api = vim.api
local base64 = vim.base64
local bit = require "bit"
local fn = vim.fn

--- @class (exact) KittyGfx: Gfx
--- @field screen Screen
--- @field shm_name_base64 string
--- @field image_id integer
--- @field image_id_msb integer
--- @field image_id_lsb integer
--- @field has_image boolean?
---
--- @field new function
--- @field type string
local M = {
  type = "kitty",
}

-- Extracted from kitty's rowcolumn-diacritics.txt using these commands in Nvim:
--
-- :v/^\w\+/d
-- :%s/^\(\w\+\).*/\='"\' .. luaeval("{_A:byte(1, #_A)}", submatch(1)->str2nr(16)->nr2char())->join('\') .. '",'
--
-- (Used luaeval over str2list as the latter doesn't always give single bytes)
-- Just one more reason why Vim/Nvim rocks! :-]
--
-- To convert a 0-indexed row/column number to a diacritic for use in kitty
-- Unicode placeholders, use `diacritics[x + 1]`.
local diacritics = {
  "\204\133",
  "\204\141",
  "\204\142",
  "\204\144",
  "\204\146",
  "\204\189",
  "\204\190",
  "\204\191",
  "\205\134",
  "\205\138",
  "\205\139",
  "\205\140",
  "\205\144",
  "\205\145",
  "\205\146",
  "\205\151",
  "\205\155",
  "\205\163",
  "\205\164",
  "\205\165",
  "\205\166",
  "\205\167",
  "\205\168",
  "\205\169",
  "\205\170",
  "\205\171",
  "\205\172",
  "\205\173",
  "\205\174",
  "\205\175",
  "\210\131",
  "\210\132",
  "\210\133",
  "\210\134",
  "\210\135",
  "\214\146",
  "\214\147",
  "\214\148",
  "\214\149",
  "\214\151",
  "\214\152",
  "\214\153",
  "\214\156",
  "\214\157",
  "\214\158",
  "\214\159",
  "\214\160",
  "\214\161",
  "\214\168",
  "\214\169",
  "\214\171",
  "\214\172",
  "\214\175",
  "\215\132",
  "\216\144",
  "\216\145",
  "\216\146",
  "\216\147",
  "\216\148",
  "\216\149",
  "\216\150",
  "\216\151",
  "\217\151",
  "\217\152",
  "\217\153",
  "\217\154",
  "\217\155",
  "\217\157",
  "\217\158",
  "\219\150",
  "\219\151",
  "\219\152",
  "\219\153",
  "\219\154",
  "\219\155",
  "\219\156",
  "\219\159",
  "\219\160",
  "\219\161",
  "\219\162",
  "\219\164",
  "\219\167",
  "\219\168",
  "\219\171",
  "\219\172",
  "\220\176",
  "\220\178",
  "\220\179",
  "\220\181",
  "\220\182",
  "\220\186",
  "\220\189",
  "\220\191",
  "\221\128",
  "\221\129",
  "\221\131",
  "\221\133",
  "\221\135",
  "\221\137",
  "\221\138",
  "\223\171",
  "\223\172",
  "\223\173",
  "\223\174",
  "\223\175",
  "\223\176",
  "\223\177",
  "\223\179",
  "\224\160\150",
  "\224\160\151",
  "\224\160\152",
  "\224\160\153",
  "\224\160\155",
  "\224\160\156",
  "\224\160\157",
  "\224\160\158",
  "\224\160\159",
  "\224\160\160",
  "\224\160\161",
  "\224\160\162",
  "\224\160\163",
  "\224\160\165",
  "\224\160\166",
  "\224\160\167",
  "\224\160\169",
  "\224\160\170",
  "\224\160\171",
  "\224\160\172",
  "\224\160\173",
  "\224\165\145",
  "\224\165\147",
  "\224\165\148",
  "\224\190\130",
  "\224\190\131",
  "\224\190\134",
  "\224\190\135",
  "\225\141\157",
  "\225\141\158",
  "\225\141\159",
  "\225\159\157",
  "\225\164\186",
  "\225\168\151",
  "\225\169\181",
  "\225\169\182",
  "\225\169\183",
  "\225\169\184",
  "\225\169\185",
  "\225\169\186",
  "\225\169\187",
  "\225\169\188",
  "\225\173\171",
  "\225\173\173",
  "\225\173\174",
  "\225\173\175",
  "\225\173\176",
  "\225\173\177",
  "\225\173\178",
  "\225\173\179",
  "\225\179\144",
  "\225\179\145",
  "\225\179\146",
  "\225\179\154",
  "\225\179\155",
  "\225\179\160",
  "\225\183\128",
  "\225\183\129",
  "\225\183\131",
  "\225\183\132",
  "\225\183\133",
  "\225\183\134",
  "\225\183\135",
  "\225\183\136",
  "\225\183\137",
  "\225\183\139",
  "\225\183\140",
  "\225\183\145",
  "\225\183\146",
  "\225\183\147",
  "\225\183\148",
  "\225\183\149",
  "\225\183\150",
  "\225\183\151",
  "\225\183\152",
  "\225\183\153",
  "\225\183\154",
  "\225\183\155",
  "\225\183\156",
  "\225\183\157",
  "\225\183\158",
  "\225\183\159",
  "\225\183\160",
  "\225\183\161",
  "\225\183\162",
  "\225\183\163",
  "\225\183\164",
  "\225\183\165",
  "\225\183\166",
  "\225\183\190",
  "\226\131\144",
  "\226\131\145",
  "\226\131\148",
  "\226\131\149",
  "\226\131\150",
  "\226\131\151",
  "\226\131\155",
  "\226\131\156",
  "\226\131\161",
  "\226\131\167",
  "\226\131\169",
  "\226\131\176",
  "\226\179\175",
  "\226\179\176",
  "\226\179\177",
  "\226\183\160",
  "\226\183\161",
  "\226\183\162",
  "\226\183\163",
  "\226\183\164",
  "\226\183\165",
  "\226\183\166",
  "\226\183\167",
  "\226\183\168",
  "\226\183\169",
  "\226\183\170",
  "\226\183\171",
  "\226\183\172",
  "\226\183\173",
  "\226\183\174",
  "\226\183\175",
  "\226\183\176",
  "\226\183\177",
  "\226\183\178",
  "\226\183\179",
  "\226\183\180",
  "\226\183\181",
  "\226\183\182",
  "\226\183\183",
  "\226\183\184",
  "\226\183\185",
  "\226\183\186",
  "\226\183\187",
  "\226\183\188",
  "\226\183\189",
  "\226\183\190",
  "\226\183\191",
  "\234\153\175",
  "\234\153\188",
  "\234\153\189",
  "\234\155\176",
  "\234\155\177",
  "\234\163\160",
  "\234\163\161",
  "\234\163\162",
  "\234\163\163",
  "\234\163\164",
  "\234\163\165",
  "\234\163\166",
  "\234\163\167",
  "\234\163\168",
  "\234\163\169",
  "\234\163\170",
  "\234\163\171",
  "\234\163\172",
  "\234\163\173",
  "\234\163\174",
  "\234\163\175",
  "\234\163\176",
  "\234\163\177",
  "\234\170\176",
  "\234\170\178",
  "\234\170\179",
  "\234\170\183",
  "\234\170\184",
  "\234\170\190",
  "\234\170\191",
  "\234\171\129",
  "\239\184\160",
  "\239\184\161",
  "\239\184\162",
  "\239\184\163",
  "\239\184\164",
  "\239\184\165",
  "\239\184\166",
  "\240\144\168\143",
  "\240\144\168\184",
  "\240\157\134\133",
  "\240\157\134\134",
  "\240\157\134\135",
  "\240\157\134\136",
  "\240\157\134\137",
  "\240\157\134\170",
  "\240\157\134\171",
  "\240\157\134\172",
  "\240\157\134\173",
  "\240\157\137\130",
  "\240\157\137\131",
  "\240\157\137\132",
}

--- @param kitty KittyGfx
local function setup_term_buf(kitty)
  local scratch_buf = require("actually-doom.ui").scratch_buf:reset()
  scratch_buf:put(
    -- Reset attributes, clear screen, clear scrollback, cursor to 1,1.
    "\27[m\27[2J\27[3J\27[H",
    -- Set foreground colour to least significant 8 bits of image ID. "True"
    -- colour terminals may use 24 bits via RGB, but &termguicolors may be off.
    "\27[38;5;",
    kitty.image_id_lsb,
    "m"
  )

  local id_msb_diacritic = assert(diacritics[kitty.image_id_msb + 1])
  for y = 1, kitty.screen.term_height do
    for x = 1, kitty.screen.term_width do
      local row_diacritic = diacritics[y]
      local col_diacritic = diacritics[x]
      if not row_diacritic or not col_diacritic then
        break -- Ran out of usable diacritics; skip the rest of the row.
      end
      scratch_buf:put(
        "\244\142\187\174",
        row_diacritic,
        col_diacritic,
        id_msb_diacritic
      )
    end
    if y < kitty.screen.term_height then
      scratch_buf:put "\r\n"
    end
  end

  api.nvim_chan_send(kitty.screen.term_chan, scratch_buf:get())
end

--- @param screen Screen
--- @param shm_name string
--- @return KittyGfx
--- @nodiscard
function M.new(screen, shm_name)
  local kitty = setmetatable({
    screen = screen,
    shm_name_base64 = base64.encode(shm_name),
    image_id = 0,
  }, { __index = M })

  while true do
    kitty.image_id = fn.rand() -- Random 32-bit number.

    -- When specifying the image ID of a Unicode placement, the foreground
    -- colour is used as the low 24 bits of the ID. The upper 8 bits are
    -- specified seperately via a diacritic.
    --
    -- In 256 colour mode, only the low 8 bits are usable, but we want to avoid
    -- using colours 0-15 as they can be customized via g:terminal_color_X.
    --
    -- This check also avoids ID 0, which we can't use (as that tells the
    -- terminal to allocate its own; we can't inspect what ID it chooses because
    -- we silence responses to stop them from being interpreted as keystrokes).
    if bit.band(kitty.image_id, 0xff) >= 16 then
      break
    end
  end
  -- Because we want compatibility with 256 colours, we won't be able to specify
  -- the middle 16 bits of the ID, so clear them.
  kitty.image_id = bit.band(kitty.image_id, bit.bnot(0xffff00))
  kitty.image_id_lsb = bit.band(kitty.image_id, 0xff)
  kitty.image_id_msb = bit.rshift(kitty.image_id, 24)
  -- Because Lua bitop normalizes numbers to the 32-bit signed range (see :help
  -- lua-bit-semantics), the ID will be treated as negative if the 31st bit is
  -- set. While this is fine in 32-bit Lua when formatting via %u, in 64-bit Lua
  -- the number is sign extended, so %u will result in too large of a value.
  -- Mask the low 32-bits via modulo to eliminate any sign-extended bits.
  kitty.image_id = kitty.image_id % 0x100000000

  setup_term_buf(kitty)
  return kitty
end

function M:close()
  if self.has_image then
    -- Delete the image and its virtual placement.
    io.stdout:write(
      self.screen:passthrough_escape(("\27_Gq=2,a=d,d=I,i=%u,p=%u\27\\"):format(
        self.image_id,
        self.image_id -- Placement ID same as image ID for convenience.
      ))
    )
    self.has_image = false
  end
end

function M:refresh()
  local old_term_width = self.screen.term_width
  local old_term_height = self.screen.term_height
  self.screen:update_term_size()
  if
    self.screen.term_width ~= old_term_width
    or self.screen.term_height ~= old_term_height
  then
    setup_term_buf(self)
  end

  -- Read frame image data (24-bit RGB) from the shared memory object.
  -- Create/re-use and place the virtual placement for it.
  io.stdout:write(
    self.screen:passthrough_escape(
      (
        "\27_Gq=2,a=T,U=1,z=-1,p=%u,c=%u,r=%u," -- Control and placement info.
        .. "t=s,f=24,i=%u,s=%u,v=%u;%s\27\\" -- Image info.
      ):format(
        self.image_id, -- Placement ID same as image ID for convenience.
        self.screen.term_width,
        self.screen.term_height,
        self.image_id,
        self.screen.res_x,
        self.screen.res_y,
        self.shm_name_base64
      )
    )
  )
  self.has_image = true
end

return M
