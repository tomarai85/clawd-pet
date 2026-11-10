#ifndef CLAWD_QUIT_H
#define CLAWD_QUIT_H
// The agent's SIGTERM handling while chat work is in flight. The handler reads only two lock-free atomics and calls only async-signal-safe
// functions. While the hold count is 0 (or no pipe is installed) SIGTERM keeps its default and kills the agent at once; otherwise the handler
// writes one byte to the pipe's write end and returns, for the main queue to act on.
// Installs the handler with the pipe's write end (non-blocking). 0, or -1 when sigaction failed (SIGTERM then keeps its default).
int clawd_quit_install(int pipe_write_end);
// One more hold: a live chat child, or a cleanup (a stop's sweep) that must finish before the agent dies.
void clawd_quit_retain(void);
// One hold less (never below 0).
void clawd_quit_release(void);
// Puts SIGTERM back to its default and raises it: the agent dies of SIGTERM.
void clawd_quit_default(void);
#endif
