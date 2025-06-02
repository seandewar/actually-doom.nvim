#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "d_items.h"
#include "d_player.h"
#include "doomgeneric.h"
#include "doomstat.h"
#include "i_system.h"
#include "i_video.h"
#include "m_argv.h"
#include "m_config.h"

#define LOG_PRE "[actually-doom] "

#define NS_PER_MS (1000 * 1000)
#define MS_PER_SEC 1000

// Sentinel value from CMSG_PRESS_KEY indicating that the key is actually a
// bitfield of currently pressed mouse buttons.
#define PK_MOUSEBUTTONS 0xff

// Message types are 8-bit values.
// Strings are 16-bit lengths followed by 8-bit data (not NUL-terminated).
//
// Integer values are sent as little-endian (network byte order considered
// cringe).
enum {
    // AMSG_FRAME,
    //   pixels: u24[res_x * res_y] (R8G8B8),
    //   detached_ui_bits: u8 (see duitype_t for meaning)
    AMSG_FRAME = 0,

    // AMSG_FRAME_SHM_READY (no payload)
    AMSG_FRAME_SHM_READY = 3,

    // AMSG_PLAYER_STATUS,
    //   health: i16,
    //   armor: i16,
    //   ready_ammo: i16,
    //   ammo: i16[NUMAMMO],
    //   max_ammo: i16[NUMAMMO],
    //   arms_bits: u8 (bits 0-5: slots 2-7),
    //   keys_bits: u8 (bit 0: blue, 1: yellow, 2: red)
    AMSG_PLAYER_STATUS = 5,

    // AMSG_GAME_MESSAGE, msg: string
    AMSG_GAME_MESSAGE = 4,

    // AMSG_MENU_MESSAGE, msg: string
    AMSG_MENU_MESSAGE = 6,

    // AMSG_AUTOMAP_TITLE, title: string
    AMSG_AUTOMAP_TITLE = 7,

    // AMSG_FINALE_TEXT text: string
    AMSG_FINALE_TEXT = 10,

    // AMSG_FRAME_MENU, type: u8, item_lumps: string[], selected_i: u8
    //   if type == DMENU_OPTIONS:
    //      toggle_bits: u8 (bit 0: low_detail, 1: messages_on)
    //      mouse_sensitivity: i8,
    //      screen_size: i8,
    //   else if type == DMENU_SOUND:
    //      sfx_volume: i8,
    //      music_volume: i8,
    //   else if type == DMENU_LOAD_GAME or DMENU_SAVE_GAME:
    //      save_slots: string[],
    //      save_slot_edit_i: i8,
    AMSG_FRAME_MENU = 8,

    // AMSG_FRAME_INTERMISSION, state: i8 (see stateenum_t)
    //   if state == StatCount:
    //      kills_percent: i32,
    //      items_percent: i32,
    //      secret_percent: i32,
    //      time_total_secs: i32,
    //      par_total_secs: i32,
    AMSG_FRAME_INTERMISSION = 9,

    // AMSG_FRAME_FINALE, text_len: u16
    AMSG_FRAME_FINALE = 11,

    // AMSG_SET_TITLE, title: string
    AMSG_SET_TITLE = 1,

    // AMSG_QUIT (no payload)
    AMSG_QUIT = 2,
};

// Incoming message types from the client. Same properties as above.
enum {
    // CMSG_WANT_FRAME (no payload)
    CMSG_WANT_FRAME = 0,

    // CMSG_SET_FRAME_SHM_NAME, name: string
    CMSG_SET_FRAME_SHM_NAME = 2,

    // CMSG_PRESS_KEY, key: u8, pressed: u8
    //   if pressed == PK_MOUSEBUTTONS: key is a bitfield of currently pressed
    //                                  mouse buttons (see event_t in d_event.h)
    //   else: key is a doomkey (see doomkeys.h), pressed is whether it's now
    //         down or released.
    CMSG_PRESS_KEY = 1,

    // CMSG_SET_CONFIG_VAR, name: string, value: string
    CMSG_SET_CONFIG_VAR = 3,
};

static const char *listen_sock_path;
static int listen_sock_fd = -1;
static int comm_sock_fd = -1;
static char frame_shm_name[NAME_MAX];
static int frame_shm_fd = -1;

// Enough for a whole frame and (a decent amount) of leeway.
#define COMM_SEND_BUF_CAP (2 * DOOMGENERIC_SCREEN_BUF_SIZE)

static struct {
    char data[COMM_SEND_BUF_CAP];
    size_t len;
} comm_send_buf;

