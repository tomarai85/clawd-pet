#!/bin/bash
# After a user line, streams one init line and waits; a control_request interrupt ends the turn with an error result.
here=$(cd "$(dirname "$0")" && pwd)
init=$(sed -n 9p "$here/../p1-two-turns.jsonl")
while IFS= read -r l; do
  case "$l" in
    *'"type":"user"'*) printf '%s\n' "$init" ;;
    *'"subtype":"interrupt"'*)
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":10,"total_cost_usd":0,"session_id":"s","result":"","errors":[]}' ;;
  esac
done
exit 0
