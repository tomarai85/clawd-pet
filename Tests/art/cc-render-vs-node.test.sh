#!/bin/bash
# The C motions against the real render-core.js run in node: one PASS/FAIL line per motion, then "cc-render-vs-node: pass=N fail=M".
#   bash Tests/art/cc-render-vs-node.test.sh
set -u
cd "$(dirname "$0")/../.." || exit 2
exec /usr/bin/env python3 -I Tests/art/cc_render_vs_node.py "$@"