static volatile sig_atomic_t interrupted;
static uint32_t clock_start_ms;
static byte enabled_dui_types;
static boolean comm_writing_msg;

#define COMM_WRITE_MSG(block)      \
    do {                           \
        assert(!comm_writing_msg); \
        comm_writing_msg = true;   \
        block;                     \
        comm_writing_msg = false;  \
    } while (0)

// Only used for received comms and buffered key state changes, so size doesn't
// need to be high. Keep this a power of 2 to make wrapping fast (compiler can
// optimize modulos into bit-ANDs).
#define RINGBUF_SIZE 512
// Max length one less than size, as start_i == end_i means empty, not full.
#define RINGBUF_CAP (RINGBUF_SIZE - 1)

typedef struct {
    char data[RINGBUF_SIZE];
    size_t start_i;
    size_t end_i;
} ringbuf_t;

static ringbuf_t comm_recv_buf;
static ringbuf_t key_buf;

typedef struct {
    int health;
    int armorpoints;
    int ready_ammo;
    int ammo[NUMAMMO];
    int maxammo[NUMAMMO];
    byte arms_bits;
    byte key_bits;
} player_status_t;

static void SigintHandler(int signum)
{
    (void)signum;
    // Generally try to handle SIGINTs with a graceful shutdown, but it may be
    // possible that DOOM code triggers syscalls without handling EINTR nicely..
    interrupted = true;
}

static boolean Ring_IsEmpty(const ringbuf_t *r)
{
    return r->start_i == r->end_i;
}

static boolean Ring_IsFull(const ringbuf_t *r)
{
    return (r->end_i + 1) % RINGBUF_SIZE == r->start_i;
}

static size_t Ring_GetLen(const ringbuf_t *r)
{
    return r->end_i >= r->start_i ? r->end_i - r->start_i
                                  : RINGBUF_SIZE - r->start_i + r->end_i;
}

static boolean Ring_Read8(ringbuf_t *r, uint8_t *v)
{
    if (Ring_IsEmpty(r))
        return false;

    *v = r->data[r->start_i++];
    r->start_i %= RINGBUF_SIZE;
    return true;
}

static boolean Ring_Read16(ringbuf_t *r, uint16_t *v)
{
    if (Ring_GetLen(r) < 2)
        return false;

    *v = r->data[r->start_i++];
    r->start_i %= RINGBUF_SIZE;
    *v |= r->data[r->start_i++] << 8;
    r->start_i %= RINGBUF_SIZE;
    return true;
}

static boolean Ring_ReadBytes(ringbuf_t *r, byte *p, size_t len)
{
    if (len == 0)
        return true;
    if (Ring_GetLen(r) < len)
        return false;

    size_t first_copy_len = r->start_i <= r->end_i ? r->end_i - r->start_i
                                                   : RINGBUF_SIZE - r->start_i;
    if (first_copy_len > len)
        first_copy_len = len;

    memcpy(p, r->data + r->start_i, first_copy_len);
    p += first_copy_len;
    r->start_i += first_copy_len;
    r->start_i %= RINGBUF_SIZE;
    len -= first_copy_len;

    if (len == 0)
        return true;

    memcpy(p, r->data + r->start_i, len);
    r->start_i += len;
    return true;
}

static boolean Ring_Write8(ringbuf_t *r, uint8_t v)
{
    if (Ring_IsFull(r))
        return false;

    r->data[r->end_i++] = v;
    r->end_i %= RINGBUF_SIZE;
    return true;
}

static void Comm_FlushSend(boolean closing)
{
    if (comm_send_buf.len == 0 || comm_sock_fd < 0)
        return;

    for (size_t sent = 0; sent < comm_send_buf.len;) {
        size_t send_len = comm_send_buf.len - sent;

        ssize_t ret = send(comm_sock_fd, comm_send_buf.data + sent, send_len,
                           closing ? MSG_DONTWAIT : 0);
        if (ret == -1 && !closing) {
            switch (errno) {
            case EINTR:
                if (interrupted)
                    I_Quit();
                break;

            case ECONNRESET:
            case EPIPE:
                fprintf(stderr,
                        LOG_PRE "Communications connection was closed; "
                                "quitting: %s\n",
                        strerror(errno));
                I_Quit(); // noreturn
                abort();

            default:
                I_Error(LOG_PRE "Failed to send %zu byte(s) to communications "
                                "socket: %s",
                        send_len, strerror(errno));
            }
        }

        if (ret > 0)
            sent += ret;
    }

    comm_send_buf.len = 0;
}

