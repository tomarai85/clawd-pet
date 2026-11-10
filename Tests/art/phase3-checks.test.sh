#!/bin/bash
# Mutation controls for scripts/check-art-contract.py --phase 3: one PASS/FAIL line per case, then "phase3-mutations: pass=N fail=M".
#   bash Tests/art/phase3-checks.test.sh [--jobs N] [--list] [--only ID ...]
set -u
cd "$(dirname "$0")/../.." || exit 2
exec /usr/bin/env python3 -I Tests/art/phase3_mutations.py "$@"
