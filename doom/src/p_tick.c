//
// Copyright(C) 1993-1996 Id Software, Inc.
// Copyright(C) 2005-2014 Simon Howard
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// DESCRIPTION:
//      Archiving: SaveGame I/O.
//      Thinker, Ticker.
//

#include "d_think.h"
#include "doomstat.h"
#include "p_local.h"
#include "p_spec.h"
#include "z_zone.h"

int leveltime;

//
// THINKERS
// All thinkers should be allocated by Z_Malloc
// so they can be operated on uniformly.
// The actual structures will vary in size,
// but the first element must be thinker_t.
//

// Both the head and tail of the thinker list.
thinker_t thinkercap;

//
// P_InitThinkers
//
void P_InitThinkers(void)
{
    thinkercap.prev = thinkercap.next = &thinkercap;
}

//
// P_AddThinker
// Adds a new thinker at the end of the list.
//
void P_AddThinker(thinker_t *thinker)
{
    thinkercap.prev->next = thinker;
    thinker->next = &thinkercap;
    thinker->prev = thinkercap.prev;
    thinkercap.prev = thinker;
}

//
// P_RemoveThinker
// Deallocation is lazy -- it will not actually be freed
// until its thinking turn comes up.
//
void P_RemoveThinker(thinker_t *thinker)
{
    // FIXME: NOP.
    thinker->function = THINKER_REMOVED;
}

//
// P_RunThinkers
//
void P_RunThinkers(void)
{
    thinker_t *currentthinker;

    currentthinker = thinkercap.next;
    while (currentthinker != &thinkercap) {
        if (currentthinker->function == THINKER_REMOVED) {
            // time to remove it
            currentthinker->next->prev = currentthinker->prev;
            currentthinker->prev->next = currentthinker->next;
            Z_Free(currentthinker);
        } else if (currentthinker->function) {
            currentthinker->function(currentthinker);
        }
        currentthinker = currentthinker->next;
    }
}

//
// P_Ticker
//

void P_Ticker(void)
{
    int i;

    // run the tic
    if (paused)
        return;

    // pause if in menu and at least one tic has been run
    if (!netgame && menuactive && !demoplayback
        && players[consoleplayer].viewz != 1) {
        return;
    }

    for (i = 0; i < MAXPLAYERS; i++)
        if (playeringame[i])
            P_PlayerThink(&players[i]);

    P_RunThinkers();
    P_UpdateSpecials();
    P_RespawnSpecials();

    // for par times
    leveltime++;
}
