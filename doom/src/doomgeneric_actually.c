#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "doomgeneric.h"
#include "i_system.h"
#include "m_argv.h"

#define NS_PER_MS (1000 * 1000)

// Message types are 8-bit values.
// Strings are 16-bit lengths followed by 8-bit data (not NUL-terminated).
//
// Integer values are sent as little-endian (network byte order considered
// cringe).
enum {
    // AMSG_INIT, resx: u16, resy: u16
    AMSG_INIT = 0,

    // #ifdef CMAP256: AMSG_FRAME, pixels: u32[resx * resy]
    // #else:          AMSG_FRAME, pixels:  u8[resx * resy]
    AMSG_FRAME = 1,

    // AMSG_SET_TITLE, title: String
    AMSG_SET_TITLE = 2,
};

static const char *listen_sock_path;
static int listen_sock_fd = -1;
static int comm_sock_fd = -1;

#define COMM_BUF_CAP (2 * DOOMGENERIC_RESX * DOOMGENERIC_RESY * sizeof(pixel_t))

static struct {
    char data[COMM_BUF_CAP];
    size_t len;
} comm_buf;

static uint32_t clock_start_ms;
static volatile sig_atomic_t interrupted;

static void SigintHandler(int signum)
{
    (void)signum;
    interrupted = true;
}

static void CommFlush(void)
{
    if (comm_buf.len == 0 || comm_sock_fd < 0)
        return;

    for (size_t sent = 0; sent < comm_buf.len || !interrupted;) {
        size_t send_len = comm_buf.len - sent;

        ssize_t ret = send(comm_sock_fd, comm_buf.data + sent, send_len, 0);
        if (ret == -1 && errno != EINTR) {
            I_Error("[actually-doom.nvim] Failed to send %zu byte(s) to "
                    "communications socket: %s",
                    send_len, strerror(errno));
        }

        if (ret > 0)
            sent += ret;
    }

    comm_buf.len = 0;
}

static void CommWrite8(uint8_t v)
{
    assert(COMM_BUF_CAP >= 1);
    if (comm_buf.len == COMM_BUF_CAP)
        CommFlush();

    comm_buf.data[comm_buf.len++] = v;
}

static void CommWrite16(uint16_t v)
{
    assert(COMM_BUF_CAP >= 2);
    if (comm_buf.len + 2 > COMM_BUF_CAP)
        CommFlush();

    comm_buf.data[comm_buf.len++] = v & 0xff;
    comm_buf.data[comm_buf.len++] = (v >> 8) & 0xff;
}

#ifdef CMAP256
static void CommWrite32(uint32_t v)
{
    assert(COMM_BUF_CAP >= 4);
    if (comm_buf.len + 4 > COMM_BUF_CAP)
        CommFlush();

    comm_buf.data[comm_buf.len++] = v & 0xff;
    comm_buf.data[comm_buf.len++] = (v >> 8) & 0xff;
    comm_buf.data[comm_buf.len++] = (v >> 16) & 0xff;
    comm_buf.data[comm_buf.len++] = (v >> 24) & 0xff;
}
#endif

static void CommWriteBytes(const char *p, size_t len)
{
    while (!interrupted) {
        size_t free_len = COMM_BUF_CAP - comm_buf.len;
        size_t copy_len = len <= free_len ? len : free_len;

        memcpy(comm_buf.data + comm_buf.len, p, copy_len);
        comm_buf.len += copy_len;
        len -= copy_len;
        p += copy_len;

        if (len == 0)
            break;

        // If we got here, then the buffer's full.
        CommFlush();
    }
}

static void CommWriteString(const char *s)
{
    size_t len = strlen(s);
    assert(len <= UINT16_MAX);

    CommWrite16(len);
    CommWriteBytes(s, len);
}

int main(int argc, char **argv)
{
    struct sigaction sa = {.sa_handler = SigintHandler};
    if (sigemptyset(&sa.sa_mask) == -1 || sigaction(SIGINT, &sa, NULL) == -1) {
        fprintf(stderr,
                "[actually-doom.nvim] Warning: Failed to install SIGINT "
                "handler: %s\n",
                strerror(errno));
    }

    doomgeneric_Create(argc, argv);

    while (!interrupted) {
        CommFlush();
        doomgeneric_Tick();
    }

    CommFlush();
    I_Quit();
}

static void CloseListenSocket(void)
{
    if (listen_sock_fd >= 0 && close(listen_sock_fd) == -1) {
        fprintf(stderr,
                "[actually-doom.nvim] Warning: Failed to close listener "
                "socket: %s\n",
                strerror(errno));
    }

    if (listen_sock_path && unlink(listen_sock_path) == -1) {
        fprintf(stderr,
                "[actually-doom.nvim] Warning: Failed to delete listener "
                "socket file: %s\n",
                strerror(errno));
    }

    listen_sock_fd = -1;
    listen_sock_path = NULL;
}

