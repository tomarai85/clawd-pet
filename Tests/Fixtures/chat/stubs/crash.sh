#!/bin/bash
# Reads a user line, writes a few lines, then dies with exit 3 and stderr lines, in the middle of the turn.
here=$(cd "$(dirname "$0")" && pwd)
read -r user
sed -n 1,12p "$here/../p1-two-turns.jsonl"
echo "first stderr line" >&2
echo "second stderr line" >&2
exit 3
