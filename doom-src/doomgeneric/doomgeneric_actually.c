#include "doomgeneric.h"

int main(const int argc, char **const argv)
{
    doomgeneric_Create(argc, argv);

    while (1) {
        doomgeneric_Tick();
    }
}
