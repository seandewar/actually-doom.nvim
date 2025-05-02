#ifndef DOOM_GENERIC
#define DOOM_GENERIC

#include <stdint.h>

#include "doomtype.h"
#include "i_video.h"

#define DOOMGENERIC_SCREEN_BUF_SIZE (SCREENWIDTH * SCREENHEIGHT * 3)

// R8G8B8; 3 bytes per pixel.
extern byte *DG_ScreenBuffer;

void doomgeneric_Create(int argc, char **argv);
void doomgeneric_Tick(void);

typedef struct {
    enum {
        IN_KEYDOWN,
        IN_KEYUP,
        IN_MOUSEBUTTONS,
    } type;

    // If type == IN_KEY*: key code (from doomkeys.h).
    // If type == IN_MOUSEBUTTONS: bitfield of mouse buttons.
    // See the comment in d_event.h within event_t for more info.
    byte value;
} input_t;

// TODO: finale, level end text
typedef enum {
    DUI_GAME_MESSAGE = 0,
    DUI_MENU_MESSAGE = 1,
    DUI_AUTOMAP_TITLE = 2,
    DUI_STATUSBAR = 3,
    DUI_MENU = 4,
    DUI_PAUSED = 5,
} duitype_t;

void DG_Init(void);
void DG_WipeTick(void);
void DG_OnGameMessage(const char *prefix, const char *msg);
void DG_OnMenuMessage(const char *msg);
void DG_OnSetAutomapTitle(const char *title);
void DG_DrawFrame(void);
void DG_DrawDetachedUI(duitype_t ui);
void DG_SleepMs(uint32_t ms);
uint32_t DG_GetTicksMs(void);
boolean DG_GetInput(input_t *input);
void DG_SetWindowTitle(const char *title);

#endif // DOOM_GENERIC
