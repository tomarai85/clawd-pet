#include "ClawdProcess.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <sys/ttycom.h>

static int identity(pid_t pid, ClawdIdentity *out) {
    struct proc_bsdinfo info;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != sizeof(info)) return -1;
    out->pid = pid; out->uid = info.pbi_uid;
    out->seconds = info.pbi_start_tvsec; out->microseconds = info.pbi_start_tvusec;
    return 0;
}
static int field_may_be(const char *stored, int capacity, const char *base) {
    size_t n = strnlen(stored, capacity);
    if (n == 0) return -1;
    if (strncmp(stored, base, n)) return 0;
    if (base[n] == '\0') return 1;
    // The kernel cuts a long name to fit its field (pbi_comm keeps 15 of 16 bytes: "WidgetsExtensio"), so a stored name that fills its
    // field to within one byte and starts the file name may be that file name cut short.
    return n + 1 >= (size_t)capacity;
}
int clawd_names_may_be(const char *name, int name_capacity, const char *comm, int comm_capacity, const char *base) {
    int by_name = field_may_be(name, name_capacity, base);
    return by_name >= 0 ? by_name : field_may_be(comm, comm_capacity, base);
}
// Whether the process could be running the executable at `path`, judged by its own name (pbi_name, set from the executable's file name
// at exec; pbi_comm, its shorter copy, when pbi_name is empty). -1 when the process cannot be described or has no name at all.
static int may_run(pid_t pid, const char *path) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return clawd_names_may_be(info.pbi_name, sizeof(info.pbi_name), info.pbi_comm, sizeof(info.pbi_comm), base);
}
int clawd_own_pids(const char *path, ClawdIdentity *output, int capacity) {
    // Only our own uid's processes are listed: other users' processes refuse inspection (EPERM) and can never be ours.
    int needed = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
    if (needed <= 0) return -1;
    int size = needed + 4096;
    pid_t *pids = NULL;
    int bytes = 0;
    for (int attempt = 0; attempt < 4; attempt++) {
        free(pids); pids = calloc(1, size);
        if (!pids) return -1;
        bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, size);
        if (bytes <= 0) { free(pids); return -1; }
        if (bytes < size) break;
        size *= 2;
        if (attempt == 3) { free(pids); return -1; }
    }
    int count = 0;
    for (int i = 0; i < bytes / sizeof(pid_t); i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;
        ClawdIdentity info;
        errno = 0;
        if (identity(pid, &info)) {
            if (errno == ESRCH) continue;
            free(pids); return -1;
        }
        if (info.uid != getuid()) continue;
        char candidate[PROC_PIDPATHINFO_MAXSIZE];
        errno = 0;
        if (proc_pidpath(pid, candidate, sizeof(candidate)) <= 0) {
            if (errno == ESRCH) continue;
            // A process whose executable file is gone has no path (an app that updated itself while running: Stats' widget extension,
            // 2026-10-21, made every uninstall refuse). It can be ours only if its own name may be the agent's: any other name is
            // skipped, and the agent's name, a nameless process or one that cannot be described keeps the enumeration fail-closed.
            // The name is enough because every agent runs under the install file name: launchd starts only the launcher, the
            // launcher execs <its directory>/clawd-pet-agent, and the agent refuses any other start (test
            // LaunchdGuard_everyAgentRunsUnderTheInstallFileNameTheLauncherExecs). Uninstall enumerates only after the job is booted
            // out and its plist removed, so no agent can start during the scan.
            if (may_run(pid, path) == 0) continue;
            free(pids); return -1;
        }
        if (strcmp(candidate, path)) continue;
        ClawdIdentity after;
        if (identity(pid, &after)) { if (errno == ESRCH) continue; free(pids); return -1; }
        if (info.seconds != after.seconds || info.microseconds != after.microseconds || after.uid != getuid()) continue;
        if (count >= capacity) { free(pids); return -1; }
        output[count++] = info;
    }
    free(pids); return count;
}
int clawd_usage(int32_t pid, ClawdUsage *output) {
    if (identity(pid, &output->identity)) return -1;
    struct rusage_info_v4 info;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info)) return -1;
    ClawdIdentity after;
    if (identity(pid, &after)) return -1;
    if (after.seconds != output->identity.seconds || after.microseconds != output->identity.microseconds) return -1;
    // ri_user_time / ri_system_time are mach absolute time ticks, not nanoseconds: on Apple Silicon one tick is 125/3 ns.
    // Converting here keeps cpu_ns honest on every Mac; a failed timebase read fails the whole read instead of returning ticks.
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return -1;
    output->cpu_ns = (uint64_t)(((unsigned __int128)(info.ri_user_time + info.ri_system_time) * timebase.numer) / timebase.denom);
    output->wakeups = info.ri_pkg_idle_wkups;
    return 0;
}
int clawd_pid_path(int32_t pid, char *buffer, int size) {
    return proc_pidpath(pid, buffer, size) > 0 ? 0 : -1;
}
int clawd_app_processes(ClawdAppProcess *output, int capacity) {
    int needed = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
    if (needed <= 0) return -1;
    int size = needed + 4096;
    pid_t *pids = calloc(1, size);
    if (!pids) return -1;
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, size);
    if (bytes <= 0 || bytes >= size) { free(pids); return -1; }
    int count = 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        if (!strstr(path, "/Contents/MacOS/") || strlen(path) >= CLAWD_APP_PATH_MAX) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.pbi_uid != getuid()) continue;
        if (count >= capacity) { free(pids); return -1; }
        output[count].pid = pid;
        output[count].start_us = (uint64_t)info.pbi_start_tvsec * 1000000u + info.pbi_start_tvusec;
        output[count].zombie = info.pbi_status == SZOMB;
        strlcpy(output[count].path, path, CLAWD_APP_PATH_MAX);
        count++;
    }
    free(pids); return count;
}
int clawd_proc_facts_via(int32_t pid, uint64_t *start_us, int32_t *zombie, int32_t *via) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        *via = 1;
        *start_us = (uint64_t)info.pbi_start_tvsec * 1000000u + info.pbi_start_tvusec;
        *zombie = info.pbi_status == SZOMB;
        return 0;
    }
    // libproc cannot describe a zombie (an exited process its parent has not reaped yet): the process table still lists it.
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc entry;
    size_t length = sizeof(entry);
    memset(&entry, 0, sizeof(entry));
    if (sysctl(mib, 4, &entry, &length, NULL, 0) != 0 || length < sizeof(entry) || entry.kp_proc.p_pid != pid) return -1;
    if (entry.kp_proc.p_stat != SZOMB) return -1;
    *start_us = (uint64_t)entry.kp_proc.p_un.__p_starttime.tv_sec * 1000000u + (uint64_t)entry.kp_proc.p_un.__p_starttime.tv_usec;
    *zombie = 1;
    *via = 2;
    return 0;
}
int clawd_proc_facts(int32_t pid, uint64_t *start_us, int32_t *zombie) {
    int32_t via = 0;
    return clawd_proc_facts_via(pid, start_us, zombie, &via);
}
int clawd_kq_create(void) {
    int kq = kqueue();
    if (kq < 0) return -1;
    if (fcntl(kq, F_SETFD, FD_CLOEXEC) != 0) { close(kq); return -1; }
    return kq;
}
int clawd_kq_watch_exit(int kq, int32_t pid) {
    struct kevent change;
    EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(kq, &change, 1, NULL, 0, NULL) == 0) return 0;
    if (errno == ESRCH) return 1;
    return errno > 0 ? -errno : -EIO;
}
int clawd_kq_unwatch(int kq, int32_t pid) {
    struct kevent change;
    EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_DELETE, NOTE_EXIT, 0, NULL);
    if (kevent(kq, &change, 1, NULL, 0, NULL) == 0) return 0;
    return errno == ENOENT || errno == ESRCH ? 0 : -1;
}
int clawd_kq_drain(int kq, int32_t *pids, int capacity) {
    struct kevent events[16];
    struct timespec none = {0, 0};
    int count = 0;
    while (count < capacity) {
        int want = capacity - count < 16 ? capacity - count : 16;
        int n = kevent(kq, NULL, 0, events, want, &none);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) break;
        for (int i = 0; i < n; i++) {
            if (events[i].filter == EVFILT_PROC && (events[i].fflags & NOTE_EXIT)) pids[count++] = (int32_t)events[i].ident;
        }
    }
    return count;
}
int clawd_kq_watch_read(int kq, int fd) {
    struct kevent change;
    EV_SET(&change, (uintptr_t)fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(kq, &change, 1, NULL, 0, NULL) == 0) return 0;
    return errno > 0 ? -errno : -EIO;
}
int clawd_kq_wait(int kq, int *kind, int32_t *ident) {
    struct kevent event;
    for (;;) {
        int n = kevent(kq, NULL, 0, &event, 1, NULL);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) continue;
        if (event.filter == EVFILT_READ) { *kind = 1; *ident = (int32_t)event.ident; return 0; }
        if (event.filter == EVFILT_PROC) { *kind = 2; *ident = (int32_t)event.ident; return 0; }
    }
}
// The terminal path's ioctls and descriptor sweep. Swift does not import the _IO macros, so the calls live here.
int clawd_pty_set_size(int fd, int columns, int rows) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = (unsigned short)columns; size.ws_row = (unsigned short)rows;
    return ioctl(fd, TIOCSWINSZ, &size);
}
int clawd_pty_get_size(int fd, int *columns, int *rows) {
    struct winsize size;
    if (ioctl(fd, TIOCGWINSZ, &size) != 0) return -1;
    *columns = size.ws_col; *rows = size.ws_row;
    return 0;
}
int clawd_pty_take_controlling(int fd) { return ioctl(fd, TIOCSCTTY, 0); }
int clawd_close_descriptors_above(int lowest) {
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    int capacity = bytes + 64 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *list = malloc((size_t)capacity);
    if (list == NULL) return -1;
    bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, list, capacity);
    if (bytes <= 0) { free(list); return -1; }
    int closed = 0;
    for (int i = 0; i < bytes / (int)sizeof(struct proc_fdinfo); i++) {
        if (list[i].proc_fd > lowest && close(list[i].proc_fd) == 0) closed++;
    }
    free(list);
    return closed;
}
// The descriptors the process holds (pid's own list), their numbers in `output`. Returns the count or -1. For the tests and the guard check.
int clawd_list_descriptors(int32_t pid, int *numbers, int *types, int capacity) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    int size = bytes + 64 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *list = malloc((size_t)size);
    if (list == NULL) return -1;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, list, size);
    if (bytes <= 0) { free(list); return -1; }
    int count = bytes / (int)sizeof(struct proc_fdinfo);
    if (count > capacity) count = capacity;
    for (int i = 0; i < count; i++) { numbers[i] = list[i].proc_fd; types[i] = (int)list[i].proc_fdtype; }
    free(list);
    return count;
}