static void Comm_Write8(uint8_t v)
{
    assert(comm_writing_msg);
    if (comm_send_buf.len + 1 > COMM_SEND_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v;
}

static void Comm_Write16(uint16_t v)
{
    assert(comm_writing_msg);
    if (comm_send_buf.len + 2 > COMM_SEND_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 8) & 0xff;
}

static void Comm_Write32(uint32_t v)
{
    assert(comm_writing_msg);
    if (comm_send_buf.len + 4 > COMM_SEND_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 8) & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 16) & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 24) & 0xff;
}

static void Comm_WriteBytes(const byte *p, size_t len)
{
    assert(comm_writing_msg);

    while (true) {
        size_t free_len = COMM_SEND_BUF_CAP - comm_send_buf.len;
        size_t copy_len = len <= free_len ? len : free_len;

        memcpy(comm_send_buf.data + comm_send_buf.len, p, copy_len);
        comm_send_buf.len += copy_len;
        len -= copy_len;
        p += copy_len;

        if (len == 0)
            break;

        // If we got here, then the buffer's full.
        Comm_FlushSend(false);
    }
}

static void Comm_WriteString(const char *s)
{
    assert(comm_writing_msg);

    size_t len = strlen(s);
    if (len > UINT16_MAX) {
        fprintf(stderr,
                LOG_PRE "String of length %zu byte(s) too large for sending; "
                        "quitting\n",
                len);
        I_Quit();
    }

    Comm_Write16(len);
    Comm_WriteBytes((byte *)s, len);
}

static void UnlinkFrameShm(void);

static void Comm_HandleReceivedMsgs(void)
{
    // Crappy resumable state machine -- WHERE'S MY COROUTINES???
    static struct {
        unsigned stage;
        uint8_t msg_type;

        // In some cases we can store the last value of a message on the stack,
        // but storing them here is less error-prone (and allows us to omit
        // braces in the switch cases lol)
        union {
            struct {
                uint16_t len;
                char name[arrlen(frame_shm_name)];
            } set_frame_shm_name;

            struct {
                uint8_t key;
                uint8_t pressed;
            } press_key;

            struct {
                uint16_t len;
                char name[64];
                char value[128];
            } set_config_var;
        } v;
    } state = {0};

    while (true) {
        if (state.stage == 0) {
            if (!Ring_Read8(&comm_recv_buf, &state.msg_type))
                return;
            ++state.stage;
        }

        switch (state.msg_type) {
        case CMSG_WANT_FRAME:
            // No payload.
            screenvisible = true;
            break;

        case CMSG_SET_FRAME_SHM_NAME:
            switch (state.stage) {
            case 1:
                if (!Ring_Read16(&comm_recv_buf,
                                 &state.v.set_frame_shm_name.len))
                    return;

                if (state.v.set_frame_shm_name.len
                    >= arrlen(state.v.set_frame_shm_name.name)) {
                    I_Error(LOG_PRE "Requested frame data shared memory object "
                                    "name too long; max: %zu, size: %" PRIu16,
                            arrlen(state.v.set_frame_shm_name.name)
                                - 1, // Exclude NUL.
                            state.v.set_frame_shm_name.len);
                }
                ++state.stage;
                // fallthrough

            case 2:
                if (!Ring_ReadBytes(&comm_recv_buf,
                                    (byte *)state.v.set_frame_shm_name.name,
                                    state.v.set_frame_shm_name.len))
                    return;
                // Not strictly needed as we're not doing string operations on
                // this buffer, but still nice to do.
                state.v.set_frame_shm_name
                    .name[state.v.set_frame_shm_name.len] = '\0';

                UnlinkFrameShm();
                memcpy(frame_shm_name, state.v.set_frame_shm_name.name,
                       state.v.set_frame_shm_name.len);
                frame_shm_name[state.v.set_frame_shm_name.len] = '\0';
                printf(LOG_PRE "CMSG_SET_FRAME_SHM_NAME: name=\"%s\"\n",
                       frame_shm_name);
                break;

            default:
                abort();
            }
            break;

        case CMSG_PRESS_KEY:
            switch (state.stage) {
            case 1:
                if (!Ring_Read8(&comm_recv_buf, &state.v.press_key.key))
                    return;
                ++state.stage;
                // fallthrough

            case 2:
                if (!Ring_Read8(&comm_recv_buf, &state.v.press_key.pressed))
                    return;

                if (Ring_GetLen(&key_buf) + 2 <= RINGBUF_CAP) {
                    boolean ok = true;
                    ok = ok && Ring_Write8(&key_buf, state.v.press_key.key);
                    ok = ok && Ring_Write8(&key_buf, state.v.press_key.pressed);
                    assert(ok);
                    (void)ok;
                } else {
                    fprintf(stderr,
                            LOG_PRE "Warning: Key buffer full; dropping "
                                    "received key %" PRIu8 " (%s)\n",
                            state.v.press_key.key,
                            state.v.press_key.pressed ? "down" : "up");
                }
                break;

            default:
                abort();
            }
            break;

        case CMSG_SET_CONFIG_VAR:
            switch (state.stage) {
            case 1:
                if (!Ring_Read16(&comm_recv_buf, &state.v.set_config_var.len))
                    return;

                if (state.v.set_config_var.len
                    >= arrlen(state.v.set_config_var.name)) {
                    I_Error(LOG_PRE "Requested config variable name too long; "
                                    "max: %zu, size: %" PRIu16,
                            arrlen(state.v.set_config_var.name)
                                - 1, // Exclude NUL.
                            state.v.set_config_var.len);
                }
                ++state.stage;
                // fallthrough

            case 2:
                if (!Ring_ReadBytes(&comm_recv_buf,
                                    (byte *)state.v.set_config_var.name,
                                    state.v.set_config_var.len))
                    return;
                state.v.set_config_var.name[state.v.set_config_var.len] = '\0';
                ++state.stage;
                // fallthrough

            case 3:
                if (!Ring_Read16(&comm_recv_buf, &state.v.set_config_var.len))
                    return;

                if (state.v.set_config_var.len
                    >= arrlen(state.v.set_config_var.value)) {
                    I_Error(LOG_PRE "Requested config variable value too long; "
                                    "max: %zu, size: %" PRIu16,
                            arrlen(state.v.set_config_var.value)
                                - 1, // Exclude NUL.
                            state.v.set_config_var.len);
                }
                ++state.stage;
                // fallthrough

            case 4:
                if (!Ring_ReadBytes(&comm_recv_buf,
                                    (byte *)state.v.set_config_var.value,
                                    state.v.set_config_var.len))
                    return;
                state.v.set_config_var.value[state.v.set_config_var.len] = '\0';

                printf("CMSG_SET_CONFIG_VAR: name=\"%s\", value=\"%s\"\n",
                       state.v.set_config_var.name,
                       state.v.set_config_var.value);
                if (!M_SetVariable(state.v.set_config_var.name,
                                   state.v.set_config_var.value)) {
                    fprintf(stderr,
                            LOG_PRE "Warning: Failed to set config variable "
                                    "\"%s\"; maybe it isn't bound\n",
                            state.v.set_config_var.name);
                }
                break;

            default:
                abort();
            }
            break;

        default:
            fprintf(stderr,
                    LOG_PRE "Received unknown message type %" PRIu8
                            "; quitting\n",
                    state.msg_type);
            I_Quit();
        }

        // Finished previous message; prepare for a new one.
        state.stage = 0;
    }
}

