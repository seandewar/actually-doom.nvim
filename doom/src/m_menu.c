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
//      DOOM selection menu, options, episode etc.
//      Sliders and icons. Kinda widget stuff.
//

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "d_englsh.h"
#include "d_loop.h"
#include "d_main.h"
#include "doomdef.h"
#include "doomgeneric.h"
#include "doomkeys.h"
#include "doomstat.h"
#include "dstrings.h"
#include "g_game.h"
#include "hu_stuff.h"
#include "i_swap.h"
#include "i_system.h"
#include "i_timer.h"
#include "i_video.h"
#include "m_controls.h"
#include "m_menu.h"
#include "m_misc.h"
#include "p_saveg.h"
#include "r_main.h"
#include "s_sound.h"
#include "sounds.h"
#include "v_video.h"
#include "w_wad.h"
#include "z_zone.h"

extern patch_t *hu_font[HU_FONTSIZE];
extern boolean message_dontfuckwithme;

extern boolean chat_on; // in heads-up code

//
// defaulted values
//
int mouseSensitivity = 5;

// Show messages has default, 0 = off, 1 = on
int showMessages = 1;

// Blocky mode, has default, 0 = high, 1 = normal
int detailLevel = 0;
int screenblocks = 10;

// -1 = no quicksave slot picked!
int quickSaveSlot;

// 1 = message to be printed
static int messageToPrint;
// ...and here is the message string!
static char *messageString;

// message x & y
int messx;
int messy;
int messageLastMenuActive;

// timed message = no input from user
boolean messageNeedsInput;

void (*messageRoutine)(int response);

char gammamsg[5][26] = {GAMMALVL0, GAMMALVL1, GAMMALVL2, GAMMALVL3, GAMMALVL4};

// we are going to be entering a savegame string
int saveStringEnter;
int saveSlot;      // which slot to save in
int saveCharIndex; // which char we're editing
// old save description before edit
char saveOldString[SAVESTRINGSIZE];

boolean inhelpscreens;
boolean menuactive;

#define SKULLXOFF -32
#define LINEHEIGHT 16

extern boolean sendpause;
char savegamestrings[10][SAVESTRINGSIZE];

char endstring[160];

// static boolean opldev;

short itemOn;           // menu item skull is on
short skullAnimCounter; // skull animation counter
short whichSkull;       // which skull to draw

// graphic name of skulls
// warning: initializer-string for array of chars is too long
char *skullName[2] = {"M_SKULL1", "M_SKULL2"};

// current menudef
menu_t *currentMenu;

//
// PROTOTYPES
//
void M_NewGame(int choice);
void M_Episode(int choice);
void M_ChooseSkill(int choice);
void M_LoadGame(int choice);
void M_SaveGame(int choice);
void M_Options(int choice);
void M_EndGame(int choice);
void M_ReadThis(int choice);
void M_ReadThis2(int choice);
void M_QuitDOOM(int choice);

void M_ChangeMessages(int choice);
void M_ChangeSensitivity(int choice);
void M_SfxVol(int choice);
void M_MusicVol(int choice);
void M_ChangeDetail(int choice);
void M_SizeDisplay(int choice);
void M_StartGame(int choice);
void M_Sound(int choice);

void M_FinishReadThis(int choice);
void M_LoadSelect(int choice);
void M_SaveSelect(int choice);
void M_ReadSaveStrings(void);
void M_QuickSave(void);
void M_QuickLoad(void);

void M_DrawMainMenu(void);
void M_DrawReadThis1(void);
void M_DrawReadThis2(void);
void M_DrawNewGame(void);
void M_DrawEpisode(void);
void M_DrawOptions(void);
void M_DrawSound(void);
void M_DrawLoad(void);
void M_DrawSave(void);

void M_DrawSaveLoadBorder(int x, int y);
void M_SetupNextMenu(menu_t *menudef);
void M_DrawThermo(int x, int y, int thermWidth, int thermDot);
void M_DrawEmptyCell(menu_t *menu, int item);
void M_DrawSelCell(menu_t *menu, int item);
void M_WriteText(int x, int y, char *string);
int M_StringWidth(char *string);
int M_StringHeight(char *string);
void M_StartMessage(char *string, void (*routine)(int), boolean input);
void M_StopMessage(void);
void M_ClearMenus(void);

//
// DOOM MENU
//
enum {
    newgame = 0,
    options,
    loadgame,
    savegame,
    readthis,
    quitdoom,
    main_end
} main_e;

menuitem_t MainMenu[] = {{1, "M_NGAME", M_NewGame, 'n'},
                         {1, "M_OPTION", M_Options, 'o'},
                         {1, "M_LOADG", M_LoadGame, 'l'},
                         {1, "M_SAVEG", M_SaveGame, 's'},
                         // Another hickup with Special edition.
                         {1, "M_RDTHIS", M_ReadThis, 'r'},
                         {1, "M_QUITG", M_QuitDOOM, 'q'}};

menu_t MainDef = {main_end, NULL, MainMenu, M_DrawMainMenu, 97, 64, 0};

//
// EPISODE SELECT
//
enum { ep1, ep2, ep3, ep4, ep_end } episodes_e;

menuitem_t EpisodeMenu[] = {{1, "M_EPI1", M_Episode, 'k'},
                            {1, "M_EPI2", M_Episode, 't'},
                            {1, "M_EPI3", M_Episode, 'i'},
                            {1, "M_EPI4", M_Episode, 't'}};

menu_t EpiDef = {
    ep_end,        // # of menu items
    &MainDef,      // previous menu
    EpisodeMenu,   // menuitem_t ->
    M_DrawEpisode, // drawing routine ->
    48,
    63, // x,y
    ep1 // lastOn
};

//
// NEW GAME
//
enum { killthings, toorough, hurtme, violence, nightmare, newg_end } newgame_e;

