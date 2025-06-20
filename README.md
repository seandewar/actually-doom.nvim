# actually-doom.nvim

This ain't some random DOOM Emacs-themed distro; _actually_ play DOOM in Neovim
v0.11+ on Linux and macOS!

<p align="center">
    <img alt="Kitty graphics on" width="54%" src="https://github.com/user-attachments/assets/a20eb1c6-0522-4db7-98a2-3bc86ca6ac67"/>
    <img alt="Kitty graphics off" width="45%" src="https://github.com/user-attachments/assets/e9c451c9-4561-4db6-a3b9-1f07dad7813a"/>
    <br/>
    <i>Screenshots with kitty graphics support enabled and disabled</i>
</p>

## Prerequisites

- [Neovim](https://neovim.io/) v0.11+. (LuaJIT support is recommended for
  performance reasons, but not required; check `:version`)
- Linux or macOS.
- C compiler with support for the [C99 standard](https://en.wikipedia.org/wiki/C99).

## How to play

Install it via your favourite package manager like any other plugin, then run
`:Doom`.

The [shareware version](https://www.doomworld.com/classicdoom/info/shareware.php)
of DOOM is included for your convenience.

For more information regarding controls and such, consult
`:help actually-doom.txt`.

### Keybindings

- **Movement**: Arrow keys (hold Shift to run)
- **Turn**: Left/Right arrows (hold Shift to turn quickly)
- **Strafe**: Alt + Left/Right arrows (may not work in all terminals)
- **Fire**: X
- **Use/Open doors**: Space
- **Weapon selection**: Number keys 0-8
- **Toggle automap**: Tab
- **Menu**: Escape
- **Select menu option**: Enter
- **Toggle renderer**: Ctrl+K (switch between kitty graphics and cell-based rendering)
- **Stop capturing input (i.e. to go back to Neovim control)**: Ctrl+\\ Ctrl+N

### Kitty graphics protocol

Though optional, for increased performance and visual clarity, the game is
best experienced in a terminal that implements the kitty graphics protocol
with support for Unicode placeholders.

Within the TUI on [Nvim v0.12+](https://github.com/neovim/neovim/pull/34426),
actually-doom.nvim attempts to auto-detect support by default. In other cases
it will have to be enabled manually.

See `:h actually-doom-kitty` for details. (And `:h actually-doom-tmux` if using
tmux)

## FAQ

### Why do the controls feel clunky?

Historically, it's not possible to receive precise key press and release events
within the terminal.

Fortunately, the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
provides the ability to [detect these events](https://sw.kovidgoyal.net/kitty/keyboard-protocol/#event-types),
but [Neovim currently lacks support](https://github.com/neovim/neovim/issues/27509)
for this.

### How do I stop sending input to DOOM without exiting?

Press `<C-\><C-N>`.

### Why does the graphics and performance suck?

You're likely using the fallback renderer that blasts-out a bunch of escape
codes to draw to the terminal grid. See `:h actually-doom-kitty` for a much
better experience.

### Why no Windows support?

Windows support would require more significant changes to handle platform differences
in terminal handling and process management.

If you're able to get things working on Windows (and if your code isn't
too messy 😉), feel free to [open a pull request](https://github.com/seandewar/actually-doom.nvim/pulls)
with your changes.

### Why did you make this?

🗿

## Testimonials

![dundargoc's review](https://github.com/user-attachments/assets/d58a9f66-2e20-404f-ad90-734eff29b896)
