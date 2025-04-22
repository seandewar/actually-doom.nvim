// Emacs style mode select   -*- C++ -*-
//-----------------------------------------------------------------------------
//
// Copyright (C) 1993-1996 by id Software, Inc.
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
//      DOOM graphics stuff for X11, UNIX.
//
//-----------------------------------------------------------------------------

#include <string.h>

#include "config.h"
#include "doomgeneric.h"
#include "i_video.h"
#include "tables.h"
#include "z_zone.h"

int usemouse = 0;

typedef struct {
    byte r;
    byte g;
    byte b;
} col_t;

static col_t colors[256];

void I_GetEvent(void);

// The screen buffer; this is modified to draw things to the screen

byte *I_VideoBuffer = NULL;

// If true, game is running as a screensaver

boolean screensaver_mode = false;

// Flag indicating whether the screen is currently visible:
// when the screen isnt visible, don't render the screen

boolean screenvisible;

// Mouse acceleration
//
// This emulates some of the behavior of DOS mouse drivers by increasing
// the speed when the mouse is moved fast.
//
// The mouse input values are input directly to the game, but when
// the values exceed the value of mouse_threshold, they are multiplied
// by mouse_acceleration to increase the speed.

float mouse_acceleration = 2.0;
int mouse_threshold = 10;

// Gamma correction level to use

int usegamma = 0;

// Palette converted to RGB565

static uint16_t rgb565_palette[256];

void cmap_to_fb(byte *out, byte *in, int in_pixels)
{
    int i;
    col_t c;

    for (i = 0; i < in_pixels; i++) {
        c = colors[*in++]; /* R:8 G:8 B:8 format! */
        *out++ = c.r;
        *out++ = c.g;
        *out++ = c.b;
    }
}

void I_InitGraphics(void)
{
    printf("I_InitGraphics: DOOM screen size: w x h: %d x %d\n", SCREENWIDTH,
           SCREENHEIGHT);

    /* Allocate screen to draw to */
    I_VideoBuffer = (byte *)Z_Malloc(SCREENWIDTH * SCREENHEIGHT, PU_STATIC,
                                     NULL); // For DOOM to draw on

    extern void I_InitInput(void);
    I_InitInput();
}

void I_ShutdownGraphics(void)
{
    Z_Free(I_VideoBuffer);
}

void I_StartFrame(void) {}

void I_StartTic(void)
{
    I_GetEvent();
}

void I_UpdateNoBlit(void) {}

//
// I_FinishUpdate
//

void I_FinishUpdate(void)
{
    int y;
    byte *line_in, *line_out;

    /* DRAW SCREEN */
    line_in = I_VideoBuffer;
    line_out = (unsigned char *)DG_ScreenBuffer;

    y = SCREENHEIGHT;

    while (y--) {
        cmap_to_fb(line_out, line_in, SCREENWIDTH);
        line_out += SCREENWIDTH * 3; // R8G8B8 (3 bytes per pixel)
        line_in += SCREENWIDTH;
    }

    DG_DrawFrame();
}

//
// I_ReadScreen
//
void I_ReadScreen(byte *scr)
{
    memcpy(scr, I_VideoBuffer, SCREENWIDTH * SCREENHEIGHT);
}

//
// I_SetPalette
//
#define GFX_RGB565(r, g, b) \
    ((((r & 0xF8) >> 3) << 11) | (((g & 0xFC) >> 2) << 5) | ((b & 0xF8) >> 3))
#define GFX_RGB565_R(color) ((0xF800 & color) >> 11)
#define GFX_RGB565_G(color) ((0x07E0 & color) >> 5)
#define GFX_RGB565_B(color) (0x001F & color)

void I_SetPalette(byte *palette)
{
    int i;
    // col_t* c;

    // for (i = 0; i < 256; i++)
    //{
    //  c = (col_t*)palette;

    //  rgb565_palette[i] = GFX_RGB565(gammatable[usegamma][c->r],
    //                                                             gammatable[usegamma][c->g],
    //                                                             gammatable[usegamma][c->b]);

    //  palette += 3;
    //}

    /* performance boost:
     * map to the right pixel format over here! */

    for (i = 0; i < 256; ++i) {
        colors[i].r = gammatable[usegamma][*palette++];
        colors[i].g = gammatable[usegamma][*palette++];
        colors[i].b = gammatable[usegamma][*palette++];
    }
}

// Given an RGB value, find the closest matching palette index.

int I_GetPaletteIndex(int r, int g, int b)
{
    int best, best_diff, diff;
    int i;
    col_t color;

    printf("I_GetPaletteIndex\n");

    best = 0;
    best_diff = INT_MAX;

    for (i = 0; i < 256; ++i) {
        color.r = GFX_RGB565_R(rgb565_palette[i]);
        color.g = GFX_RGB565_G(rgb565_palette[i]);
        color.b = GFX_RGB565_B(rgb565_palette[i]);

        diff = (r - color.r) * (r - color.r) + (g - color.g) * (g - color.g)
               + (b - color.b) * (b - color.b);

        if (diff < best_diff) {
            best = i;
            best_diff = diff;
        }

        if (diff == 0) {
            break;
        }
    }

    return best;
}

void I_BeginRead(void) {}

void I_EndRead(void) {}

void I_SetWindowTitle(char *title)
{
    DG_SetWindowTitle(title);
}

void I_GraphicsCheckCommandLine(void) {}

void I_SetGrabMouseCallback(grabmouse_callback_t func)
{
    (void)func;
}

void I_EnableLoadingDisk(void) {}

void I_BindVideoVariables(void) {}

void I_DisplayFPSDots(boolean dots_on)
{
    (void)dots_on;
}

void I_CheckIsScreensaver(void) {}
