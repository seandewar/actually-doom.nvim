// Sound support via miniaudio and TinySoundFont for actually-doom.

#ifdef FEATURE_SOUND

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "miniaudio.h"
#include "tml.h"
#include "tsf.h"

#include "i_sound.h"
#include "m_argv.h"
#include "m_misc.h"
#include "mus2mid.h"
#include "s_sound.h"
#include "sounds.h"
#include "w_wad.h"
#include "z_zone.h"

// NOTE: miniaudio uninits must be matched by prior inits *exactly*.
static ma_engine engine;
static int engine_init_count;

typedef struct {
    ma_data_source_base base;
    tml_message *first_msg; // Also used as music handles.
    tml_message *next_msg;
    float time_ms;
} ma_tml_data_source_t;

static tsf *music_soundfont;
static MEMFILE *music_memfile;
static ma_tml_data_source_t music_midi;
static ma_sound music_channel;

static boolean use_sfx_prefix;
static ma_sound *sfx_channels;
static boolean *sfx_channel_inited;
static ma_audio_buffer_ref *sfx_channel_bufs;

typedef struct {
    uint8_t *samples;
    unsigned count;
    unsigned rate;
} cached_samples_t;

static boolean I_Miniaudio_InitEngine(void)
{
    if (engine_init_count > 0)
        return true;

    printf("I_Miniaudio_InitEngine: %s\n", ma_version_string());

    ma_engine_config config = ma_engine_config_init();
    config.sampleRate = snd_samplerate;
    config.periodSizeInMilliseconds = snd_maxslicetime_ms;
    config.channels = 2;

    const ma_result result = ma_engine_init(&config, &engine);
    if (result != MA_SUCCESS) {
        fprintf(stderr,
                "I_Miniaudio_InitEngine: Failed to initialize ma_engine: %s\n",
                ma_result_description(result));
        return false;
    }

    ++engine_init_count;
    return true;
}

static void I_Miniaudio_UninitEngine(void)
{
    if (engine_init_count > 0) {
        ma_engine_uninit(&engine);
        --engine_init_count;
    }
}

static boolean I_Miniaudio_SoundInit(boolean use_sfx_prefix_)
{
    if (!I_Miniaudio_InitEngine())
        return false; // error already printed

    sfx_channel_bufs = Z_Malloc(snd_channels * sizeof sfx_channel_bufs[0],
                                PU_STATIC, NULL);
    for (int i = 0; i < snd_channels; ++i) {
        const ma_result result = ma_audio_buffer_ref_init(
                ma_format_u8, 1, NULL, 0, &sfx_channel_bufs[i]);
        (void)result;
        assert(result == MA_SUCCESS);
    }

    sfx_channels = Z_Malloc(snd_channels * sizeof sfx_channels[0], PU_STATIC,
                            NULL);
    sfx_channel_inited = Z_Malloc(snd_channels * sizeof sfx_channel_inited[0],
                                  PU_STATIC, NULL);
    for (int i = 0; i < snd_channels; ++i)
        sfx_channel_inited[i] = false;

    use_sfx_prefix = use_sfx_prefix_;
    return true;
}

static int I_Miniaudio_GetSfxLumpNum(sfxinfo_t *sfxinfo)
{
    if (sfxinfo->link != NULL)
        sfxinfo = sfxinfo->link;

    // Doom uses a DS prefix; Heretic and Hexen don't.
    char namebuf[16];
    M_snprintf(namebuf, sizeof namebuf, use_sfx_prefix ? "ds%s" : "%s",
               sfxinfo->name);

    return W_CheckNumForName(namebuf);
}

