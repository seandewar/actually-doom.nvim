# High priority
- [ ] Improve API to take an "opts" table like rebuild() now does, move API to
  init.lua, but move all the doom-related guts to doom.lua and make the init.lua
  stuff just a shim that require()s into other modules.
- [ ] Plugin configuration.
- [ ] Clean up the code; address some of the TODOs hanging around before
  release. :)

# Medium Priority
- [ ] Add an alternative implementation of the "string.buffer" library to
  support Nvims lacking LuaJIT.
- [ ] Implement music, maybe in the executable.
- [ ] When Nvim gets kitty key press/release detection support, use that (or
  possibly make the executable listen for it, but that might be hard under
  Wayland (also we'll want to communicate with the client to figure out if a
  DOOM buffer has focus; otherwise ignore the keypresses))

# Low Priority
- [ ] Maybe move terminal rendering and pixel blending to the executable if
  performance is bad.
- [ ] Support other platforms: Windows, Mac, BSDs, etc.?
