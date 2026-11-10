#!/bin/bash
# Appends its arguments to ./spawn-args.log, answers turns like replay.sh, and when its stdin closes prints one more init line that names another
# session (00000000-0000-4000-8000-000000000099), as a child that was told to stop but had one last line in its pipe.
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >> spawn-args.log
"$here/replay.sh"
sed -n '9p' "$here/../p1-two-turns.jsonl" | sed 's/"session_id":"00000000-0000-4000-8000-000000000001"/"session_id":"00000000-0000-4000-8000-000000000099"/'
exit 0
