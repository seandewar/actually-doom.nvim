# High priority
- [ ] Add a AMSG_QUIT type for graceful shutdowns of the server (avoids
  CONNRESET message in console).
- [ ] Quit the DOOM process when closing the screen or console or something.
- [ ] Try to quit the DOOM process cleanly when Nvim is exiting, rather than
  brutally murdering it via SIGKILL.
- [ ] Nvimify UI elements (hide them from the framebuffer and draw them inside
  Nvim); also consider `vim.ui.select()` for menus, `vim.ui.input()` for text
  inputs...
- [ ] Figure out why the screen melt effect is broken after the change that made
  frame rendering be officiated by the client.
- [ ] Pause the game when DOOM is unfocused. (Send KEY_PAUSE)
- [ ] Don't bother requesting frames when the screen window is hidden.
  (Currently, we just don't bother sending to the terminal)
- [ ] Hide the left/right or bottom borders if the screen float meets the
  appropriate edge of the editor screen (keep the top border though for the
  title); we want all the room we can get!
- [ ] Automatic rebuilding of the executable.
- [ ] IWAD selection.
- [ ] Add kitty image protocol support. (can use Doom's UI in that case, though
  using `vim.ui.select()` for menus etc. may still be useful)

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