menuitem_t NewGameMenu[] = {{1, "M_JKILL", M_ChooseSkill, 'i'},
                            {1, "M_ROUGH", M_ChooseSkill, 'h'},
                            {1, "M_HURT", M_ChooseSkill, 'h'},
                            {1, "M_ULTRA", M_ChooseSkill, 'u'},
                            {1, "M_NMARE", M_ChooseSkill, 'n'}};

menu_t NewDef = {
    newg_end,      // # of menu items
    &EpiDef,       // previous menu
    NewGameMenu,   // menuitem_t ->
    M_DrawNewGame, // drawing routine ->
    48,
    63,    // x,y
    hurtme // lastOn
};

//
// OPTIONS MENU
//
enum {
    endgame,
    messages,
    detail,
    scrnsize,
    option_empty1,
    mousesens,
    option_empty2,
    soundvol,
    opt_end
} options_e;

menuitem_t OptionsMenu[] = {{1, "M_ENDGAM", M_EndGame, 'e'},
                            {1, "M_MESSG", M_ChangeMessages, 'm'},
                            {1, "M_DETAIL", M_ChangeDetail, 'g'},
                            {2, "M_SCRNSZ", M_SizeDisplay, 's'},
                            {-1, "", 0, '\0'},
                            {2, "M_MSENS", M_ChangeSensitivity, 'm'},
                            {-1, "", 0, '\0'},
                            {1, "M_SVOL", M_Sound, 's'}};

menu_t OptionsDef = {opt_end, &MainDef, OptionsMenu, M_DrawOptions, 60, 37, 0};

//
// Read This! MENU 1 & 2
//
enum { rdthsempty1, read1_end } read_e;

menuitem_t ReadMenu1[] = {{1, "", M_ReadThis2, 0}};

menu_t ReadDef1 = {read1_end, &MainDef, ReadMenu1, M_DrawReadThis1,
                   280,       185,      0};

enum { rdthsempty2, read2_end } read_e2;

menuitem_t ReadMenu2[] = {{1, "", M_FinishReadThis, 0}};

menu_t ReadDef2 = {read2_end, &ReadDef1, ReadMenu2, M_DrawReadThis2,
                   330,       175,       0};

//
// SOUND VOLUME MENU
//
enum { sfx_vol, sfx_empty1, music_vol, sfx_empty2, sound_end } sound_e;

menuitem_t SoundMenu[] = {{2, "M_SFXVOL", M_SfxVol, 's'},
                          {-1, "", 0, '\0'},
                          {2, "M_MUSVOL", M_MusicVol, 'm'},
                          {-1, "", 0, '\0'}};

menu_t SoundDef = {sound_end, &OptionsDef, SoundMenu, M_DrawSound, 80, 64, 0};

//
// LOAD GAME MENU
//
enum { load1, load2, load3, load4, load5, load6, load_end } load_e;

menuitem_t LoadMenu[] = {
    {1, "", M_LoadSelect, '1'}, {1, "", M_LoadSelect, '2'},
    {1, "", M_LoadSelect, '3'}, {1, "", M_LoadSelect, '4'},
    {1, "", M_LoadSelect, '5'}, {1, "", M_LoadSelect, '6'}};

menu_t LoadDef = {load_end, &MainDef, LoadMenu, M_DrawLoad, 80, 54, 0};

//
// SAVE GAME MENU
//
menuitem_t SaveMenu[] = {
    {1, "", M_SaveSelect, '1'}, {1, "", M_SaveSelect, '2'},
    {1, "", M_SaveSelect, '3'}, {1, "", M_SaveSelect, '4'},
    {1, "", M_SaveSelect, '5'}, {1, "", M_SaveSelect, '6'}};

menu_t SaveDef = {load_end, &MainDef, SaveMenu, M_DrawSave, 80, 54, 0};

//
// M_ReadSaveStrings
//  read the strings from the savegame files
//
void M_ReadSaveStrings(void)
{
    FILE *handle;
    int i;
    char name[256];

    for (i = 0; i < load_end; i++) {
        M_StringCopy(name, P_SaveGameFile(i), sizeof(name));

        handle = fopen(name, "rb");
        if (handle == NULL) {
            M_StringCopy(savegamestrings[i], EMPTYSTRING, SAVESTRINGSIZE);
            LoadMenu[i].status = 0;
            continue;
        }
        fread(&savegamestrings[i], 1, SAVESTRINGSIZE, handle);
        fclose(handle);
        LoadMenu[i].status = 1;
    }
}

//
// M_LoadGame & Cie.
//
void M_DrawLoad(void)
{
    int i;

    if (detached_ui)
        return;

    V_DrawPatchDirect(72, 28, W_CacheLumpName("M_LOADG", PU_CACHE));

    for (i = 0; i < load_end; i++) {
        M_DrawSaveLoadBorder(LoadDef.x, LoadDef.y + LINEHEIGHT * i);
        M_WriteText(LoadDef.x, LoadDef.y + LINEHEIGHT * i, savegamestrings[i]);
    }
}

//
// Draw border for the savegame description
//
void M_DrawSaveLoadBorder(int x, int y)
{
    int i;

    V_DrawPatchDirect(x - 8, y + 7, W_CacheLumpName("M_LSLEFT", PU_CACHE));

    for (i = 0; i < 24; i++) {
        V_DrawPatchDirect(x, y + 7, W_CacheLumpName("M_LSCNTR", PU_CACHE));
        x += 8;
    }

    V_DrawPatchDirect(x, y + 7, W_CacheLumpName("M_LSRGHT", PU_CACHE));
}

//
// User wants to load this game
//
void M_LoadSelect(int choice)
{
    char name[256];

    M_StringCopy(name, P_SaveGameFile(choice), sizeof(name));

    G_LoadGame(name);
    M_ClearMenus();
}

//
// Selected from DOOM menu
//
void M_LoadGame(int choice)
{
    (void)choice;

    if (netgame) {
        M_StartMessage(LOADNET, NULL, false);
        return;
    }

    M_SetupNextMenu(&LoadDef);
    M_ReadSaveStrings();
}