static void I_Miniaudio_SoundShutdown(void)
{
    for (int i = 0; i < snd_channels; ++i)
        if (sfx_channel_inited[i])
            ma_sound_uninit(&sfx_channels[i]);
    Z_Free(sfx_channels);
    Z_Free(sfx_channel_inited);

    for (int i = 0; i < snd_channels; ++i)
        ma_audio_buffer_ref_uninit(&sfx_channel_bufs[i]);
    Z_Free(sfx_channel_bufs);

    I_Miniaudio_UninitEngine();

    for (int i = 1; i < NUMSFX; ++i) {
        if (S_sfx[i].driver_data != NULL) {
            Z_Free(S_sfx[i].driver_data);
            S_sfx[i].driver_data = NULL;

            if (S_sfx[i].lumpnum < 0)
                S_sfx[i].lumpnum = I_Miniaudio_GetSfxLumpNum(&S_sfx[i]);
            W_ReleaseLumpNum(S_sfx[i].lumpnum);
        }
    }
}

static void I_Miniaudio_SoundUpdate(void)
{
    // Don't need to do anything here.
}

static cached_samples_t *I_Miniaudio_CacheSound(sfxinfo_t *sfxinfo)
{
    if (sfxinfo->driver_data != NULL)
        return sfxinfo->driver_data;

    uint8_t *const lump = W_CacheLumpNum(sfxinfo->lumpnum, PU_STATIC);
    const int lump_len = W_LumpLength(sfxinfo->lumpnum);

    // Sound lumps use the DMX format. First byte (format number) must be 3.
    // Header totals 8 bytes before padding. Padding totals 32 bytes.
    if (lump_len < 8 + 32 || lump[0] != 3) {
        fprintf(stderr, "I_Miniaudio_CacheSound: Lump \"%s\" has bad format\n",
                sfxinfo->name);

        W_ReleaseLumpNum(sfxinfo->lumpnum);
        return NULL;
    }

    const unsigned sample_rate = (unsigned)lump[2] | ((unsigned)lump[3] << 8);
    const unsigned sample_count_with_pad = (unsigned)lump[4]
        | ((unsigned)lump[5] << 8) | ((unsigned)lump[6] << 16)
        | ((unsigned)lump[7] << 24);

    if ((unsigned)lump_len - 8 < sample_count_with_pad) {
        fprintf(stderr,
                "I_Miniaudio_CacheSound: Lump \"%s\" has bad sample count - "
                "expected: %u, actual: %u\n",
                sfxinfo->name, sample_count_with_pad, (unsigned)lump_len - 8);

        W_ReleaseLumpNum(sfxinfo->lumpnum);
        return NULL;
    }

    // Don't release the lump; we reference its allocation for its samples.
    cached_samples_t *const cached = Z_Malloc(sizeof *cached, PU_STATIC, NULL);
    cached->samples = lump + 8 + 16;
    cached->count = sample_count_with_pad - 32;
    cached->rate = sample_rate;
    sfxinfo->driver_data = cached;
    return cached;
}

static boolean I_Miniaudio_SoundIsPlaying(int channel)
{
    return sfx_channel_inited[channel]
        && ma_sound_is_playing(&sfx_channels[channel]);
}

static void I_Miniaudio_UpdateSoundParams(int channel, int vol, int sep)
{
    if (sfx_channel_inited[channel]) {
        ma_sound_set_volume(&sfx_channels[channel], vol / 127.0f);
        ma_sound_set_pan(&sfx_channels[channel], (sep - NORM_SEP) / 127.0f);
    }
}

static int I_Miniaudio_StartSound(sfxinfo_t *sfxinfo, int channel, int vol,
                                  int sep)
{
    const cached_samples_t *const cached = I_Miniaudio_CacheSound(sfxinfo);
    if (cached == NULL)
        return -1;

    // Must reinit the ma_sound to get it to pick up the new sample rate.
    boolean *const sound_inited = &sfx_channel_inited[channel];
    ma_sound *const sound = &sfx_channels[channel];
    ma_audio_buffer_ref *const buf = &sfx_channel_bufs[channel];

    if (*sound_inited) {
        ma_sound_uninit(sound);
        *sound_inited = false;
    }

    ma_result result = ma_audio_buffer_ref_set_data(buf, cached->samples,
                                                    cached->count);
    assert(result == MA_SUCCESS);
    buf->sampleRate = cached->rate; // No way to change this otherwise.

    // Pitching isn't used, despite sfxinfo having it as a field, as old DOOM
    // would randomly vary it; DG seems to have stripped that code out. Can
    // re-implement it, but for now just disable miniaudio's support for
    // pitching as an optimization. We also don't use 3D spatialization (DOOM
    // instead does stereo panning), so disable that too.
    result = ma_sound_init_from_data_source(&engine, buf,
            MA_SOUND_FLAG_NO_PITCH | MA_SOUND_FLAG_NO_SPATIALIZATION, NULL,
            sound);
    if (result != MA_SUCCESS) {
        fprintf(stderr,
                "I_Miniaudio_StartSound: Failed to initialize ma_sound for "
                "channel %d, lump \"%s\": %s\n",
                channel, sfxinfo->name, ma_result_description(result));
        return -1;
    }

    *sound_inited = true;
    result = ma_sound_start(sound);
    assert(result == MA_SUCCESS);

    I_Miniaudio_UpdateSoundParams(channel, vol, sep);
    return channel;
}

