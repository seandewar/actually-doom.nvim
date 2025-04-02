/*

Copyright(C) 2005-2014 Simon Howard

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

--

Functions for presenting the information captured from the statistics
buffer to a file.

*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d_mode.h"
#include "d_player.h"
#include "m_argv.h"

#include "statdump.h"

/* Par times for E1M1-E1M9. */
static const int doom1_par_times[] = {
    30, 75, 120, 90, 165, 180, 180, 30, 165,
};

/* Par times for MAP01-MAP09. */
static const int doom2_par_times[] = {
    30, 90, 120, 120, 90, 150, 120, 120, 270,
};

// Array of end-of-level statistics that have been captured.

#define MAX_CAPTURES 32
static wbstartstruct_t captured_stats[MAX_CAPTURES];
static int num_captured_stats = 0;

void StatCopy(wbstartstruct_t *stats)
{
    if (M_ParmExists("-statdump") && num_captured_stats < MAX_CAPTURES) {
        memcpy(&captured_stats[num_captured_stats], stats,
               sizeof(wbstartstruct_t));
        ++num_captured_stats;
    }
}

void StatDump(void) {}
