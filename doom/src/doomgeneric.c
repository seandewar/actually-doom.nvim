#include <stdio.h>
#include <stdlib.h>

#include "doomgeneric.h"
#include "m_argv.h"

pixel_t *DG_ScreenBuffer = NULL;

void M_FindResponseFile(void);
void D_DoomMain(void);

void doomgeneric_Create(int argc, char **argv)
{
    // save arguments
    myargc = argc;
    myargv = argv;

    M_FindResponseFile();

    DG_ScreenBuffer = malloc(DOOMGENERIC_SCREEN_BUF_SIZE);

    DG_Init();

    D_DoomMain();
}
