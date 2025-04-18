# High priority
- [ ] Add a way to re-open the screen as a float (maybe just `:Doom` can do
  this; change the hint message to match)
- [ ] Nvimify UI elements (hide them from the framebuffer and draw them inside
  Nvim); also consider `vim.ui.select()` for menus, `vim.ui.input()` for text
  inputs...
- [ ] Automatic rebuilding of the executable.
- [ ] IWAD selection.
- [ ] Add kitty image protocol support. (can use Doom's UI in that case, though
  using `vim.ui.select()` for menus etc. may still be useful)
- [ ] Allow any size of the float when using kitty image protocol. Show all the
  float borders in this case.

# Medium Priority
- [ ] Implement music, maybe in the executable.
- [ ] When Nvim gets kitty key press/release detection support, use that (or
  possibly make the executable listen for it, but that might be hard under
  Wayland (also we'll want to communicate with the client to figure out if a
  DOOM buffer has focus; otherwise ignore the keypresses))
- [ ] Plugin configuration.

# Low Priority
- [ ] Maybe move the rebuild logic to the plugin to eliminate the Make
  dependency.
- [ ] Add an alternative implementation of the "string.buffer" library to
  support Nvims lacking LuaJIT.
- [ ] Support other platforms: Windows, Mac, BSDs, etc.?
- [ ] Maybe move terminal rendering and pixel blending to the executable if
  performance is bad.