static void Comm_Receive(void)
{
    while (true) {
        // Read into both halves of the ringbuf, in case it wraps. Be careful to
        // leave the last slot untouched, as size == cap - 1 is used to indicate
        // a full buffer (to disambiguate between start_i == end_i, which is
        // used to indicate an empty one).
        struct iovec iovs[2] = {
            {
                .iov_base = comm_recv_buf.data + comm_recv_buf.end_i,
                .iov_len = (comm_recv_buf.start_i > comm_recv_buf.end_i
                                ? comm_recv_buf.start_i - 1
                                : RINGBUF_SIZE - (comm_recv_buf.start_i == 0))
                           - comm_recv_buf.end_i,
            },
            {
                .iov_base = comm_recv_buf.data,
                .iov_len =
                    comm_recv_buf.start_i > 0
                            && comm_recv_buf.start_i < comm_recv_buf.end_i
                        ? comm_recv_buf.start_i - 1
                        : 0,
            },
        };

        ssize_t recv_ret = recvmsg(comm_sock_fd,
                                   &(struct msghdr){
                                       .msg_iov = iovs,
                                       .msg_iovlen = arrlen(iovs),
                                   },
                                   MSG_DONTWAIT);
        if (recv_ret == 0) {
            fprintf(stderr,
                    LOG_PRE "EOF while reading from communications socket; "
                            "quitting\n");
            I_Quit();
        } else if (recv_ret < 0) {
            switch (errno) {
#if EAGAIN != EWOULDBLOCK
            case EAGAIN:
#endif
            case EWOULDBLOCK:
                return; // No data.

            case EINTR:
                if (interrupted)
                    I_Quit();
                continue;
            }

            I_Error(LOG_PRE "Unexpected error while reading from "
                            "communications socket: %s",
                    strerror(errno));
        }
        comm_recv_buf.end_i += recv_ret;
        comm_recv_buf.end_i %= RINGBUF_SIZE;
        Comm_HandleReceivedMsgs();

        if (Ring_IsEmpty(&comm_recv_buf)) {
            // Empty; reposition at front to reduce disjoint accesses.
            comm_recv_buf.start_i = comm_recv_buf.end_i = 0;
        } else if (Ring_IsFull(&comm_recv_buf)) {
            fprintf(stderr, LOG_PRE "Communications read buffer overflow; "
                                    "quitting\n");
            I_Quit();
        }
    }
}

