#!/bin/bash
# Answers the first user line with a whole turn after closing its own stdin: the next write to this process fails with EPIPE.
here=$(cd "$(dirname "$0")" && pwd)
read -r user
exec 0<&-
sed -n 1,25p "$here/../p1-two-turns.jsonl"
sleep 30
