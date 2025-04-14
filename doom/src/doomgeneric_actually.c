#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "doomgeneric.h"
#include "i_system.h"
#include "m_argv.h"

// Bump after a breaking change to the messaging protocol.
#define AMSG_PROTO_VERSION 0

#define LOG_PRE "[actually-doom] "

#define NS_PER_MS (1000 * 1000)
#define MS_PER_SEC 1000

// Message types are 8-bit values.
// Strings are 16-bit lengths followed by 8-bit data (not NUL-terminated).
//
// Integer values are sent as little-endian (network byte order considered
// cringe).
enum {
    // AMSG_FRAME, pixels: u24[resx * resy] (BGR)
    AMSG_FRAME = 0,

    // AMSG_SET_TITLE, title: string
    AMSG_SET_TITLE = 1,
};

// Incoming message types from the client. Same properties as above.
enum {
    // CMSG_WANT_FRAME (no payload)
    CMSG_WANT_FRAME = 0,

    // CMSG_PRESS_KEY, doomkey: u8, pressed: bool
    CMSG_PRESS_KEY = 1,
};

static const char *listen_sock_path;
static int listen_sock_fd = -1;
static int comm_sock_fd = -1;

// Enough for a whole frame and (a decent amount) of leeway.
#define COMM_WRITE_BUF_CAP (2 * DOOMGENERIC_RESX * DOOMGENERIC_RESY * 3)

static struct {
    char data[COMM_WRITE_BUF_CAP];
    size_t len;
} comm_send_buf;

static uint32_t clock_start_ms;
static volatile sig_atomic_t interrupted;

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
static boolean client_wants_frame;

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
                I_Error(LOG_PRE "Failed to send %zu byte(s) to "
                                "communications socket: %s",
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
    if (comm_send_buf.len == COMM_WRITE_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v;
}

static void Comm_Write16(uint16_t v)
{
    if (comm_send_buf.len + 2 > COMM_WRITE_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 8) & 0xff;
}

static void Comm_Write24(uint32_t v)
{
    if (comm_send_buf.len + 3 > COMM_WRITE_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 8) & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 16) & 0xff;
}

static void Comm_Write32(uint32_t v)
{
    if (comm_send_buf.len + 4 > COMM_WRITE_BUF_CAP)
        Comm_FlushSend(false);

    comm_send_buf.data[comm_send_buf.len++] = v & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 8) & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 16) & 0xff;
    comm_send_buf.data[comm_send_buf.len++] = (v >> 24) & 0xff;
}

static void Comm_WriteBytes(const char *p, size_t len)
{
    while (true) {
        size_t free_len = COMM_WRITE_BUF_CAP - comm_send_buf.len;
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
    size_t len = strlen(s);
    if (len > UINT16_MAX) {
        fprintf(stderr,
                LOG_PRE "String of length %zu byte(s) too large for sending; "
                        "quitting\n",
                len);
        I_Quit();
    }

    Comm_Write16(len);
    Comm_WriteBytes(s, len);
}

static void Comm_HandleReceivedMsgs(void)
{
    // Crappy resumable state machine -- WHERE'S MY COROUTINES???
    static struct {
        unsigned stage;
        uint8_t msg_type;
        // Technically we can store the last value of a message on the stack,
        // but storing them here is less error-prone (and allows us to omit
        // braces in the switch cases lol)
        union {
            struct {
                uint8_t doomkey;
                uint8_t pressed;
            } press_key;
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
            client_wants_frame = true;
            break;

        case CMSG_PRESS_KEY:
            switch (state.stage) {
            case 1:
                if (!Ring_Read8(&comm_recv_buf, &state.v.press_key.doomkey))
                    return;
                ++state.stage;
                // fallthrough

            case 2:
                if (!Ring_Read8(&comm_recv_buf, &state.v.press_key.pressed))
                    return;

                if (Ring_GetLen(&key_buf) + 2 <= RINGBUF_CAP) {
                    boolean ok = true;
                    ok = ok && Ring_Write8(&key_buf, state.v.press_key.doomkey);
                    ok = ok && Ring_Write8(&key_buf, state.v.press_key.pressed);
                    assert(ok);
                    (void)ok;
                } else {
                    fprintf(stderr,
                            LOG_PRE "Warning: Key buffer full; dropping "
                                    "received key %" PRIu8 " (%s)\n",
                            state.v.press_key.doomkey,
                            state.v.press_key.pressed ? "down" : "up");
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
    while (!interrupted) {
        Comm_FlushSend(false);
        Comm_Receive();
        doomgeneric_Tick();
    }

    I_Quit();
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

static void CloseSockets(void)
{
    CloseListenSocket();

    Comm_FlushSend(true);
    if (comm_sock_fd >= 0 && close(comm_sock_fd) == -1) {
        fprintf(stderr,
                LOG_PRE "Warning: Failed to close communications socket: %s\n",
                strerror(errno));
    }

    comm_sock_fd = -1;
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

    I_AtExit(CloseSockets, true);
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
            I_Error(LOG_PRE "Unexpected error while listening for "
                            "connections: %s",
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

    // "AMSG_INIT": proto_version: u32, resx: u16, resy: u16
    Comm_Write32(AMSG_PROTO_VERSION);
    Comm_Write16(DOOMGENERIC_RESX);
    Comm_Write16(DOOMGENERIC_RESY);
}

void DG_DrawFrame(void)
{
    if (!client_wants_frame)
        return;

    Comm_Write8(AMSG_FRAME);
    for (size_t i = 0; i < DOOMGENERIC_RESX * DOOMGENERIC_RESY; ++i)
        Comm_Write24(DG_ScreenBuffer[i]);

    client_wants_frame = false;
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    uint8_t k, p;
    if (!Ring_Read8(&key_buf, &k))
        return 0;

    boolean ok = Ring_Read8(&key_buf, &p);
    assert(ok);
    (void)ok;

    // DOOM expects alphabetic keys in lower-case. tolower is cringe and uses
    // locale information, so don't bother with it; we can do it quicker anyway.
    if (k >= 'A' && k <= 'Z')
        k = k - 'A' + 'a';

    *key = k;
    *pressed = p;
    return 1;
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
    Comm_Write8(AMSG_SET_TITLE);
    Comm_WriteString(title);
}
