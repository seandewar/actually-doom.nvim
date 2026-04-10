#ifdef FEATURE_SOUND

// These are TSF's defaults, but they're only defined in its implementation, and
// I'd like to use them outside it.
#define TSF_RENDER_EFFECTSAMPLEBLOCK 64
#define TSF_RENDER_SHORTBUFFERBLOCK 512

#include "../vendor/tsf.h"

#endif // FEATURE_SOUND