//
//  M_SaveGame & Cie.
//
void M_DrawSave(void)
{
    int i;

    if (detached_ui)
        return;

    V_DrawPatchDirect(72, 28, W_CacheLumpName("M_SAVEG", PU_CACHE));
    for (i = 0; i < load_end; i++) {
        M_DrawSaveLoadBorder(LoadDef.x, LoadDef.y + LINEHEIGHT * i);
        M_WriteText(LoadDef.x, LoadDef.y + LINEHEIGHT * i, savegamestrings[i]);
    }

    if (saveStringEnter) {
        i = M_StringWidth(savegamestrings[saveSlot]);
        M_WriteText(LoadDef.x + i, LoadDef.y + LINEHEIGHT * saveSlot, "_");
    }
}

//
// M_Responder calls this when user is finished
//
void M_DoSave(int slot)
{
    G_SaveGame(slot, savegamestrings[slot]);
    M_ClearMenus();

    // PICK QUICKSAVE SLOT YET?
    if (quickSaveSlot == -2)
        quickSaveSlot = slot;
}

//
// User wants to save. Start string input for M_Responder
//
void M_SaveSelect(int choice)
{
    // we are going to be intercepting all chars
    saveStringEnter = 1;

    saveSlot = choice;
    M_StringCopy(saveOldString, savegamestrings[choice], SAVESTRINGSIZE);
    if (!strcmp(savegamestrings[choice], EMPTYSTRING))
        savegamestrings[choice][0] = 0;
    saveCharIndex = strlen(savegamestrings[choice]);
}

//
// Selected from DOOM menu
//
void M_SaveGame(int choice)
{
    (void)choice;

    if (!usergame) {
        M_StartMessage(SAVEDEAD, NULL, false);
        return;
    }

    if (gamestate != GS_LEVEL)
        return;

    M_SetupNextMenu(&SaveDef);
    M_ReadSaveStrings();
}

//
//      M_QuickSave
//
// Longest string is the load prompt displaying a max-length save slot desc.
// Only include NUL once in the sizeof values.
char tempstring[sizeof QLPROMPT - (sizeof "%s" - 1) + (SAVESTRINGSIZE - 1)];

void M_QuickSaveResponse(int key)
{
    if (key == key_menu_confirm) {
        M_DoSave(quickSaveSlot);
        S_StartSound(NULL, sfx_swtchx);
    }
}

void M_QuickSave(void)
{
    if (!usergame) {
        S_StartSound(NULL, sfx_oof);
        return;
    }

    if (gamestate != GS_LEVEL)
        return;

    if (quickSaveSlot < 0) {
        M_StartControlPanel();
        M_ReadSaveStrings();
        M_SetupNextMenu(&SaveDef);
        quickSaveSlot = -2; // means to pick a slot now
        return;
    }
    snprintf(tempstring, sizeof tempstring, QSPROMPT,
             savegamestrings[quickSaveSlot]);
    M_StartMessage(tempstring, M_QuickSaveResponse, true);
}

//
// M_QuickLoad
//
void M_QuickLoadResponse(int key)
{
    if (key == key_menu_confirm) {
        M_LoadSelect(quickSaveSlot);
        S_StartSound(NULL, sfx_swtchx);
    }
}

void M_QuickLoad(void)
{
    if (netgame) {
        M_StartMessage(QLOADNET, NULL, false);
        return;
    }

    if (quickSaveSlot < 0) {
        M_StartMessage(QSAVESPOT, NULL, false);
        return;
    }
    snprintf(tempstring, sizeof tempstring, QLPROMPT,
             savegamestrings[quickSaveSlot]);
    M_StartMessage(tempstring, M_QuickLoadResponse, true);
}

//
// Read This Menus
// Had a "quick hack to fix romero bug"
//
void M_DrawReadThis1(void)
{
    char *lumpname = "CREDIT";
    int skullx = 330, skully = 175;

    inhelpscreens = true;

    // Different versions of Doom 1.9 work differently

    switch (gameversion) {
    case exe_doom_1_666:
    case exe_doom_1_7:
    case exe_doom_1_8:
    case exe_doom_1_9:
    case exe_hacx:

        if (gamemode == commercial) {
            // Doom 2

            lumpname = "HELP";

            skullx = 330;
            skully = 165;
        } else {
            // Doom 1
            // HELP2 is the first screen shown in Doom 1

            lumpname = "HELP2";

            skullx = 280;
            skully = 185;
        }
        break;

    case exe_ultimate:
    case exe_chex:

        // Ultimate Doom always displays "HELP1".

        // Chex Quest version also uses "HELP1", even though it is based
        // on Final Doom.

        lumpname = "HELP1";

        break;

    case exe_final:
    case exe_final2:

        // Final Doom always displays "HELP".

        lumpname = "HELP";

        break;

    default:
        I_Error("Unhandled game version");
        break;
    }

    V_DrawPatchDirect(0, 0, W_CacheLumpName(lumpname, PU_CACHE));

    ReadDef1.x = skullx;
    ReadDef1.y = skully;
}

//
// Read This Menus - optional second page.
//
void M_DrawReadThis2(void)
{
    inhelpscreens = true;

    // We only ever draw the second page if this is
    // gameversion == exe_doom_1_9 and gamemode == registered

    V_DrawPatchDirect(0, 0, W_CacheLumpName("HELP1", PU_CACHE));
}

//
// Change Sfx & Music volumes
//
void M_DrawSound(void)
{
    if (detached_ui)
        return;

    V_DrawPatchDirect(60, 38, W_CacheLumpName("M_SVOL", PU_CACHE));

    M_DrawThermo(SoundDef.x, SoundDef.y + LINEHEIGHT * (sfx_vol + 1), 16,
                 sfxVolume);

    M_DrawThermo(SoundDef.x, SoundDef.y + LINEHEIGHT * (music_vol + 1), 16,
                 musicVolume);
}

