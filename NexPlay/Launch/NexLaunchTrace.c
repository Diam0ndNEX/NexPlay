// NexPlay 8.7.5: launch trace (see NexLaunchTrace.h). Plain POSIX calls only: the first mark runs in a constructor,
// before main, Foundation or Swift are ready.
#include "NexLaunchTrace.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

void nex_launch_mark(const char *step)
{
    const char *home = getenv("HOME");
    if (!home || !step) return;
    char path[1024];
    if (snprintf(path, sizeof(path), "%s/Documents/NexPlay-launch.txt", home) >= (int)sizeof(path)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char line[512];
    int n = snprintf(line, sizeof(line), "%ld pid %d: %s\n", (long)time(NULL), (int)getpid(), step);
    if (n > 0) write(fd, line, (size_t)(n < (int)sizeof(line) ? n : (int)sizeof(line) - 1));
    fsync(fd);
    close(fd);
}

// Runs before BCD's constructors (priority 101+), i.e. right after dyld has loaded every library.
__attribute__((constructor(100), used)) static void nex_launch_first(void)
{
    nex_launch_mark("1 loaded (before any other code)");
}
__attribute__((constructor(65535), used)) static void nex_launch_ctors_done(void)
{
    nex_launch_mark("2 start-up code done");
}
