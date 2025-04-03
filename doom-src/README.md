Modified version of doomgeneric based on
[commit dd975839780b4c957c4597f77ccadc3dc592a038](https://github.com/ozkl/doomgeneric/tree/dd975839780b4c957c4597f77ccadc3dc592a038)
for use with actually-doom.nvim.

Things irrelevant to actually-doom.nvim such as the platform code have been
removed.

---

# doomgeneric

The purpose of doomgeneric is to make porting Doom easier.
Of course Doom is already portable but with doomgeneric it is possible with just
a few functions.

To try it you will need a WAD file (game data). If you don't own the game,
shareware version is freely available (doom1.wad).

# porting
Create a file named doomgeneric_yourplatform.c and just implement these
functions to suit your platform.
* DG_Init
* DG_DrawFrame
* DG_SleepMs
* DG_GetTicksMs
* DG_GetKey

|Functions            |Description|
|---------------------|-----------|
|DG_Init              |Initialize your platfrom (create window, framebuffer, etc...).
|DG_DrawFrame         |Frame is ready in DG_ScreenBuffer. Copy it to your platform's screen.
|DG_SleepMs           |Sleep in milliseconds.
|DG_GetTicksMs        |The ticks passed since launch in milliseconds.
|DG_GetKey            |Provide keyboard events.
|DG_SetWindowTitle    |Not required. This is for setting the window title as Doom sets this from WAD file.

### main loop
At start, call doomgeneric_Create().

In a loop, call doomgeneric_Tick().

In simplest form:
```
int main(int argc, char **argv)
{
    doomgeneric_Create(argc, argv);

    while (1)
    {
        doomgeneric_Tick();
    }

    return 0;
}
```

# sound
Sound is much harder to implement! If you need sound, take a look at SDL port in
the doomgeneric repository. It fully supports sound and music! Where to start?
Define FEATURE_SOUND, assign DG_sound_module and DG_music_module.

# platforms
Ported platforms include Windows, X11, SDL, emscripten. Just look at
doomgeneric_foo.c in the doomgeneric repository; Makefiles are provided for each
platform.
