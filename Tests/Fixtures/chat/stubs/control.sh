#!/bin/bash
# Prints a control_request and records what comes back on stdin into $CHAT_STUB_LOG (given as the first argument of the stub's folder).
read -r user
printf '%s\n' '{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}'
sleep 0.5
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"total_cost_usd":0.1,"session_id":"s","result":"done"}'
while IFS= read -r l; do printf '%s\n' "$l" >> "$PWD/control-answers.txt"; done
exit 0