static void MaybeSendPlayerStatus(void);

int main(int argc, char **argv)
{
    // Set buffering to what's usually the default when run within a terminal.
    // Return values ignored; if this fails then whatever, though console output
    // in other applications (like Nvim) may look confusing.
    setvbuf(stdout, NULL, _IOLBF, 0); // Line buffering for stdout.
    setvbuf(stderr, NULL, _IONBF, 0); // No buffering for stderr.

    struct sigaction sa = {.sa_handler = SigintHandler};
    if (sigemptyset(&sa.sa_mask) == -1 || sigaction(SIGINT, &sa, NULL) == -1) {
        fprintf(stderr,
                LOG_PRE "Warning: Failed to install SIGINT handler: %s\n",
                strerror(errno));
    }

    doomgeneric_Create(argc, argv);
    while (true) {
        if (gamestate == GS_LEVEL)
            MaybeSendPlayerStatus();

        Comm_FlushSend(false);
        Comm_Receive();
        doomgeneric_Tick();
    }
}

void DG_WipeTick(void)
{
    // Screen wipes loop within D_Display, which means we should probably limit
    // this function to simple actions and defer messages that may change game
    // state and such.
    Comm_FlushSend(false);
    Comm_Receive();
}

static void CloseFrameShm(void)
{
    if (frame_shm_fd >= 0 && close(frame_shm_fd) == -1) {
        fprintf(
            stderr,
            LOG_PRE
            "Warning: Failed to close frame data shared memory object: %s\n",
            strerror(errno));
    }

    frame_shm_fd = -1;
}

static void UnlinkFrameShm(void)
{
#ifndef __ANDROID__
    if (frame_shm_name[0] != '\0' && shm_unlink(frame_shm_name) == -1
        && errno != ENOENT) { // May have been unlinked already by the client.
        fprintf(
            stderr,
            LOG_PRE
            "Warning: Failed to delete frame data shared memory object: %s\n",
            strerror(errno));
    }
#endif

    frame_shm_name[0] = '\0';
}

static void CloseListenSocket(void)
{
    if (listen_sock_fd >= 0 && close(listen_sock_fd) == -1) {
        fprintf(stderr,
                LOG_PRE "Warning: Failed to close listener socket: %s\n",
                strerror(errno));
    }

    // Technically susceptible to a TOC/TOU if the file was replaced with some
    // other file by a different process, as unlikely and dumb as that is...
    if (listen_sock_path && unlink(listen_sock_path) == -1) {
        fprintf(stderr,
                LOG_PRE "Warning: Failed to delete listener socket file: %s\n",
                strerror(errno));
    }

    listen_sock_fd = -1;
    listen_sock_path = NULL;
}

static void Cleanup(void)
{
    CloseListenSocket();

    if (comm_sock_fd >= 0) {
        if (!comm_writing_msg)
            COMM_WRITE_MSG(Comm_Write8(AMSG_QUIT));

        Comm_FlushSend(true);
        if (close(comm_sock_fd) == -1) {
            fprintf(stderr,
                    LOG_PRE
                    "Warning: Failed to close communications socket: %s\n",
                    strerror(errno));
        }
    }
    comm_sock_fd = -1;

    CloseFrameShm();
    UnlinkFrameShm();
}

static uint32_t GetClockMs(void)
{
    struct timespec tp;

    if (clock_gettime(
#ifdef __linux__
            CLOCK_MONOTONIC_RAW, // Unaffected by NTP adjustments.
#else
            CLOCK_MONOTONIC,
#endif
            &tp)
        == -1) {
        I_Error(LOG_PRE "Unexpected error while reading clock: %s",
                strerror(errno));
    }

    return (tp.tv_sec * MS_PER_SEC) + (tp.tv_nsec / NS_PER_MS);
}

