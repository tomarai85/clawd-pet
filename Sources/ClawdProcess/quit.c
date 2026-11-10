#include "ClawdQuit.h"
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

// The agent's SIGTERM handler touches only these two lock-free atomics (statically initialised) and write, sigaction and raise, which are
// async-signal-safe. Nothing here allocates, locks or calls the Swift runtime.
static atomic_int quit_holds = 0;
static atomic_int quit_pipe_write = -1;

void clawd_quit_default(void) {
    struct sigaction action;
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGTERM, &action, NULL);
    raise(SIGTERM);
}

static void quit_handler(int number) {
    (void)number;
    int fd = atomic_load(&quit_pipe_write);
    if (atomic_load(&quit_holds) == 0 || fd < 0) {
        clawd_quit_default();
        return;
    }
    unsigned char byte = 1;
    (void)write(fd, &byte, 1);
}

int clawd_quit_install(int pipe_write_end) {
    atomic_store(&quit_pipe_write, pipe_write_end);
    struct sigaction action;
    action.sa_handler = quit_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGTERM, &action, NULL) != 0) {
        atomic_store(&quit_pipe_write, -1);
        return -1;
    }
    return 0;
}

void clawd_quit_retain(void) { atomic_fetch_add(&quit_holds, 1); }

void clawd_quit_release(void) {
    int current = atomic_load(&quit_holds);
    while (current > 0 && !atomic_compare_exchange_weak(&quit_holds, &current, current - 1)) {}
}
