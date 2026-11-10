#!/bin/bash
# After a user line prints one message_start block and 3000 one-character deltas as fast as it can, then a result.
read -r user
printf '%s\n' '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"session_id":"s","uuid":"u","api_message_id":"m1","parent_tool_use_id":null}'
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s","uuid":"u","api_message_id":"m1","parent_tool_use_id":null}'
for i in $(seq 1 3000); do
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}},"session_id":"s","uuid":"u","api_message_id":"m1","parent_tool_use_id":null}'
done
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"total_cost_usd":0.1,"session_id":"s","result":""}'
while read -r l; do :; done
exit 0
