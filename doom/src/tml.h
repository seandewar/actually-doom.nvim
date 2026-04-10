#ifdef FEATURE_SOUND

#define TML_ERROR(msg) fprintf(stderr, "TinyMidiLoader error: %s\n", msg);
#define TML_WARN(msg)  fprintf(stderr, "TinyMidiLoader warning: %s\n", msg);

#include "../vendor/tml.h"

#endif // FEATURE_SOUND
