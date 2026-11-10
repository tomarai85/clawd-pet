#!/bin/bash
# Replays Tests/Fixtures/chat/p1-two-turns.jsonl: one user line in, the next turn's lines out (up to and including its result line).
here=$(cd "$(dirname "$0")" && pwd)
lines=()
while IFS= read -r l; do lines+=("$l"); done < "$here/../p1-two-turns.jsonl"
pos=0
while IFS= read -r user; do
  case "$user" in *'"type":"user"'*) ;; *) continue ;; esac
  while [ "$pos" -lt "${#lines[@]}" ]; do
    l=${lines[$pos]}; pos=$((pos + 1))
    printf '%s\n' "$l"
    case "$l" in *'"type":"result"'*) break ;; esac
  done
done
exit 0
