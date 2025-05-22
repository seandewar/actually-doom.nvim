# High priority
- [ ] Detached UI for finale, clean up detached_ui code
- [ ] Automatic rebuilding of the executable.
- [ ] Plugin configuration.

# Medium Priority
- [ ] Implement music, maybe in the executable.
- [ ] When Nvim gets kitty key press/release detection support, use that (or
  possibly make the executable listen for it, but that might be hard under
  Wayland (also we'll want to communicate with the client to figure out if a
  DOOM buffer has focus; otherwise ignore the keypresses))
- [ ] Maybe move the rebuild logic to the plugin to eliminate the Make
  dependency.

# Low Priority
- [ ] Maybe move terminal rendering and pixel blending to the executable if
  performance is bad.
- [ ] Add an alternative implementation of the "string.buffer" library to
  support Nvims lacking LuaJIT.
- [ ] Support other platforms: Windows, Mac, BSDs, etc.?
