#include "PTYSpawn.h"

#include <util.h>      // forkpty
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <stdlib.h>

int pty_spawn(const char *path, char *const argv[],
              int cols, int rows,
              int *master_fd, pid_t *child_pid) {
    struct winsize ws;
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: the PTY slave is already our controlling terminal and stdio.
        execv(path, argv);
        _exit(127);
    }
    // Parent.
    *master_fd = master;
    *child_pid = pid;
    return 0;
}

void pty_set_winsize(int master_fd, int cols, int rows) {
    struct winsize ws;
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    ioctl(master_fd, TIOCSWINSZ, &ws);
}