static void CloseSockets(void)
{
    CloseListenSocket();

    if (comm_sock_fd >= 0 && close(comm_sock_fd) == -1) {
        fprintf(stderr,
                "[actually-doom.nvim] Warning: Failed to close communications "
                "socket: %s\n",
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
        I_Error("[actually-doom.nvim] Unexpected error while reading clock: %s",
                strerror(errno));
    }

    return tp.tv_nsec / NS_PER_MS;
}

void DG_Init(void)
{
    int p = M_CheckParmWithArgs("-listen", 1);
    if (p == 0)
        I_Error("[actually-doom.nvim] \"-listen <socket_path>\" argument "
                "required.");

    listen_sock_path = myargv[p + 1];
    size_t listen_sock_path_len = strlen(listen_sock_path);
    struct sockaddr_un listen_sock_addr = {.sun_family = AF_UNIX};

    if (listen_sock_path_len + 1 > sizeof listen_sock_addr.sun_path) {
        I_Error("[actually-doom.nvim] Listener socket path too long; max: %zu, "
                "size: %zu.",
                (sizeof listen_sock_addr.sun_path) - 1, listen_sock_path_len);
    }

    if ((listen_sock_fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        I_Error("[actually-doom.nvim] Failed to create listener socket: %s",
                strerror(errno));
    }

    I_AtExit(CloseSockets, true);
    // Bounds already checked above.
    strcpy(listen_sock_addr.sun_path, listen_sock_path);

    if (bind(listen_sock_fd, (struct sockaddr *)&listen_sock_addr,
             sizeof listen_sock_addr)
        == -1) {
        I_Error("[actually-doom.nvim] Failed to bind listener socket to path "
                "\"%s\": %s",
                listen_sock_path, strerror(errno));
    }

    if (listen(listen_sock_fd, 2) != 0) {
        I_Error("[actually-doom.nvim] Failed to listen on actually-doom.nvim "
                "socket: %s",
                strerror(errno));
    }

    printf(
        "[actually-doom.nvim] Listening for connections on socket \"%s\"...\n",
        listen_sock_path);

    while ((comm_sock_fd = accept(listen_sock_fd, NULL, NULL)) == -1) {
        switch (errno) {
        case ECONNABORTED:
        case EPERM:
            fprintf(stderr,
                    "[actually-doom.nvim] Warning: Failed to accept a "
                    "connection: %s\n",
                    strerror(errno));
            break;

        case EINTR:
            if (interrupted)
                I_Quit();
            break;

        default:
            I_Error("[actually-doom.nvim] Unexpected error while listening for "
                    "connections: %s",
                    strerror(errno));
        }
    }

    struct ucred creds;
    if (getsockopt(comm_sock_fd, SOL_SOCKET, SO_PEERCRED, &creds,
                   &(socklen_t){sizeof creds})
        == 0) {
        printf("[actually-doom.nvim] PID %jd has connected.\n",
               (intmax_t)creds.pid);
    } else {
        printf("[actually-doom.nvim] A client has connected.\n");
    }

    CloseListenSocket();
    clock_start_ms = GetClockMs();

    CommWrite8(AMSG_INIT);
    CommWrite16(DOOMGENERIC_RESX);
    CommWrite16(DOOMGENERIC_RESY);
}

void DG_DrawFrame(void)
{
    CommWrite8(AMSG_FRAME);

#ifdef CMAP256
    // TODO: possibly slow; it may do a flush check for each u32 (also we're
    // manually splitting the bytes), but CMAP256 currently isn't actually used.
    for (size_t i = 0; i < DOOMGENERIC_RESX * DOOMGENERIC_RESY; ++i)
        CommWrite32(DG_ScreenBuffer[i]);
#else
    CommWriteBytes((char *)DG_ScreenBuffer,
                   DOOMGENERIC_RESX * DOOMGENERIC_RESY);
#endif
}

void DG_SleepMs(uint32_t ms)
{
    if (nanosleep(&(struct timespec){.tv_nsec = ms * NS_PER_MS}, NULL) == -1
        && (errno != EINTR || !interrupted)) {
        I_Error("[actually-doom.nvim] Unexpected error while sleeping: %s",
                strerror(errno));
    }
}

uint32_t DG_GetTicksMs(void)
{
    return GetClockMs() - clock_start_ms;
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    (void)pressed;
    (void)key;

    // TODO
    return 0;
}

void DG_SetWindowTitle(const char *title)
{
    CommWrite8(AMSG_SET_TITLE);
    CommWriteString(title);
}
