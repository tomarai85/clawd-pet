#ifndef CLAWD_PROCESS_H
#define CLAWD_PROCESS_H
#include <stdint.h>
#include "ClawdQuit.h"
typedef struct { int32_t pid; uint32_t uid; uint64_t seconds; uint64_t microseconds; } ClawdIdentity;
typedef struct { ClawdIdentity identity; uint64_t cpu_ns; uint64_t wakeups; } ClawdUsage;
// Returns count or -1. Only ESRCH is ignored; denied enumeration is an error.
int clawd_own_pids(const char *path, ClawdIdentity *output, int capacity);
// Whether a process's kernel name fields (pbi_name, else pbi_comm; each `capacity` bytes, not always NUL-terminated) may be the file
// name `base`: 1 equal or a cut-short prefix, 0 a different name, -1 both empty (unknown).
int clawd_names_may_be(const char *name, int name_capacity, const char *comm, int comm_capacity, const char *base);
int clawd_usage(int32_t pid, ClawdUsage *output);
// Writes the executable path of pid into buffer; 0 on success, -1 on failure.
int clawd_pid_path(int32_t pid, char *buffer, int size);
// One application process of the agent's own user: its executable lies inside "<something>/Contents/MacOS/". `path` is that executable's
// path (processes with a longer path are left out: no application bundle has one).
#define CLAWD_APP_PATH_MAX 1024
typedef struct { int32_t pid; uint64_t start_us; int32_t zombie; char path[CLAWD_APP_PATH_MAX]; } ClawdAppProcess;
// Lists the user's application processes (zombies included, flagged). Returns the count, or -1 when the list cannot be read or does not fit.
int clawd_app_processes(ClawdAppProcess *output, int capacity);
// The generation facts of one pid: its start time in microseconds and whether it is a zombie. 0 when the process exists, -1 when it is gone.
int clawd_proc_facts(int32_t pid, uint64_t *start_us, int32_t *zombie);
// The same, and which path answered: 1 for libproc (proc_pidinfo), 2 for the process-table fallback (sysctl).
int clawd_proc_facts_via(int32_t pid, uint64_t *start_us, int32_t *zombie, int32_t *via);
// A kqueue for process-exit events. Returns the descriptor or -1.
int clawd_kq_create(void);
// Registers a one-shot NOTE_EXIT for pid. Returns 0 when the kernel holds the registration, 1 when the process is already gone (ESRCH), the negated errno otherwise.
int clawd_kq_watch_exit(int kq, int32_t pid);
// Deletes the registration of pid; a pid that has no registration (it fired, or never was one) is not an error. Returns 0 or -1.
int clawd_kq_unwatch(int kq, int32_t pid);
// Reads the exit events that are ready now, without waiting: the pids go to `pids`. Returns the count or -1.
int clawd_kq_drain(int kq, int32_t *pids, int capacity);
// Registers read-readiness of fd. Returns 0 or the negated errno.
int clawd_kq_watch_read(int kq, int fd);
// Blocks (no timeout) until a registered descriptor is readable (kind 1, ident = fd) or a watched process exited (kind 2, ident = pid). 0, or -1.
int clawd_kq_wait(int kq, int *kind, int32_t *ident);
// The terminal path (spec R9.2 T-1, T-5): the window size of a PTY, the controlling-terminal ioctl, and the trampoline's descriptor sweep.
int clawd_pty_set_size(int fd, int columns, int rows);
int clawd_pty_get_size(int fd, int *columns, int *rows);
int clawd_pty_take_controlling(int fd);
// Closes every descriptor of this process numbered above `lowest`, listed with proc_pidinfo(PROC_PIDLISTFDS). The count, or -1.
int clawd_close_descriptors_above(int lowest);
// The descriptors pid holds: numbers and PROX_FDTYPE values. The count, or -1.
int clawd_list_descriptors(int32_t pid, int *numbers, int *types, int capacity);
#endif
