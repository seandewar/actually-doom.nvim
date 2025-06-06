# High priority

# Medium Priority
- [ ] Per-WAD save directory; usually trying to load a save of a different WAD
  will lead to errors.
- [ ] Clean up the code; address some of the TODOs hanging around.
- [ ] Implement music, maybe in the executable.
- [ ] When Nvim gets kitty key press/release detection support, use that (or
  possibly make the executable listen for it, but that might be hard under
  Wayland (also we'll want to communicate with the client to figure out if a
  DOOM buffer has focus; otherwise ignore the keypresses))

# Low Priority
- [ ] Maybe move terminal rendering to the executable for performance reasons;
  things are fine under LuaJIT (as the bottleneck if nvim_chan_send; not much we
  can probably do there), but under PUC the drawing code takes a lot of time;
  most Nvim's won't be using PUC anyway...
- [ ] Support other platforms: Windows, Mac, BSDs, etc.?
