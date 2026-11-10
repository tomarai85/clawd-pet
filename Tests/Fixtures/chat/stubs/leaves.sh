#!/bin/bash
# Starts a detached helper (its own session, ignores TERM, reparented to launchd; a double fork, so only the spawn token finds it) and replays a
# turn, then leaves on its own, as an idle exit or a crash does. $1 of the helper is the clawd-chat-stub path filled in by the test. The helper
# ignores TERM and stdin EOF, so the sweep that follows the exit needs its SIGKILL at about 2 s.
trap '' TERM
( "@STUB@" detached 60 & )

read -r user
sed -n 1,25p "@FIXTURES@/p1-two-turns.jsonl"
exit 3
