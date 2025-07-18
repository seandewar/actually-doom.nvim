# actually-doom.nvim can already build DOOM by itself without a Makefile, but
# this Makefile is useful for building a debug version of DOOM while keeping the
# object files.
#
# Just set $OUTDIR appropriately at the command line when invoking make.
# You may need to run "make clean" first if an executable already exists there.

CFLAGS += -std=c99 -Wall -Wextra -Wpedantic -g3

# Platform-specific flags
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
    CFLAGS += -D_POSIX_C_SOURCE=199309 -D_GNU_SOURCE
else ifeq ($(UNAME_S),Darwin)
    # macOS needs _DARWIN_C_SOURCE for some functions
    CFLAGS += -D_DARWIN_C_SOURCE
endif
LDLIBS += -lm -lc
OUTDIR ?= build

OBJS := am_map.o doomstat.o dstrings.o d_event.o d_items.o d_iwad.o \
        d_loop.o d_main.o d_mode.o d_net.o f_finale.o f_wipe.o g_game.o \
        hu_lib.o hu_stuff.o info.o i_cdmus.o i_endoom.o i_joystick.o i_scale.o \
        i_sound.o i_system.o i_timer.o memio.o m_argv.o m_bbox.o m_cheat.o \
        m_config.o m_controls.o m_fixed.o m_menu.o m_misc.o m_random.o \
        p_ceilng.o p_doors.o p_enemy.o p_floor.o p_inter.o p_lights.o p_map.o \
        p_maputl.o p_mobj.o p_plats.o p_pspr.o p_saveg.o p_setup.o p_sight.o \
        p_spec.o p_switch.o p_telept.o p_tick.o p_user.o r_bsp.o r_data.o \
        r_draw.o r_main.o r_plane.o r_segs.o r_sky.o r_things.o sha1.o \
        sounds.o statdump.o st_lib.o st_stuff.o s_sound.o tables.o v_video.o \
        wi_stuff.o w_checksum.o w_file.o w_main.o w_wad.o z_zone.o \
        w_file_stdc.o i_input.o i_video.o doomgeneric.o doomgeneric_actually.o

OBJDIR := $(OUTDIR)/objects
OBJS := $(addprefix $(OBJDIR)/,$(OBJS))

OUTPUT := $(OUTDIR)/actually-doom

.PHONY: all clean
.DELETE_ON_ERROR:

all: $(OUTPUT)

clean:
	$(RM) -r $(OBJDIR) $(OUTPUT)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJS): | $(OBJDIR)

$(OBJDIR)/%.o: src/%.c
	$(CC) $(CFLAGS) -c $< -o $@

$(OUTPUT): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(LDLIBS) $(OBJS) -o $(OUTPUT)
