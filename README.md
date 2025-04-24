# actually-doom.nvim

_Actually_ play DOOM in Neovim v0.11+ on Linux!

![Screenshot](https://github.com/user-attachments/assets/a20eb1c6-0522-4db7-98a2-3bc86ca6ac67)

## Prerequisites

- [Neovim](https://neovim.io/) v0.11+ built with [LuaJIT](https://luajit.org/luajit.html) support (check `:version`).
- Linux.
- C compiler with support for the [C99 standard](https://en.wikipedia.org/wiki/C99).

## How to play

Install it via your favourite package manager like any other plugin, then run
`:Doom`.

The [shareware version](https://www.doomworld.com/classicdoom/info/shareware.php)
of DOOM is included for your convenience.

### Controls

_Mostly_ the same as vanilla DOOM (see the in-game help menu); mainly:

- `Enter`/`Return` to select menu options.
- `X` to fire. _(Vanilla DOOM uses `CTRL`, which is only usable as a modifier
  within the terminal)_
- `Space` to interact with objects. _(Open doors, etc.)_
- Arrow keys to move and turn.
- Hold `Shift` with the arrow keys to sprint.
- Hold `Alt` with the arrow keys to strafe.
- Number keys to switch between weapons in your inventory.
- `Tab` to open the [automap](https://doomwiki.org/wiki/Automap).

Additionally (continue reading for details):

- `CTRL-K` to toggle kitty graphics in a supported terminal.
- `CTRL-T` to toggle tmux passthrough support.

### Kitty graphics protocol

Though optional, the game is best experienced in a terminal that implements the
[kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
with [Unicode placeholder](https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders)
support. Press `CTRL-K` in-game to enable.

Because shared memory is used to transmit frame data for performance reasons,
this does _not_ work remotely (e.g: over [SSH](https://en.wikipedia.org/wiki/Secure_Shell)).

#### Kitty graphics in tmux

To use the kitty graphics protocol within [tmux](https://github.com/tmux/tmux),
enable passthrough support (e.g: `set -g allow-passthrough on` in tmux v3.3+).

Note that the host terminal must still support the graphics protocol for this to
be effective.

actually-doom.nvim automatically uses passthrough sequences if `$TMUX` is set,
but it can be toggled manually by pressing `CTRL-T` in-game.

## FAQ

### Why do the controls feel clunky?

Historically, it's not possible to receive precise key press and release events
within the terminal.

Fortunately, the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
provides the ability to [detect these events](https://sw.kovidgoyal.net/kitty/keyboard-protocol/#event-types),
but [Neovim currently lacks support](https://github.com/neovim/neovim/issues/27509)
for them.

### Why no Windows/Mac/whatever support?

There's no technical reason, it's just that I daily-drive [Fedora Linux](https://fedoraproject.org/)
these days.

If you're able to get things working on your platform (and if your code isn't
too messy 😉), feel free to [open a pull request](https://github.com/seandewar/actually-doom.nvim/pulls)
with your changes.

### Why did you make this?

🗿
