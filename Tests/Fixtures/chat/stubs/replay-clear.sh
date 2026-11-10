#!/bin/bash
# Replays the third turn of Tests/Fixtures/chat/d-clear-uuid.jsonl (the `/clear` turn: running, queued, started, conversation_reset, init, replay,
# result, completed, idle) when a user line comes in. The first two turns of the capture (`/context` and the `touch` denial) are skipped.
here=$(cd "$(dirname "$0")" && pwd)
lines=()
running=0
while IFS= read -r l; do
  case "$l" in *'"state":"running"'*) running=$((running + 1)) ;; esac
  [ "$running" -ge 3 ] && lines+=("$l")
done < "$here/../d-clear-uuid.jsonl"
# The capture's own uuid for the command (Clawd's frames carry one of theirs, and the ledger matches on it).
fixture=$(printf '%s\n' "${lines[@]}" | sed -n 's/.*"command_uuid":"\([^"]*\)".*/\1/p' | head -1)
while IFS= read -r user; do
  case "$user" in *'"type":"user"'*) ;; *) continue ;; esac
  mine=$(printf '%s' "$user" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
  for l in "${lines[@]}"; do
    [ -n "$mine" ] && [ -n "$fixture" ] && l=${l//$fixture/$mine}
    printf '%s\n' "$l"
    case "$l" in *'"state":"idle"'*) break ;; esac
  done
done
exit 0