void M_Sound(int choice)
{
    (void)choice;

    M_SetupNextMenu(&SoundDef);
}

void M_SfxVol(int choice)
{
    switch (choice) {
    case 0:
        if (sfxVolume)
            sfxVolume--;
        break;
    case 1:
        if (sfxVolume < 15)
            sfxVolume++;
        break;
    }

    S_SetSfxVolume(sfxVolume * 8);
}

void M_MusicVol(int choice)
{
    switch (choice) {
    case 0:
        if (musicVolume)
            musicVolume--;
        break;
    case 1:
        if (musicVolume < 15)
            musicVolume++;
        break;
    }

    S_SetMusicVolume(musicVolume * 8);
}

//
// M_DrawMainMenu
//
void M_DrawMainMenu(void)
{
    V_DrawPatchDirect(94, 2, W_CacheLumpName("M_DOOM", PU_CACHE));
}

//
// M_NewGame
//
void M_DrawNewGame(void)
{
    if (detached_ui)
        return;

    V_DrawPatchDirect(96, 14, W_CacheLumpName("M_NEWG", PU_CACHE));
    V_DrawPatchDirect(54, 38, W_CacheLumpName("M_SKILL", PU_CACHE));
}

void M_NewGame(int choice)
{
    (void)choice;

    if (netgame && !demoplayback) {
        M_StartMessage(NEWGAME, NULL, false);
        return;
    }

    // Chex Quest disabled the episode select screen, as did Doom II.

    if (gamemode == commercial || gameversion == exe_chex)
        M_SetupNextMenu(&NewDef);
    else
        M_SetupNextMenu(&EpiDef);
}

//
//      M_Episode
//
int epi;

void M_DrawEpisode(void)
{
    if (detached_ui)
        return;

    V_DrawPatchDirect(54, 38, W_CacheLumpName("M_EPISOD", PU_CACHE));
}

void M_VerifyNightmare(int key)
{
    if (key != key_menu_confirm)
        return;

    G_DeferedInitNew(sk_nightmare, epi + 1, 1);
    M_ClearMenus();
}

void M_ChooseSkill(int choice)
{
    if (choice == nightmare) {
        M_StartMessage(NIGHTMARE, M_VerifyNightmare, true);
        return;
    }

    G_DeferedInitNew(choice, epi + 1, 1);
    M_ClearMenus();
}

void M_Episode(int choice)
{
    if ((gamemode == shareware) && choice) {
        M_StartMessage(SWSTRING, NULL, false);
        M_SetupNextMenu(&ReadDef1);
        return;
    }

    // Yet another hack...
    if ((gamemode == registered) && (choice > 2)) {
        fprintf(stderr, "M_Episode: 4th episode requires UltimateDOOM\n");
        choice = 0;
    }

    epi = choice;
    M_SetupNextMenu(&NewDef);
}

//
// M_Options
//
static char *detailNames[2] = {"M_GDHIGH", "M_GDLOW"};
static char *msgNames[2] = {"M_MSGOFF", "M_MSGON"};

void M_DrawOptions(void)
{
    if (detached_ui)
        return;

    V_DrawPatchDirect(108, 15, W_CacheLumpName("M_OPTTTL", PU_CACHE));

    V_DrawPatchDirect(OptionsDef.x + 175, OptionsDef.y + LINEHEIGHT * detail,
                      W_CacheLumpName(detailNames[detailLevel], PU_CACHE));

    V_DrawPatchDirect(OptionsDef.x + 120, OptionsDef.y + LINEHEIGHT * messages,
                      W_CacheLumpName(msgNames[showMessages], PU_CACHE));

    M_DrawThermo(OptionsDef.x, OptionsDef.y + LINEHEIGHT * (mousesens + 1), 10,
                 mouseSensitivity);

    M_DrawThermo(OptionsDef.x, OptionsDef.y + LINEHEIGHT * (scrnsize + 1), 9,
                 screenblocks - 3);
}

void M_Options(int choice)
{
    (void)choice;

    M_SetupNextMenu(&OptionsDef);
}

//
//      Toggle messages on/off
//
void M_ChangeMessages(int choice)
{
    (void)choice;

    showMessages = 1 - showMessages;

    if (!showMessages)
        players[consoleplayer].message = MSGOFF;
    else
        players[consoleplayer].message = MSGON;

    message_dontfuckwithme = true;
}

//
// M_EndGame
//
void M_EndGameResponse(int key)
{
    if (key != key_menu_confirm)
        return;

    currentMenu->lastOn = itemOn;
    M_ClearMenus();
    D_StartTitle();
}

void M_EndGame(int choice)
{
    (void)choice;

    if (!usergame) {
        S_StartSound(NULL, sfx_oof);
        return;
    }

    if (netgame) {
        M_StartMessage(NETEND, NULL, false);
        return;
    }

    M_StartMessage(ENDGAME, M_EndGameResponse, true);
}

//
// M_ReadThis
//
void M_ReadThis(int choice)
{
    (void)choice;

    M_SetupNextMenu(&ReadDef1);
}

void M_ReadThis2(int choice)
{
    (void)choice;

    // Doom 1.9 had two menus when playing Doom 1
    // All others had only one

    if (gameversion <= exe_doom_1_9 && gamemode != commercial) {
        choice = 0;
        M_SetupNextMenu(&ReadDef2);
    } else {
        // Close the menu

        M_FinishReadThis(0);
    }
}

void M_FinishReadThis(int choice)
{
    (void)choice;

    M_SetupNextMenu(&MainDef);
}

//
// M_QuitDOOM
//
int quitsounds[8] = {sfx_pldeth, sfx_dmpain, sfx_popain, sfx_slop,
                     sfx_telept, sfx_posit1, sfx_posit3, sfx_sgtatk};