void DG_Init(void)
{
    int p = M_CheckParmWithArgs("-listen", 1);
    if (p == 0)
        I_Error(LOG_PRE "\"-listen <socket_path>\" argument required");

    const char *sock_path = myargv[p + 1];
    size_t sock_path_len = strlen(sock_path);
    struct sockaddr_un listen_sock_addr = {.sun_family = AF_UNIX};

    if (sock_path_len + 1 > sizeof listen_sock_addr.sun_path) {
        I_Error(LOG_PRE "Listener socket path too long; max: %zu, size: %zu",
                (sizeof listen_sock_addr.sun_path) - 1, sock_path_len);
    }

    if ((listen_sock_fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        I_Error(LOG_PRE "Failed to create listener socket: %s",
                strerror(errno));
    }

    I_AtExit(Cleanup, true);
    // Bounds already checked above.
    strcpy(listen_sock_addr.sun_path, sock_path);

    if (bind(listen_sock_fd, (struct sockaddr *)&listen_sock_addr,
             sizeof listen_sock_addr)
        == -1) {
        I_Error(LOG_PRE "Failed to bind listener socket to path \"%s\": %s",
                sock_path, strerror(errno));
    }

    // Bound now, so this path has our socket file.
    listen_sock_path = sock_path;

    if (listen(listen_sock_fd, 2) != 0) {
        I_Error(LOG_PRE "Failed to listen on actually-doom socket: %s",
                strerror(errno));
    }

    printf(LOG_PRE "Listening for connections on socket \"%s\"...\n",
           sock_path);

    while ((comm_sock_fd = accept(listen_sock_fd, NULL, NULL)) == -1) {
        switch (errno) {
        case ECONNABORTED:
        case EPERM:
            fprintf(stderr,
                    LOG_PRE "Warning: Failed to accept a connection: %s\n",
                    strerror(errno));
            break;

        case EINTR:
            if (interrupted)
                I_Quit();
            break;

        default:
            I_Error(LOG_PRE "Unexpected error while listening for connections: "
                            "%s",
                    strerror(errno));
        }
    }

    struct ucred creds;
    if (getsockopt(comm_sock_fd, SOL_SOCKET, SO_PEERCRED, &creds,
                   &(socklen_t){sizeof creds})
        == 0) {
        printf(LOG_PRE "PID %jd has connected\n", (intmax_t)creds.pid);
    } else {
        printf(LOG_PRE "A client has connected\n");
    }

    CloseListenSocket();
    clock_start_ms = GetClockMs();

    // "AMSG_INIT": res_x: u16, res_y: u16
    COMM_WRITE_MSG({
        Comm_Write16(SCREENWIDTH);
        Comm_Write16(SCREENHEIGHT);
    });
}

static void MaybeSendPlayerStatus(void)
{
    static player_status_t last_status = {0};

    const player_t *p = &players[consoleplayer];

    player_status_t status;
    status.health = p->health;
    status.armorpoints = p->armorpoints;

    ammotype_t ready_ammo_type = weaponinfo[p->readyweapon].ammo;
    status.ready_ammo =
        ready_ammo_type == am_noammo ? -1 : p->ammo[ready_ammo_type];

    memcpy(status.ammo, p->ammo, sizeof p->ammo);
    memcpy(status.maxammo, p->maxammo, sizeof p->maxammo);

    status.arms_bits = 0;
    for (int i = 0; i < 6; ++i) // Slots numbered 2-7.
        status.arms_bits |= !!p->weaponowned[i + 1] << i;

    status.key_bits = 0;
    status.key_bits |= p->cards[it_bluecard] || p->cards[it_blueskull];
    status.key_bits |= (p->cards[it_yellowcard] || p->cards[it_yellowskull])
                       << 1;
    status.key_bits |= (p->cards[it_redcard] || p->cards[it_redskull]) << 2;

    if (status.health == last_status.health
        && status.armorpoints == last_status.armorpoints
        && status.ready_ammo == last_status.ready_ammo
        && memcmp(status.ammo, last_status.ammo, sizeof status.ammo) == 0
        && memcmp(status.maxammo, last_status.maxammo, sizeof status.maxammo)
               == 0
        && status.arms_bits == last_status.arms_bits
        && status.key_bits == last_status.key_bits) {
        return; // Unchanged.
    }

    COMM_WRITE_MSG({
        Comm_Write8(AMSG_PLAYER_STATUS);

        assert((int16_t)status.health == status.health);
        Comm_Write16(status.health);

        assert((int16_t)status.armorpoints == status.armorpoints);
        Comm_Write16(status.armorpoints);

        assert((int16_t)status.ready_ammo == status.ready_ammo);
        Comm_Write16(status.ready_ammo);

        for (int i = 0; i < NUMAMMO; ++i) {
            assert((int16_t)status.ammo[i] == status.ammo[i]);
            Comm_Write16(status.ammo[i]);
        }
        for (int i = 0; i < NUMAMMO; ++i) {
            assert((int16_t)status.maxammo[i] == status.maxammo[i]);
            Comm_Write16(status.maxammo[i]);
        }

        Comm_Write8(status.arms_bits);
        Comm_Write8(status.key_bits);
    });

    last_status = status;
}

void DG_DrawFrame(void)
{
    if (frame_shm_name[0] == '\0') {
        // Just send pixels over the socket with player status information.
        COMM_WRITE_MSG({
            Comm_Write8(AMSG_FRAME);
            Comm_WriteBytes(DG_ScreenBuffer, DOOMGENERIC_SCREEN_BUF_SIZE);
            Comm_Write8(enabled_dui_types);
        });

        goto end;
    }

#ifndef __ANDROID__
    // Old file descriptor should already be closed, but make sure anyway.
    CloseFrameShm();

    frame_shm_fd =
        shm_open(frame_shm_name, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (frame_shm_fd == -1) {
        I_Error(LOG_PRE "Failed to create frame data shared memory object: %s",
                strerror(errno));
    }

    while (ftruncate(frame_shm_fd, DOOMGENERIC_SCREEN_BUF_SIZE) == -1) {
        if (errno == EINTR) {
            if (interrupted)
                I_Quit();
            continue;
        }
        I_Error(LOG_PRE "Failed to set size of frame data shared memory: %s",
                strerror(errno));
    }

    void *p = mmap(NULL, DOOMGENERIC_SCREEN_BUF_SIZE, PROT_READ | PROT_WRITE,
                   MAP_SHARED, frame_shm_fd, 0);
    if (p == MAP_FAILED) {
        I_Error(LOG_PRE "Failed to map frame data shared memory: %s",
                strerror(errno));
    }
    // File descriptor need not be kept open after mapping.
    CloseFrameShm();

    memcpy(p, DG_ScreenBuffer, DOOMGENERIC_SCREEN_BUF_SIZE);

    if (msync(p, DOOMGENERIC_SCREEN_BUF_SIZE, MS_SYNC) == -1) {
        I_Error(LOG_PRE "Failed to synchronize frame data shared memory: %s",
                strerror(errno));
    }

    if (munmap(p, DOOMGENERIC_SCREEN_BUF_SIZE) == -1) {
        fprintf(stderr,
                LOG_PRE
                "Warning: Failed to unmap frame data shared memory: %s\n",
                strerror(errno));
    }

    COMM_WRITE_MSG(Comm_Write8(AMSG_FRAME_SHM_READY));
#else
    I_Error(
        LOG_PRE
        "Shared memory object support not implemented on Android; quitting");
#endif

end:
    screenvisible = false;
    enabled_dui_types = 0;
}

void DG_DrawDetachedUI(duitype_t ui)
{
    assert(ui < CHAR_BIT);
    enabled_dui_types |= 1 << ui;
}

void DG_DrawMenu(duimenutype_t type, const menu_t *menu, short selected_i,
                 const duimenuvars_t *vars)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_FRAME_MENU);

        // TODO: unsigned vs signed; will this trick work??
        assert((uint8_t)type == type);
        Comm_Write8(type);

        // TODO: unsigned vs signed; will this trick work??
        assert((uint16_t)menu->numitems == menu->numitems);
        Comm_Write16(menu->numitems);
        for (int i = 0; i < menu->numitems; i++)
            Comm_WriteString(menu->menuitems[i].name);

        // TODO: unsigned vs signed; will this trick work??
        assert((uint8_t)selected_i == selected_i);
        Comm_Write8(selected_i);

        switch (type) {
        case DMENU_OPTIONS: {
            byte toggle_bits = 0;
            toggle_bits |= vars->options.low_detail;
            toggle_bits |= vars->options.messages_on << 1;
            Comm_Write8(toggle_bits);

            assert((int8_t)vars->options.mouse_sensitivity
                   == vars->options.mouse_sensitivity);
            Comm_Write8(vars->options.mouse_sensitivity);

            assert((int8_t)vars->options.screen_size
                   == vars->options.screen_size);
            Comm_Write8(vars->options.screen_size);
        } break;

        case DMENU_SOUND:
            assert((int8_t)vars->sound.sfx_volume == vars->sound.sfx_volume);
            Comm_Write8(vars->sound.sfx_volume);

            assert((int8_t)vars->sound.music_volume
                   == vars->sound.music_volume);
            Comm_Write8(vars->sound.music_volume);
            break;

        case DMENU_LOAD_GAME:
        case DMENU_SAVE_GAME:
            // TODO: unsigned vs signed; will this trick work??
            assert((uint16_t)vars->load_or_save_game.save_slot_count
                   == vars->load_or_save_game.save_slot_count);
            Comm_Write16(vars->load_or_save_game.save_slot_count);

            for (int i = 0; i < vars->load_or_save_game.save_slot_count; ++i)
                Comm_WriteString(vars->load_or_save_game.save_slots[i]);

            assert((int8_t)vars->load_or_save_game.save_slot_edit_i
                   == vars->load_or_save_game.save_slot_edit_i);
            Comm_Write8(vars->load_or_save_game.save_slot_edit_i);
            break;

        default:
            assert(!vars);
        }
    });
}

