#!/bin/bash
# After a user line prints one very long line (CHAT_STUB_BYTES, default 300000 bytes), then a normal result line.
read -r user
head -c "${CHAT_STUB_BYTES:-300000}" /dev/zero | tr '\0' 'a'
printf '\n'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"total_cost_usd":0.1,"session_id":"s","result":"after the long line"}'
while read -r l; do :; done
exit 0
