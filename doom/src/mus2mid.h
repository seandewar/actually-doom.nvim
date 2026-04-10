#ifndef MUS2MID_H
#define MUS2MID_H

#ifdef FEATURE_SOUND

#include "doomtype.h"
#include "memio.h"

boolean mus2mid(MEMFILE *musinput, MEMFILE *midioutput);

#endif // FEATURE_SOUND

#endif // MUS2MID_H
