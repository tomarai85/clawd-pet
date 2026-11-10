#!/bin/bash
# Appends its arguments to ./spawn-args.log (the chat folder; one line per spawn). The first spawn answers a turn like replay.sh; every later spawn
# exits before its init, as a resumed child does when Esc, Stop or the exam stand-down comes in its first seconds.
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >> spawn-args.log
[ "$(wc -l < spawn-args.log | tr -d ' ')" -eq 1 ] && exec "$here/replay.sh"
exit 0
