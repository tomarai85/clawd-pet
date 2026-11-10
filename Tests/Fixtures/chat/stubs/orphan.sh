#!/bin/bash
# Replays a turn, then 0.5 s later starts a system tool in a session of its own (so not in the child's group; a platform binary hides its
# environment, so no spawn token finds it) from a subshell that lives 1.6 s and exits, which reparents the tool to launchd. Its pid goes to
# the file named PIDFILE below (filled in by the test). A snapshot taken only when a stop begins (after 2 s) cannot see it; one grown every second can.
read -r user
sed -n 1,25p "@FIXTURES@/p1-two-turns.jsonl"
sleep 0.5
( /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec "/bin/sleep", "300"' & echo $! > "@PIDFILE@"; /bin/sleep 1.6 ) &
for _ in $(seq 900); do sleep 1; done   # gone after 15 min even when a failed or crashed test never stops it
