#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec /usr/bin/python3 "$repo/scripts/lint_banned.py" "${1:-$repo}"