void DG_DrawIntermission(stateenum_t state, const duiwistats_t *stats)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_FRAME_INTERMISSION);

        assert((int8_t)state == state);
        Comm_Write8(state);

        if (stats) {
            assert((int32_t)stats->kills == stats->kills);
            Comm_Write32(stats->kills);

            assert((int32_t)stats->items == stats->items);
            Comm_Write32(stats->items);

            assert((int32_t)stats->secret == stats->secret);
            Comm_Write32(stats->secret);

            assert((int32_t)stats->time == stats->time);
            Comm_Write32(stats->time);

            assert((int32_t)stats->par == stats->par);
            Comm_Write32(stats->par);
        }
    });
}

void DG_DrawFinaleText(int count)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_FRAME_FINALE);
        // TODO: unsigned vs signed; will this trick work??
        assert((uint16_t)count == count);
        Comm_Write16(count);
    });
}

void DG_OnGameMessage(const char *prefix, const char *msg)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_GAME_MESSAGE);
        size_t prefix_len = strlen(prefix);
        size_t msg_len = strlen(msg);
        Comm_Write16(prefix_len + msg_len);
        Comm_WriteBytes((byte *)prefix, prefix_len);
        Comm_WriteBytes((byte *)msg, msg_len);
    });
}

void DG_OnMenuMessage(const char *msg)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_MENU_MESSAGE);
        Comm_WriteString(msg);
    });
}

