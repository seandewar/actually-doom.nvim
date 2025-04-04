#include "doomgeneric.h"

int main(int argc, char **argv)
{
    doomgeneric_Create(argc, argv);

    while (1) {
        doomgeneric_Tick();
    }
}

void DG_Init(void)
{
    // TODO
}

void DG_DrawFrame(void)
{
    // TODO
}

void DG_SleepMs(uint32_t ms)
{
    (void)ms;

    // TODO
}

uint32_t DG_GetTicksMs(void)
{
    // TODO
    return 0;
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    (void)pressed;
    (void)key;

    // TODO
    return 0;
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;

    // TODO
}
