#!/bin/bash
# Mutation controls for scripts/check-art-contract.py --phase 1: one PASS/FAIL line per case, then "phase1-mutations: pass=N fail=M".
#   bash Tests/art/phase1-checks.test.sh [--jobs N] [--list] [--only ID ...]
set -u
cd "$(dirname "$0")/../.." || exit 2
exec /usr/bin/env python3 -I Tests/art/phase1_mutations.py "$@"
