#!/bin/bash
# Appends its arguments to ./spawn-args.log. With --resume among them it prints the CLI's refusal to stderr and exits 1 before any init, as the CLI
# does when the session is not under the working directory; without it, it answers a turn like replay.sh.
here=$(cd "$(dirname "$0")" && pwd)
echo "$*" >> spawn-args.log
case " $* " in *" --resume "*) echo "No conversation found with session ID: stub" >&2; exit 1 ;; esac
exec "$here/replay.sh"
