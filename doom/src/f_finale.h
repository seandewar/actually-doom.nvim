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
//
//

#ifndef __F_FINALE__
#define __F_FINALE__

#include "d_event.h"
#include "doomtype.h"

//
// FINALE
//

typedef enum {
    F_STAGE_TEXT = 0,
    F_STAGE_ARTSCREEN = 1,
    F_STAGE_CAST = 2,
} finalestage_t;

// Called by main loop.
boolean F_Responder(event_t *ev);

// Called by main loop.
void F_Ticker(void);

// Called by main loop.
void F_Drawer(void);

void F_StartFinale(void);

#endif