int quitsounds2[8] = {sfx_vilact, sfx_getpow, sfx_boscub, sfx_slop,
                      sfx_skeswg, sfx_kntdth, sfx_bspact, sfx_sgtatk};

void M_QuitResponse(int key)
{
    if (key != key_menu_confirm)
        return;
    if (!netgame) {
        if (gamemode == commercial)
            S_StartSound(NULL, quitsounds2[(gametic >> 2) & 7]);
        else
            S_StartSound(NULL, quitsounds[(gametic >> 2) & 7]);
        I_WaitVBL(105);
    }
    I_Quit();
}

static char *M_SelectEndMessage(void)
{
    char **endmsg;

    if (logical_gamemission == doom) {
        // Doom 1

        endmsg = doom1_endmsg;
    } else {
        // Doom 2

        endmsg = doom2_endmsg;
    }

    return endmsg[gametic % NUM_QUITMESSAGES];
}

void M_QuitDOOM(int choice)
{
    (void)choice;

    snprintf(endstring, sizeof(endstring), "%s\n\n" DOSY, M_SelectEndMessage());

    M_StartMessage(endstring, M_QuitResponse, true);
}

void M_ChangeSensitivity(int choice)
{
    switch (choice) {
    case 0:
        if (mouseSensitivity)
            mouseSensitivity--;
        break;
    case 1:
        if (mouseSensitivity < 9)
            mouseSensitivity++;
        break;
    }
}

void M_ChangeDetail(int choice)
{
    (void)choice;

    detailLevel = 1 - detailLevel;

    R_SetViewSize(screenblocks, detailLevel);

    if (!detailLevel)
        players[consoleplayer].message = DETAILHI;
    else
        players[consoleplayer].message = DETAILLO;
}

void M_SizeDisplay(int choice)
{
    switch (choice) {
    case 0:
        if (screenblocks > 3)
            screenblocks--;
        break;
    case 1:
        if (screenblocks < 11)
            screenblocks++;
        break;
    }

    R_SetViewSize(screenblocks, detailLevel);
}

//
//      Menu Functions
//
void M_DrawThermo(int x, int y, int thermWidth, int thermDot)
{
    int xx;
    int i;

    xx = x;
    V_DrawPatchDirect(xx, y, W_CacheLumpName("M_THERML", PU_CACHE));
    xx += 8;
    for (i = 0; i < thermWidth; i++) {
        V_DrawPatchDirect(xx, y, W_CacheLumpName("M_THERMM", PU_CACHE));
        xx += 8;
    }
    V_DrawPatchDirect(xx, y, W_CacheLumpName("M_THERMR", PU_CACHE));

    V_DrawPatchDirect((x + 8) + thermDot * 8, y,
                      W_CacheLumpName("M_THERMO", PU_CACHE));
}

void M_DrawEmptyCell(menu_t *menu, int item)
{
    V_DrawPatchDirect(menu->x - 10, menu->y + item * LINEHEIGHT - 1,
                      W_CacheLumpName("M_CELL1", PU_CACHE));
}

void M_DrawSelCell(menu_t *menu, int item)
{
    V_DrawPatchDirect(menu->x - 10, menu->y + item * LINEHEIGHT - 1,
                      W_CacheLumpName("M_CELL2", PU_CACHE));
}

void M_StartMessage(char *string, void (*routine)(int), boolean input)
{
    messageLastMenuActive = menuactive;
    messageToPrint = 1;
    messageString = string;
    messageRoutine = routine;
    messageNeedsInput = input;
    menuactive = true;
    DG_OnMenuMessage(messageString);
    return;
}

void M_StopMessage(void)
{
    menuactive = messageLastMenuActive;
    messageToPrint = 0;
}

//
// Find string width from hu_font chars
//
int M_StringWidth(char *string)
{
    size_t i;
    int w = 0;
    int c;

    for (i = 0; i < strlen(string); i++) {
        c = toupper(string[i]) - HU_FONTSTART;
        if (c < 0 || c >= HU_FONTSIZE)
            w += 4;
        else
            w += SHORT(hu_font[c]->width);
    }

    return w;
}

//
//      Find string height from hu_font chars
//
int M_StringHeight(char *string)
{
    size_t i;
    int h;
    int height = SHORT(hu_font[0]->height);

    h = height;
    for (i = 0; i < strlen(string); i++)
        if (string[i] == '\n')
            h += height;

    return h;
}

//
//      Write a string using the hu_font
//
void M_WriteText(int x, int y, char *string)
{
    int w;
    char *ch;
    int c;
    int cx;
    int cy;

    ch = string;
    cx = x;
    cy = y;

    while (1) {
        c = *ch++;
        if (!c)
            break;
        if (c == '\n') {
            cx = x;
            cy += 12;
            continue;
        }

        c = toupper(c) - HU_FONTSTART;
        if (c < 0 || c >= HU_FONTSIZE) {
            cx += 4;
            continue;
        }

        w = SHORT(hu_font[c]->width);
        if (cx + w > SCREENWIDTH)
            break;
        V_DrawPatchDirect(cx, cy, hu_font[c]);
        cx += w;
    }
}

// These keys evaluate to a "null" key in Vanilla Doom that allows weird
// jumping in the menus. Preserve this behavior for accuracy.

static boolean IsNullKey(int key)
{
    return key == KEY_PAUSE || key == KEY_CAPSLOCK || key == KEY_SCRLCK
           || key == KEY_NUMLOCK;
}

//
// CONTROL PANEL
//

