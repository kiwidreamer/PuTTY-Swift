#ifndef PTYSPAWN_H
#define PTYSPAWN_H

#include <sys/types.h>

// Spawn `path` with argv under a freshly allocated pseudo-terminal.
// On success returns 0, writes the PTY master fd to *master_fd and the
// child pid to *child_pid.  Returns -1 on failure.
// cols/rows set the initial window size of the PTY.
int pty_spawn(const char *path, char *const argv[],
              int cols, int rows,
              int *master_fd, pid_t *child_pid);

// Resize the PTY referenced by master_fd.
void pty_set_winsize(int master_fd, int cols, int rows);

#endif
