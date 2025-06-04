# High priority
- [ ] Check that this actually works with PUC Lua lol

# Medium Priority
- [ ] Clean up the code; address some of the TODOs hanging around before
  release. :)
- [ ] Implement music, maybe in the executable.
- [ ] When Nvim gets kitty key press/release detection support, use that (or
  possibly make the executable listen for it, but that might be hard under
  Wayland (also we'll want to communicate with the client to figure out if a
  DOOM buffer has focus; otherwise ignore the keypresses))

# Low Priority
- [ ] Maybe move terminal rendering and pixel blending to the executable if
  performance is bad. (Actually the bottleneck seems to be nvim_chan_send itself
  and "true colour" handling; not much we can do about that I guess?)
- [ ] Support other platforms: Windows, Mac, BSDs, etc.?