//
// M_Responder
//
boolean M_Responder(event_t *ev)
{
    int ch;
    int key;
    int i;
    static int joywait = 0;
    static int mousewait = 0;
    static int mousey = 0;
    static int lasty = 0;
    static int mousex = 0;
    static int lastx = 0;

    // In testcontrols mode, none of the function keys should do anything
    // - the only key is escape to quit.

    if (testcontrols) {
        if (ev->type == ev_quit
            || (ev->type == ev_keydown
                && (ev->data1 == key_menu_activate
                    || ev->data1 == key_menu_quit))) {
            I_Quit();
            return true;
        }

        return false;
    }

    // "close" button pressed on window?
    if (ev->type == ev_quit) {
        // First click on close button = bring up quit confirm message.
        // Second click on close button = confirm quit

        if (menuactive && messageToPrint && messageRoutine == M_QuitResponse) {
            M_QuitResponse(key_menu_confirm);
        } else {
            S_StartSound(NULL, sfx_swtchn);
            M_QuitDOOM(0);
        }

        return true;
    }

    // key is the key pressed, ch is the actual character typed

    ch = 0;
    key = -1;

    if (ev->type == ev_joystick && joywait < I_GetTime()) {
        if (ev->data3 < 0) {
            key = key_menu_up;
            joywait = I_GetTime() + 5;
        } else if (ev->data3 > 0) {
            key = key_menu_down;
            joywait = I_GetTime() + 5;
        }

        if (ev->data2 < 0) {
            key = key_menu_left;
            joywait = I_GetTime() + 2;
        } else if (ev->data2 > 0) {
            key = key_menu_right;
            joywait = I_GetTime() + 2;
        }

        if (ev->data1 & 1) {
            key = key_menu_forward;
            joywait = I_GetTime() + 5;
        }
        if (ev->data1 & 2) {
            key = key_menu_back;
            joywait = I_GetTime() + 5;
        }
        if (joybmenu >= 0 && (ev->data1 & (1 << joybmenu)) != 0) {
            key = key_menu_activate;
            joywait = I_GetTime() + 5;
        }
    } else {
        if (ev->type == ev_mouse && mousewait < I_GetTime()) {
            mousey += ev->data3;
            if (mousey < lasty - 30) {
                key = key_menu_down;
                mousewait = I_GetTime() + 5;
                mousey = lasty -= 30;
            } else if (mousey > lasty + 30) {
                key = key_menu_up;
                mousewait = I_GetTime() + 5;
                mousey = lasty += 30;
            }

            mousex += ev->data2;
            if (mousex < lastx - 30) {
                key = key_menu_left;
                mousewait = I_GetTime() + 5;
                mousex = lastx -= 30;
            } else if (mousex > lastx + 30) {
                key = key_menu_right;
                mousewait = I_GetTime() + 5;
                mousex = lastx += 30;
            }

            if (ev->data1 & 1) {
                key = key_menu_forward;
                mousewait = I_GetTime() + 15;
            }

            if (ev->data1 & 2) {
                key = key_menu_back;
                mousewait = I_GetTime() + 15;
            }
        } else {
            if (ev->type == ev_keydown) {
                key = ev->data1;
                ch = ev->data2;
            }
        }
    }

    if (key == -1)
        return false;

    // Save Game string input
    if (saveStringEnter) {
        switch (key) {
        case KEY_BACKSPACE:
            if (saveCharIndex > 0) {
                saveCharIndex--;
                savegamestrings[saveSlot][saveCharIndex] = 0;
            }
            break;

        case KEY_ESCAPE:
            saveStringEnter = 0;
            M_StringCopy(savegamestrings[saveSlot], saveOldString,
                         SAVESTRINGSIZE);
            break;

        case KEY_ENTER:
            saveStringEnter = 0;
            if (savegamestrings[saveSlot][0])
                M_DoSave(saveSlot);
            break;

        default:
            // This is complicated.
            // Vanilla has a bug where the shift key is ignored when entering
            // a savegame name. If vanilla_keyboard_mapping is on, we want
            // to emulate this bug by using 'data1'. But if it's turned off,
            // it implies the user doesn't care about Vanilla emulation: just
            // use the correct 'data2'.

            if (vanilla_keyboard_mapping) {
                ch = key;
            }

            ch = toupper(ch);

            if (ch != ' '
                && (ch - HU_FONTSTART < 0
                    || ch - HU_FONTSTART >= HU_FONTSIZE)) {
                break;
            }

            if (ch >= 32 && ch <= 127 && saveCharIndex < SAVESTRINGSIZE - 1
                && M_StringWidth(savegamestrings[saveSlot])
                       < (SAVESTRINGSIZE - 2) * 8) {
                savegamestrings[saveSlot][saveCharIndex++] = ch;
                savegamestrings[saveSlot][saveCharIndex] = 0;
            }
            break;
        }
        return true;
    }

    // Take care of any messages that need input
    if (messageToPrint) {
        if (messageNeedsInput) {
            if (key != ' ' && key != KEY_ESCAPE && key != key_menu_confirm
                && key != key_menu_abort) {
                return false;
            }
        }

        M_StopMessage();
        if (messageRoutine)
            messageRoutine(key);

        menuactive = false;
        S_StartSound(NULL, sfx_swtchx);
        return true;
    }

    if ((devparm && key == key_menu_help)
        || (key != 0 && key == key_menu_screenshot)) {
        G_ScreenShot();
        return true;
    }

    // F-Keys
    if (!menuactive) {
        if (key == key_menu_decscreen) // Screen size down
        {
            if (automapactive || chat_on)
                return false;
            M_SizeDisplay(0);
            S_StartSound(NULL, sfx_stnmov);
            return true;
        } else if (key == key_menu_incscreen) // Screen size up
        {
            if (automapactive || chat_on)
                return false;
            M_SizeDisplay(1);
            S_StartSound(NULL, sfx_stnmov);
            return true;
        } else if (key == key_menu_help) // Help key
        {
            M_StartControlPanel();

            if (gamemode == retail)
                currentMenu = &ReadDef2;
            else
                currentMenu = &ReadDef1;

            itemOn = 0;
            S_StartSound(NULL, sfx_swtchn);
            return true;
        } else if (key == key_menu_save) // Save
        {
            M_StartControlPanel();
            S_StartSound(NULL, sfx_swtchn);
            M_SaveGame(0);
            return true;
        } else if (key == key_menu_load) // Load
        {
            M_StartControlPanel();
            S_StartSound(NULL, sfx_swtchn);
            M_LoadGame(0);
            return true;
        } else if (key == key_menu_volume) // Sound Volume
        {
            M_StartControlPanel();
            currentMenu = &SoundDef;
            itemOn = sfx_vol;
            S_StartSound(NULL, sfx_swtchn);
            return true;
        } else if (key == key_menu_detail) // Detail toggle
        {
            M_ChangeDetail(0);
            S_StartSound(NULL, sfx_swtchn);
            return true;
        } else if (key == key_menu_qsave) // Quicksave
        {
            S_StartSound(NULL, sfx_swtchn);
            M_QuickSave();
            return true;
        } else if (key == key_menu_endgame) // End game
        {
            S_StartSound(NULL, sfx_swtchn);
            M_EndGame(0);
            return true;
        } else if (key == key_menu_messages) // Toggle messages
        {
            M_ChangeMessages(0);
            S_StartSound(NULL, sfx_swtchn);
            return true;
        } else if (key == key_menu_qload) // Quickload
        {
            S_StartSound(NULL, sfx_swtchn);
            M_QuickLoad();
            return true;
        } else if (key == key_menu_quit) // Quit DOOM
        {
            S_StartSound(NULL, sfx_swtchn);
            M_QuitDOOM(0);
            return true;
        } else if (key == key_menu_gamma) // gamma toggle
        {
            usegamma++;
            if (usegamma > 4)
                usegamma = 0;
            players[consoleplayer].message = gammamsg[usegamma];
            I_SetPalette(W_CacheLumpName("PLAYPAL", PU_CACHE));
            return true;
        }
    }

    // Pop-up menu?
    if (!menuactive) {
        if (key == key_menu_activate) {
            M_StartControlPanel();
            S_StartSound(NULL, sfx_swtchn);
            return true;
        }
        return false;
    }

    // Keys usable within menu

    if (key == key_menu_down) {
        // Move down to next item

        do {
            if (itemOn + 1 > currentMenu->numitems - 1)
                itemOn = 0;
            else
                itemOn++;
            S_StartSound(NULL, sfx_pstop);
        } while (currentMenu->menuitems[itemOn].status == -1);

        return true;
    } else if (key == key_menu_up) {
        // Move back up to previous item

        do {
            if (!itemOn)
                itemOn = currentMenu->numitems - 1;
            else
                itemOn--;
            S_StartSound(NULL, sfx_pstop);
        } while (currentMenu->menuitems[itemOn].status == -1);

        return true;
    } else if (key == key_menu_left) {
        // Slide slider left

        if (currentMenu->menuitems[itemOn].routine
            && currentMenu->menuitems[itemOn].status == 2) {
            S_StartSound(NULL, sfx_stnmov);
            currentMenu->menuitems[itemOn].routine(0);
        }
        return true;
    } else if (key == key_menu_right) {
        // Slide slider right

        if (currentMenu->menuitems[itemOn].routine
            && currentMenu->menuitems[itemOn].status == 2) {
            S_StartSound(NULL, sfx_stnmov);
            currentMenu->menuitems[itemOn].routine(1);
        }
        return true;
    } else if (key == key_menu_forward) {
        // Activate menu item

        if (currentMenu->menuitems[itemOn].routine
            && currentMenu->menuitems[itemOn].status) {
            currentMenu->lastOn = itemOn;
            if (currentMenu->menuitems[itemOn].status == 2) {
                currentMenu->menuitems[itemOn].routine(1); // right arrow
                S_StartSound(NULL, sfx_stnmov);
            } else {
                currentMenu->menuitems[itemOn].routine(itemOn);
                S_StartSound(NULL, sfx_pistol);
            }
        }
        return true;
    } else if (key == key_menu_activate) {
        // Deactivate menu

        currentMenu->lastOn = itemOn;
        M_ClearMenus();
        S_StartSound(NULL, sfx_swtchx);
        return true;
    } else if (key == key_menu_back) {
        // Go back to previous menu

        currentMenu->lastOn = itemOn;
        if (currentMenu->prevMenu) {
            currentMenu = currentMenu->prevMenu;
            itemOn = currentMenu->lastOn;
            S_StartSound(NULL, sfx_swtchn);
        }
        return true;
    }

    // Keyboard shortcut?
    // Vanilla Doom has a weird behavior where it jumps to the scroll bars
    // when the certain keys are pressed, so emulate this.

    else if (ch != 0 || IsNullKey(key)) {
        for (i = itemOn + 1; i < currentMenu->numitems; i++) {
            if (currentMenu->menuitems[i].alphaKey == ch) {
                itemOn = i;
                S_StartSound(NULL, sfx_pstop);
                return true;
            }
        }

        for (i = 0; i <= itemOn; i++) {
            if (currentMenu->menuitems[i].alphaKey == ch) {
                itemOn = i;
                S_StartSound(NULL, sfx_pstop);
                return true;
            }
        }
    }

    return false;
}

