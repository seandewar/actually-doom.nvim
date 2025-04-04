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
//  MapObj data. Map Objects or mobjs are actors, entities,
//  thinker, take-your-pick... anything that moves, acts, or
//  suffers state changes of more or less violent nature.
//

#ifndef __D_THINK__
#define __D_THINK__

struct mobj_s;
struct player_s;
struct pspdef_s;

typedef union {
    void (*acp1)(struct mobj_s *);
    void (*acp2)(struct player_s *, struct pspdef_s *);
} actionf_t;

struct thinker_s;
typedef void (*think_t)(struct thinker_s *);

#define THINKER_REMOVED ((think_t)(-1))

// Doubly linked list of actors.
typedef struct thinker_s {
    struct thinker_s *prev;
    struct thinker_s *next;
    think_t function;
} thinker_t;

#endif
