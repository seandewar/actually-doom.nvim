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

#include <fcntl.h>

#include "config.h"
#include "d_event.h"
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doomtype.h"
#include "i_video.h"

int vanilla_keyboard_mapping = 1;

// Is the shift key currently down?

static int shiftdown = 0;

// Lookup table for mapping ASCII characters to their equivalent when
// shift is pressed on an American layout keyboard:
static const char shiftxform[] = {
    0,    1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,
    15,   16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
    30,   31,  ' ', '!', '"', '#', '$', '%', '&',
    '"', // shift-'
    '(',  ')', '*', '+',
    '<', // shift-,
    '_', // shift--
    '>', // shift-.
    '?', // shift-/
    ')', // shift-0
    '!', // shift-1
    '@', // shift-2
    '#', // shift-3
    '$', // shift-4
    '%', // shift-5
    '^', // shift-6
    '&', // shift-7
    '*', // shift-8
    '(', // shift-9
    ':',
    ':', // shift-;
    '<',
    '+', // shift-=
    '>',  '?', '@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L',
    'M',  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    '[', // shift-[
    '!', // shift-backslash - OH MY GOD DOES WATCOM SUCK
    ']', // shift-]
    '"',  '_',
    '\'', // shift-`
    'A',  'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P',  'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '{', '|', '}', '~',
    127};

// Get the equivalent ASCII (Unicode?) character for a keypress.

static unsigned char GetTypedChar(unsigned char key)
{
    // Is shift held down?  If so, perform a translation.

    if (shiftdown > 0) {
        if (key >= 0 && key < arrlen(shiftxform)) {
            key = shiftxform[key];
        } else {
            key = 0;
        }
    }

    return key;
}

static void UpdateShiftStatus(int pressed, unsigned char key)
{
    int change;

    if (pressed) {
        change = 1;
    } else {
        change = -1;
    }

    if (key == KEY_RSHIFT) {
        shiftdown += change;
    }
}

void I_GetEvent(void)
{
    event_t event;
    int pressed;
    unsigned char key;

    while (DG_GetKey(&pressed, &key)) {
        UpdateShiftStatus(pressed, key);

        // process event

        if (pressed) {
            // data1 has the key pressed, data2 has the character
            // (shift-translated, etc)
            event.type = ev_keydown;
            event.data1 = key;
            event.data2 = GetTypedChar(key);

            if (event.data1 != 0) {
                D_PostEvent(&event);
            }
        } else {
            event.type = ev_keyup;
            event.data1 = key;

            // data2 is just initialized to zero for ev_keyup.
            // For ev_keydown it's the shifted Unicode character
            // that was typed, but if something wants to detect
            // key releases it should do so based on data1
            // (key ID), not the printable char.

            event.data2 = 0;

            if (event.data1 != 0) {
                D_PostEvent(&event);
            }
            break;
        }
    }
}

void I_InitInput(void) {}
