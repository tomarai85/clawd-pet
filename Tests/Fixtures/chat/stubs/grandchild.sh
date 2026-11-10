#!/bin/bash
# Replays a turn, and starts a detached grandchild: its own session, ignores TERM, reparented to launchd (a double fork), so only the spawn
# token it inherited finds it. $1 is the path of the clawd-chat-stub helper (a non-platform binary, which is what lets the token find it);
# the test writes a copy of this script with that path filled in. The stub itself ignores TERM and stdin EOF and stays until it is killed.
trap '' TERM
( "@STUB@" detached 60 & )

read -r user
sed -n 1,25p "@FIXTURES@/p1-two-turns.jsonl"
for _ in $(seq 900); do sleep 1; done   # gone after 15 min even when a failed or crashed test never stops it
