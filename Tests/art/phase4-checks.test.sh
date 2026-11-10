#!/bin/bash
# Mutation controls for scripts/check-art-contract.py --phase 4: one PASS/FAIL line per case, then "phase4-mutations: pass=N fail=M".
#   bash Tests/art/phase4-checks.test.sh [--jobs N] [--list] [--only ID ...]
set -u
cd "$(dirname "$0")/../.." || exit 2
exec /usr/bin/env python3 -I Tests/art/phase4_mutations.py "$@"
