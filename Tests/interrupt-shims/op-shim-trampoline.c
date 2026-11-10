/*
 * op-shim-trampoline: the compiled entry the suites put on PATH as mkdir, cp, mv, chmod, sed, rm and rmdir (symlinks to this binary).
 * It runs the shell shim (op-shim, path compiled in as OPSHIM_SCRIPT) through an explicit `/bin/sh op-shim ...`, passing the command
 * name in OPSHIM_NAME, and replaces itself with it (execv), so the shim keeps this process's pid and parent: its PPID check, its
 * SIGSTOP of itself and the test's SIGCONT all work as before.
 *
 * Why: on macOS 26 each exec of a #! script by a #! script (the CLI under test is a bash script) leaves about 1 KiB in the kernel zone
 * data.kalloc.1024 that only a reboot frees; the suites made millions of such execs through the #! shim (measured 2026-10-21 by the
 * claude-config lane: depth-2 #! about one element per run, an explicit interpreter about one per 17 runs).
 */
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef OPSHIM_SCRIPT
#error "build with -DOPSHIM_SCRIPT=\"/path/to/op-shim\""
#endif

int main(int argc, char **argv) {
    char name[1024];
    strncpy(name, argv[0], sizeof name - 1);
    name[sizeof name - 1] = '\0';
    if (setenv("OPSHIM_NAME", basename(name), 1) != 0) { perror("op-shim-trampoline: setenv"); return 127; }
    char **args = calloc((size_t)argc + 2, sizeof *args);
    if (!args) { perror("op-shim-trampoline: calloc"); return 127; }
    args[0] = "sh";
    args[1] = OPSHIM_SCRIPT;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
    execv("/bin/sh", args);
    perror("op-shim-trampoline: execv /bin/sh");
    return 127;
}
