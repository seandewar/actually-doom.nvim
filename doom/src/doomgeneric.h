#ifndef DOOM_GENERIC
#define DOOM_GENERIC

#include <stdint.h>

#include "doomtype.h"
#include "f_finale.h"
#include "i_video.h"
#include "m_menu.h"
#include "p_saveg.h"
#include "wi_stuff.h"

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

// TODO: finale
typedef enum {
    DUI_GAME_MESSAGE = 0,
    DUI_MENU_MESSAGE = 1,
    DUI_AUTOMAP_TITLE = 2,
    DUI_STATUSBAR = 3,
    DUI_PAUSED = 4,
} duitype_t;

typedef enum {
    DMENU_MAIN = 0,
    DMENU_EPISODE = 1,
    DMENU_NEW_GAME = 2,
    DMENU_OPTIONS = 3,
    DMENU_README1 = 4,
    DMENU_README2 = 5,
    DMENU_SOUND = 6,
    DMENU_LOAD_GAME = 7,
    DMENU_SAVE_GAME = 8,
} duimenutype_t;

typedef union {
    struct {
        int save_slot_count;
        const char (*save_slots)[SAVESTRINGSIZE];
        // -1 if not editing a slot string.
        int save_slot_edit_i;
    } load_or_save_game;

    struct {
        boolean low_detail;
        boolean messages_on;
        int mouse_sensitivity;
        int screen_size;
    } options;

    struct {
        int sfx_volume;
        int music_volume;
    } sound;
} duimenuvars_t;

typedef struct {
    int kills;
    int items;
    int secret;
    int time;
    int par;
} duiwistats_t;

void DG_Init(void);
void DG_WipeTick(void);
void DG_OnGameMessage(const char *prefix, const char *msg);
void DG_OnMenuMessage(const char *msg);
void DG_OnSetAutomapTitle(const char *title);
void DG_OnSetFinaleText(finalestage_t stage, const char *text);
void DG_DrawFrame(void);
void DG_DrawDetachedUI(duitype_t ui);
// "vars" may be in temporary storage!
void DG_DrawMenu(duimenutype_t type, const menu_t *menu, short selected_i,
                 const duimenuvars_t *vars);
// "stats" may be in temporary storage!
void DG_DrawIntermission(stateenum_t state, const duiwistats_t *stats);
void DG_DrawFinaleText(int count);
void DG_SleepMs(uint32_t ms);
uint32_t DG_GetTicksMs(void);
boolean DG_GetInput(input_t *input);
void DG_SetWindowTitle(const char *title);

#endif // DOOM_GENERIC