void DG_OnSetAutomapTitle(const char *title)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_AUTOMAP_TITLE);
        Comm_WriteString(title);
    });
}

void DG_OnSetFinaleText(finalestage_t stage, const char *text)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_FINALE_TEXT);
        assert((uint8_t)stage == stage);
        Comm_Write8(stage);
        Comm_WriteString(text);
    });
}

boolean DG_GetInput(input_t *input)
{
    // Initialize pressed to silence bogus GCC -Wmaybe-uninitialized; we always
    // push at least two bytes to the key_buf.
    uint8_t key, pressed = 0;
    if (!Ring_Read8(&key_buf, &key))
        return false;

    boolean ok = Ring_Read8(&key_buf, &pressed);
    assert(ok);
    (void)ok;

    if (pressed == PK_MOUSEBUTTONS) {
        // key is instead a bitfield of currently pressed mouse buttons.
        *input = (input_t){
            .type = IN_MOUSEBUTTONS,
            .value = key,
        };
        return true;
    }

    // DOOM expects alphabetic keys in lower-case. tolower is cringe and uses
    // locale information, so don't bother with it; we can do it quicker anyway.
    if (key >= 'A' && key <= 'Z')
        key = key - 'A' + 'a';

    *input = (input_t){
        .type = pressed ? IN_KEYDOWN : IN_KEYUP,
        .value = key,
    };
    return true;
}

void DG_SleepMs(uint32_t ms)
{
    struct timespec duration = {.tv_nsec = ms * NS_PER_MS};

    while (nanosleep(&duration, &duration) == -1) {
        if (errno == EINTR) {
            if (interrupted)
                I_Quit();
            // Could consider clock_nanosleep instead to avoid time drift from
            // repeated signal interrupts, but don't care.
            continue;
        }
        I_Error(LOG_PRE "Unexpected error while sleeping: %s", strerror(errno));
    }
}

uint32_t DG_GetTicksMs(void)
{
    return GetClockMs() - clock_start_ms;
}

void DG_SetWindowTitle(const char *title)
{
    COMM_WRITE_MSG({
        Comm_Write8(AMSG_SET_TITLE);
        Comm_WriteString(title);
    });
}
