// A native stand-in for the agent behind the launcher in the launcher tests (compiled by Tests/cli.test.sh, never installed by install).
//
// With STUB_GUARD_LOG unset it prints what it was started with and exits: argv[0], the number of arguments, its pid, the canary variable.
// With STUB_GUARD_LOG set it makes the decision of the agent's launch guard (LaunchGuard in Sources/ClawdCore/ProcessIdentity.swift):
// XPC_SERVICE_NAME must be the job's label, and `launchctl list <label>` (the stub named by CLAWD_LAUNCHCTL) must report a "PID" equal
// to this process's own pid. It writes what it saw and what it decided to STUB_GUARD_LOG through a rename, so a reader never sees half
// of it, then stays alive until it is stopped, as the agent does.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LABEL "com.tomtim.clawd-pet"

static const char *env_or(const char *name, const char *fallback) {
    const char *value = getenv(name);
    return value != NULL ? value : fallback;
}

int main(int argc, char **argv) {
    const char *log = getenv("STUB_GUARD_LOG");
    if (log == NULL) {
        printf("argv0=%s\nargs=%d\npid=%d\ncanary=%s\n", argv[0], argc - 1, (int)getpid(), env_or("CLAWD_LAUNCH_CANARY", ""));
        for (int i = 1; i < argc; i++) printf("arg%d=%s\n", i, argv[i]);
        return 0;
    }
    char partial[4096];
    snprintf(partial, sizeof partial, "%s.new", log);
    FILE *out = fopen(partial, "w");
    if (out == NULL) return 3;
    fprintf(out, "argv0=%s\nargs=%d\npid=%d\nxpc=%s\ncanary=%s\n", argv[0], argc - 1, (int)getpid(),
            env_or("XPC_SERVICE_NAME", ""), env_or("CLAWD_LAUNCH_CANARY", ""));
    int listed = -1;
    if (strcmp(env_or("XPC_SERVICE_NAME", ""), LABEL) == 0) {
        char command[4096];
        snprintf(command, sizeof command, "'%s' list %s 2>/dev/null", env_or("CLAWD_LAUNCHCTL", "/bin/launchctl"), LABEL);
        FILE *pipe = popen(command, "r");
        if (pipe != NULL) {
            char line[512];
            while (fgets(line, sizeof line, pipe) != NULL) {
                int pid = 0;
                const char *at = strstr(line, "\"PID\" = ");
                if (at != NULL && sscanf(at, "\"PID\" = %d;", &pid) == 1) { listed = pid; break; }
            }
            pclose(pipe);
        }
    }
    int allowed = listed > 0 && listed == (int)getpid();
    fprintf(out, "listed=%d\nguard=%s\n", listed, allowed ? "allowed" : "refused");
    if (fclose(out) != 0) return 3;
    if (rename(partial, log) != 0) return 3;
    if (!allowed) return 0;
    for (;;) sleep(1);
}
