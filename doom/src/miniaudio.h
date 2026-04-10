#ifdef FEATURE_SOUND

// Disable unused features. Should improve build times and maybe other stuff.
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION

#include "../vendor/miniaudio.h"

#endif // FEATURE_SOUND
