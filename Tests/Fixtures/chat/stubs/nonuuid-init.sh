#!/bin/bash
# Appends its arguments to ./spawn-args.log and answers turns like replay.sh, but every line names the session `-p` (a value the CLI's --resume
# would read as a flag): an init that names something that is not a UUID.
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >> spawn-args.log
lines=()
while IFS= read -r l; do lines+=("$l"); done < "$here/../p1-two-turns.jsonl"
pos=0
while IFS= read -r user; do
  case "$user" in *'"type":"user"'*) ;; *) continue ;; esac
  while [ "$pos" -lt "${#lines[@]}" ]; do
    l=${lines[$pos]}; pos=$((pos + 1))
    printf '%s\n' "${l//\"session_id\":\"00000000-0000-4000-8000-000000000001\"/\"session_id\":\"-p\"}"
    case "$l" in *'"type":"result"'*) break ;; esac
  done
done
exit 0
