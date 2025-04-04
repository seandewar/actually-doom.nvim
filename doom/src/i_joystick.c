//
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
//       SDL Joystick code.
//

#include "i_joystick.h"
#include "m_config.h"
#include "m_misc.h"

// When an axis is within the dead zone, it is set to zero.
// This is 5% of the full range:

#define DEAD_ZONE (32768 / 3)

// Configuration variables:

// Standard default.cfg Joystick enable/disable

static int usejoystick = 0;

// Joystick to use, as an SDL joystick index:

static int joystick_index = -1;

// Which joystick axis to use for horizontal movement, and whether to
// invert the direction:

static int joystick_x_axis = 0;
static int joystick_x_invert = 0;

// Which joystick axis to use for vertical movement, and whether to
// invert the direction:

static int joystick_y_axis = 1;
static int joystick_y_invert = 0;

// Which joystick axis to use for strafing?

static int joystick_strafe_axis = -1;
static int joystick_strafe_invert = 0;

// Virtual to physical button joystick button mapping. By default this
// is a straight mapping.
static int joystick_physical_buttons[NUM_VIRTUAL_BUTTONS] = {0, 1, 2, 3, 4,
                                                             5, 6, 7, 8, 9};

void I_ShutdownJoystick(void) {}

void I_InitJoystick(void) {}

void I_UpdateJoystick(void) {}

void I_BindJoystickVariables(void)
{
    int i;

    M_BindVariable("use_joystick", &usejoystick);
    M_BindVariable("joystick_index", &joystick_index);
    M_BindVariable("joystick_x_axis", &joystick_x_axis);
    M_BindVariable("joystick_y_axis", &joystick_y_axis);
    M_BindVariable("joystick_strafe_axis", &joystick_strafe_axis);
    M_BindVariable("joystick_x_invert", &joystick_x_invert);
    M_BindVariable("joystick_y_invert", &joystick_y_invert);
    M_BindVariable("joystick_strafe_invert", &joystick_strafe_invert);

    for (i = 0; i < NUM_VIRTUAL_BUTTONS; ++i) {
        char name[32];
        M_snprintf(name, sizeof(name), "joystick_physical_button%i", i);
        M_BindVariable(name, &joystick_physical_buttons[i]);
    }
}