//
// M_StartControlPanel
//
void M_StartControlPanel(void)
{
    // intro might call this repeatedly
    if (menuactive)
        return;

    menuactive = 1;
    currentMenu = &MainDef;       // JDC
    itemOn = currentMenu->lastOn; // JDC
}

// Display OPL debug messages - hack for GENMIDI development.

#if 0
static void M_DrawOPLDev(void)
{
    extern void I_OPL_DevMessages(char *, size_t);
    char debug[1024];
    char *curr, *p;
    int line;

    //XXX I_OPL_DevMessages(debug, sizeof(debug));
    curr = debug;
    line = 0;

    for (;;)
    {
        p = strchr(curr, '\n');

        if (p != NULL)
        {
            *p = '\0';
        }

        M_WriteText(0, line * 8, curr);
        ++line;

        if (p == NULL)
        {
            break;
        }

        curr = p + 1;
    }
}
#endif

//
// M_Drawer
// Called after the view has been rendered,
// but before it has been blitted.
//
void M_Drawer(void)
{
    static short x;
    static short y;
    unsigned int i;
    unsigned int max;
    char string[80];
    char *name;
    int start;

    inhelpscreens = false;

    // Horiz. & Vertically center string and print it.
    if (messageToPrint) {
        if (detached_ui) {
            DG_DrawDetachedUI(DUI_MENU_MESSAGE);
            return;
        }

        start = 0;
        y = SCREENHEIGHT / 2 - M_StringHeight(messageString) / 2;
        while (messageString[start] != '\0') {
            int foundnewline = 0;

            for (i = 0; i < strlen(messageString + start); i++) {
                if (messageString[start + i] == '\n') {
                    M_StringCopy(string, messageString + start, sizeof(string));
                    if (i < sizeof(string)) {
                        string[i] = '\0';
                    }

                    foundnewline = 1;
                    start += i + 1;
                    break;
                }
            }

            if (!foundnewline) {
                M_StringCopy(string, messageString + start, sizeof(string));
                start += strlen(string);
            }

            x = SCREENWIDTH / 2 - M_StringWidth(string) / 2;
            M_WriteText(x, y, string);
            y += SHORT(hu_font[0]->height);
        }

        return;
    }

    // if (opldev) {
    //     M_DrawOPLDev();
    // }

    if (!menuactive)
        return;

    if (currentMenu->routine)
        currentMenu->routine(); // call Draw routine

    if (detached_ui) {
        duimenutype_t type;
        duimenuvars_t vars;
        const duimenuvars_t *varsp = NULL;

        if (currentMenu == &MainDef)
            type = DMENU_MAIN;
        else if (currentMenu == &EpiDef)
            type = DMENU_EPISODE;
        else if (currentMenu == &NewDef)
            type = DMENU_NEW_GAME;
        else if (currentMenu == &OptionsDef) {
            type = DMENU_OPTIONS;

            vars.options.low_detail = detailLevel;
            vars.options.messages_on = showMessages;
            vars.options.mouse_sensitivity = mouseSensitivity;
            vars.options.screen_size = screenblocks - 3;
            varsp = &vars;
        } else if (currentMenu == &ReadDef1)
            type = DMENU_README1;
        else if (currentMenu == &ReadDef2)
            type = DMENU_README2;
        else if (currentMenu == &SoundDef) {
            type = DMENU_SOUND;

            vars.sound.sfx_volume = sfxVolume;
            vars.sound.music_volume = musicVolume;
            varsp = &vars;
        } else if (currentMenu == &LoadDef || currentMenu == &SaveDef) {
            type = currentMenu == &LoadDef ? DMENU_LOAD_GAME : DMENU_SAVE_GAME;

            vars.load_or_save_game.save_slot_count = load_end;
            // Before C23, qualifiers on arrays apply just to the element type,
            // not the array type. Therefore "const char (*)[X]" and "char
            // (*)[X]" are not actually compatible types, so we need to cast.
            vars.load_or_save_game.save_slots =
                (const char (*)[SAVESTRINGSIZE])savegamestrings;
            vars.load_or_save_game.save_slot_edit_i =
                saveStringEnter ? saveSlot : -1;
            varsp = &vars;
        } else
            abort();

        DG_DrawMenu(type, currentMenu, itemOn, varsp);
        return;
    }

    // DRAW MENU
    x = currentMenu->x;
    y = currentMenu->y;
    max = currentMenu->numitems;

    for (i = 0; i < max; i++) {
        name = currentMenu->menuitems[i].name;

        if (name[0]) {
            V_DrawPatchDirect(x, y, W_CacheLumpName(name, PU_CACHE));
        }
        y += LINEHEIGHT;
    }

    // DRAW SKULL
    V_DrawPatchDirect(x + SKULLXOFF, currentMenu->y - 5 + itemOn * LINEHEIGHT,
                      W_CacheLumpName(skullName[whichSkull], PU_CACHE));
}

