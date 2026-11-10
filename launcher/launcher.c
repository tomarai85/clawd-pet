// clawd-pet-launch: the program the LaunchAgent names. It replaces itself with the agent that sits next to it
// (same pid, same environment, argv[0] = the agent's path) and does nothing else.
//
// Why it exists. macOS tracks a LaunchAgent as a background item by the code identity of its program (ProgramArguments[0]). Every
// rebuilt agent has a new code identity, so naming the agent in the plist made macOS post "App Background Activity" after each
// rebuild. The plist names this launcher instead; it is built once, checked in with its sha256 (clawd-pet-launch.sha256), copied
// byte for byte by `clawd-pet install` and never rebuilt, so the item macOS tracks never changes while the agent behind it does.
// Measured on Friday 2026-10-17: one item across agent rebuilds, a plist rewrite and a full reinstall.
//
// It must stay a plain exec. The agent's launch guard asks launchd for the PID of the job and compares it with its own pid, so the
// launcher may not fork, wait or keep the job alive in any other way. A failure exits 111 and starts nothing.
//
// The agent is found by the launcher's own place, not by a path compiled in, so one binary serves every install root:
// <directory of this file>/clawd-pet-agent.
//
// Build: scripts/build-launcher (once). Changing this file means a new launcher, a new background-item notice for the user and a
// deliberate `scripts/build-launcher --rebuild`.
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define AGENT_NAME "clawd-pet-agent"

int main(int argc, char **argv) {
    (void)argc;
    char given[PATH_MAX];
    char self[PATH_MAX];
    char agent[PATH_MAX];
    uint32_t size = (uint32_t)sizeof given;
    if (_NSGetExecutablePath(given, &size) != 0) _exit(111);
    if (realpath(given, self) == NULL) _exit(111);
    char *slash = strrchr(self, '/');
    if (slash == NULL) _exit(111);
    size_t directory = (size_t)(slash - self) + 1;
    if (directory + sizeof AGENT_NAME > sizeof agent) _exit(111);
    memcpy(agent, self, directory);
    memcpy(agent + directory, AGENT_NAME, sizeof AGENT_NAME);
    argv[0] = agent;
    execv(agent, argv);
    _exit(111);
}