static void I_Miniaudio_StopSound(int channel)
{
    if (sfx_channel_inited[channel])
        ma_sound_stop(&sfx_channels[channel]);
}

static void I_Miniaudio_CacheSounds(sfxinfo_t *sounds, int num_sounds)
{
    printf("I_Miniaudio_CacheSounds: Pre-caching %d sound(s)...\n", num_sounds);

    for (int i = 0; i < num_sounds; ++i) {
        sfxinfo_t *const sfxinfo = &sounds[i];
        sfxinfo->lumpnum = I_Miniaudio_GetSfxLumpNum(sfxinfo);
        if (sfxinfo->lumpnum >= 0)
            I_Miniaudio_CacheSound(sfxinfo);
    }
}

static snddevice_t sound_devices[] = {
    SNDDEVICE_SB,
    SNDDEVICE_PAS,
    SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS,
    SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module = {
    .sound_devices = sound_devices,
    .num_sound_devices = arrlen(sound_devices),
    .Init = I_Miniaudio_SoundInit,
    .Shutdown = I_Miniaudio_SoundShutdown,
    .GetSfxLumpNum = I_Miniaudio_GetSfxLumpNum,
    .Update = I_Miniaudio_SoundUpdate,
    .UpdateSoundParams = I_Miniaudio_UpdateSoundParams,
    .StartSound = I_Miniaudio_StartSound,
    .StopSound = I_Miniaudio_StopSound,
    .SoundIsPlaying = I_Miniaudio_SoundIsPlaying,
    .CacheSounds = I_Miniaudio_CacheSounds,
};

static ma_result ma_tml_data_source_read(ma_data_source *src_, void *frames_out,
        ma_uint64 frame_count, ma_uint64 *frames_read)
{
    ma_tml_data_source_t *const src = src_;
    float *out = frames_out;
    ma_uint64 read = 0;

    while (frame_count > 0) {
        ma_uint64 render_count = TSF_RENDER_EFFECTSAMPLEBLOCK;
        if (render_count > frame_count)
            render_count = frame_count;

        const float render_ms = (1000.0f * render_count) / snd_samplerate;

        while (src->next_msg != NULL && src->time_ms >= src->next_msg->time) {
            const tml_message *const msg = src->next_msg;

            switch (msg->type) {
            case TML_PROGRAM_CHANGE:
                tsf_channel_set_presetnumber(music_soundfont, msg->channel,
                                             msg->program, msg->channel == 9);
                break;
            case TML_NOTE_ON:
                tsf_channel_note_on(music_soundfont, msg->channel, msg->key,
                                    msg->velocity / 127.0f);
                break;
            case TML_NOTE_OFF:
                tsf_channel_note_off(music_soundfont, msg->channel, msg->key);
                break;
            case TML_PITCH_BEND:
                tsf_channel_set_pitchwheel(music_soundfont, msg->channel,
                                           msg->pitch_bend);
                break;
            case TML_CONTROL_CHANGE:
                tsf_channel_midi_control(music_soundfont, msg->channel,
                                         msg->control, msg->control_value);
                break;
            }

            src->next_msg = msg->next;
        }

        tsf_render_float(music_soundfont, out, render_count, 0);
        out += 2 * render_count; // 2 channels
        read += render_count;
        frame_count -= render_count;
        src->time_ms += render_ms;
    }

    if (frames_read)
        *frames_read = read;

    // If there's no more messages, consider that the end. Don't wait for voices
    // to go inactive.
    return src->next_msg != NULL ? MA_SUCCESS : MA_AT_END;
}

static ma_result ma_tml_data_source_seek(ma_data_source* src_,
                                         ma_uint64 frame_index)
{
    // Only seeking to the start is implemented, so looping works.
    // Could implement other seeking if needed, but I don't think it is.
    if (frame_index > 0) {
        fprintf(stderr, "ma_tml_data_source_seek: Unsupported seek to frame "
                        "index %" PRIu64 "\n", (uint64_t)frame_index);
        return MA_NOT_IMPLEMENTED;
    }

    tsf_reset(music_soundfont);

    ma_tml_data_source_t *const src = src_;
    src->next_msg = src->first_msg;
    src->time_ms = 0;

    return MA_SUCCESS;
}

static ma_result ma_tml_data_source_get_data_format(ma_data_source *src,
        ma_format *format, ma_uint32 *channels, ma_uint32 *sample_rate,
        ma_channel *channel_map, size_t channel_map_cap)
{
    (void)src;

    *format = ma_format_f32;
    *channels = 2;
    *sample_rate = snd_samplerate;
    ma_channel_map_init_standard(ma_standard_channel_map_default, channel_map,
                                 channel_map_cap, 2);

    return MA_SUCCESS;
}

static ma_data_source_vtable ma_tml_data_source_vtable = {
    .onRead = ma_tml_data_source_read,
    .onSeek = ma_tml_data_source_seek,
    .onGetDataFormat = ma_tml_data_source_get_data_format,
};

static boolean I_Miniaudio_MusicInit(void)
{
    const int p = M_CheckParmWithArgs("-soundfont", 1);
    if (p == 0) {
        fprintf(stderr, "I_Miniaudio_MusicInit: \"-soundfont\" argument "
                        "required\n");
        return false;
    }

    const char *const soundfont_fname = myargv[p + 1];
    music_soundfont = tsf_load_filename(soundfont_fname);
    if (music_soundfont == NULL) {
        fprintf(stderr,
                "I_Miniaudio_MusicInit: Failed to load SoundFont \"%s\"\n",
                soundfont_fname);
        return false;
    }

    // Set special channel 9 to use percussion bank 128, if available.
    tsf_channel_set_bank_preset(music_soundfont, 9, 128, 0);

    tsf_set_output(music_soundfont, TSF_STEREO_INTERLEAVED, snd_samplerate,
                   0.0f);

    if (!I_Miniaudio_InitEngine()) {
        tsf_close(music_soundfont);
        return false; // error already printed
    }

    ma_data_source_config config = ma_data_source_config_init();
    config.vtable = &ma_tml_data_source_vtable;

    ma_result result = ma_data_source_init(&config, &music_midi.base);
    assert(result == MA_SUCCESS);

    result = ma_sound_init_from_data_source(&engine, &music_midi,
            MA_SOUND_FLAG_NO_PITCH | MA_SOUND_FLAG_NO_SPATIALIZATION, NULL,
            &music_channel);
    if (result != MA_SUCCESS) {
        fprintf(stderr,
                "I_Miniaudio_MusicInit: Failed to initialize ma_sound: %s\n",
                ma_result_description(result));

        ma_data_source_uninit(&music_midi.base);
        tsf_close(music_soundfont);
        I_Miniaudio_UninitEngine();
        return false;
    }

    return true;
}

static void I_Miniaudio_StopSong(void)
{
    music_midi.next_msg = NULL;
    tsf_reset(music_soundfont);
    ma_sound_stop(&music_channel);
}

static void I_Miniaudio_UnRegisterSong(void *handle)
{
    if (handle == NULL || handle != music_midi.first_msg)
        return;

    I_Miniaudio_StopSong();
    tml_free(music_midi.first_msg);
    music_midi.first_msg = NULL;

    if (music_memfile != NULL) {
        mem_fclose(music_memfile);
        music_memfile = NULL;
    }
}

static void I_Miniaudio_MusicShutdown(void)
{
    if (music_midi.first_msg != NULL)
        I_Miniaudio_UnRegisterSong(music_midi.first_msg);

    ma_sound_uninit(&music_channel);
    ma_data_source_uninit(&music_midi.base);
    tsf_close(music_soundfont);
    I_Miniaudio_UninitEngine();
}

static void I_Miniaudio_SetMusicVolume(int vol)
{
    ma_sound_set_volume(&music_channel, vol / 127.0f);
}

static void I_Miniaudio_PauseMusic(void)
{
    ma_sound_stop(&music_channel);
}

static void I_Miniaudio_ResumeMusic(void)
{
    if (music_midi.first_msg != NULL)
        ma_sound_start(&music_channel);
}

static void *I_Miniaudio_RegisterSong(void *data, int len)
{
    // We only support one registered song at a time, which should be enough.
    assert(music_midi.first_msg == NULL);

    // Check MIDI header. If invalid, it's probably a MUS that needs converting.
    if (len <= 4 || memcmp(data, "MThd", 4) != 0) {
        MEMFILE *const in = mem_fopen_read(data, len);
        MEMFILE *const out = mem_fopen_write();

        if (mus2mid(in, out)) { // NOTE: true means failure. Boooo!
            fprintf(stderr,
                    "I_Miniaudio_RegisterSong: mus2mid failed for song with "
                    "length %d\n", len);

            mem_fclose(in);
            mem_fclose(out);
            return NULL;
        }

        mem_fclose(in);
        music_memfile = out; // Hang on to the allocation.

        size_t out_len;
        mem_get_buf(out, &data, &out_len);
        assert(out_len <= INT_MAX);
        len = out_len;
    }

    music_midi.first_msg = tml_load_memory(data, len);
    if (music_midi.first_msg == NULL) {
        fprintf(stderr,
                "I_Miniaudio_RegisterSong: tml_load_memory failed for song "
                "with length %d\n", len);

        if (music_memfile != NULL) {
            mem_fclose(music_memfile);
            music_memfile = NULL;
        }
        return NULL;
    }

    // data remains allocated while registered.
    return music_midi.first_msg;
}

static void I_Miniaudio_PlaySong(void *handle, boolean looping)
{
    assert(handle != NULL && handle == music_midi.first_msg);
    (void)handle;

    music_midi.next_msg = music_midi.first_msg;
    music_midi.time_ms = 0.0f;
    ma_sound_set_looping(&music_channel, looping);
    ma_sound_start(&music_channel);
}

static boolean I_Miniaudio_MusicIsPlaying(void)
{
    return ma_sound_is_playing(&music_channel);
}

static void I_Miniaudio_MusicPoll(void)
{
    // Don't need to do anything here.
}

static snddevice_t music_devices[] = {
    SNDDEVICE_PAS,
    SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS,
    SNDDEVICE_GENMIDI,
    SNDDEVICE_AWE32,
};

music_module_t DG_music_module = {
    .sound_devices = music_devices,
    .num_sound_devices = arrlen(music_devices),
    .Init = I_Miniaudio_MusicInit,
    .Shutdown = I_Miniaudio_MusicShutdown,
    .SetMusicVolume = I_Miniaudio_SetMusicVolume,
    .PauseMusic = I_Miniaudio_PauseMusic,
    .ResumeMusic = I_Miniaudio_ResumeMusic,
    .RegisterSong = I_Miniaudio_RegisterSong,
    .UnRegisterSong = I_Miniaudio_UnRegisterSong,
    .PlaySong = I_Miniaudio_PlaySong,
    .StopSong = I_Miniaudio_StopSong,
    .MusicIsPlaying = I_Miniaudio_MusicIsPlaying,
    .Poll = I_Miniaudio_MusicPoll,
};

#endif // FEATURE_SOUND