//
// M_ClearMenus
//
void M_ClearMenus(void)
{
    menuactive = 0;
    // if (!netgame && usergame && paused)
    //       sendpause = true;
}

//
// M_SetupNextMenu
//
void M_SetupNextMenu(menu_t *menudef)
{
    currentMenu = menudef;
    itemOn = currentMenu->lastOn;
}

//
// M_Ticker
//
void M_Ticker(void)
{
    if (--skullAnimCounter <= 0) {
        whichSkull ^= 1;
        skullAnimCounter = 8;
    }
}

//
// M_Init
//
void M_Init(void)
{
    currentMenu = &MainDef;
    menuactive = 0;
    itemOn = currentMenu->lastOn;
    whichSkull = 0;
    skullAnimCounter = 10;
    messageToPrint = 0;
    messageString = NULL;
    messageLastMenuActive = menuactive;
    quickSaveSlot = -1;

    // Here we could catch other version dependencies,
    //  like HELP1/2, and four episodes.

    switch (gamemode) {
    case commercial:
        // Commercial has no "read this" entry.
        MainMenu[readthis] = MainMenu[quitdoom];
        MainDef.numitems--;
        MainDef.y += 8;
        NewDef.prevMenu = &MainDef;
        break;
    case shareware:
        // Episode 2 and 3 are handled,
        //  branching to an ad screen.
    case registered:
        break;
    case retail:
        // We are fine.
    default:
        break;
    }

    // Versions of doom.exe before the Ultimate Doom release only had
    // three episodes; if we're emulating one of those then don't try
    // to show episode four. If we are, then do show episode four
    // (should crash if missing).
    if (gameversion < exe_ultimate) {
        EpiDef.numitems--;
    }

    // opldev = M_CheckParm("-opldev") > 0;
}
