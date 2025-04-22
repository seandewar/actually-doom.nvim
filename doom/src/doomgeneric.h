#ifndef DOOM_GENERIC
#define DOOM_GENERIC

#include "doomtype.h"
#include "i_video.h"
#include <stdint.h>

#define DOOMGENERIC_SCREEN_BUF_SIZE (SCREENWIDTH * SCREENHEIGHT * 3)

// R8G8B8; 3 bytes per pixel.
extern byte *DG_ScreenBuffer;

void doomgeneric_Create(int argc, char **argv);
void doomgeneric_Tick(void);

// Implement below functions for your platform
void DG_Init(void);
void DG_WipeTick(void);
void DG_DrawFrame(void);
void DG_SleepMs(uint32_t ms);
uint32_t DG_GetTicksMs(void);
int DG_GetKey(int *pressed, unsigned char *key);
void DG_SetWindowTitle(const char *title);

#endif // DOOM_GENERIC
