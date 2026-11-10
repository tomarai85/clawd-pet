#!/bin/bash
# Usage: scripts/test-filter.sh <filter> <min|@baseline>
# Runs `swift test --filter <filter>` and exits 0 only when swift exited 0 AND at least <min> tests ran. `swift test` exits 0 when a
# filter matches nothing (it only prints "No matching test cases were run"), so a bare filtered run proves nothing.
# <min> is a number, or the literal @baseline: the count recorded for <filter> in Tests/test-count-baseline.txt (lines `Suite=count`).
# The count is the sum of the XCTest total ("Executed N tests") and the Swift Testing total ("Test run with N tests").
# Exit: 0 passed and enough tests; 1 too few tests ran; 2 bad arguments or no baseline entry; otherwise swift's own non-zero status.
# CLAWD_TEST_FILTER_SWIFT (a command) and CLAWD_TEST_BASELINE (a file) replace `swift` and the baseline file; only the test of this script sets them.
set -u
if [ "$#" -ne 2 ] || [ -z "$1" ]; then
  echo "usage: scripts/test-filter.sh <filter> <min|@baseline>" >&2
  exit 2
fi
filter=$1
want=$2
repo="$(cd "$(dirname "$0")/.." && pwd)"
baseline_file="${CLAWD_TEST_BASELINE:-$repo/Tests/test-count-baseline.txt}"

if [ "$want" = "@baseline" ]; then
  want=$(awk -F= -v f="$filter" '$1 == f { print $2; exit }' "$baseline_file" 2>/dev/null)
  if [ -z "$want" ]; then
    echo "test-filter: no baseline entry for $filter in $baseline_file" >&2
    exit 2
  fi
fi
case "$want" in
  ''|*[!0-9]*) echo "test-filter: <min> must be a number or @baseline, got '$want'" >&2; exit 2 ;;
esac

log=$(mktemp "${TMPDIR:-/tmp}/test-filter.XXXXXX") || { echo "test-filter: cannot create a log file" >&2; exit 2; }
trap 'rm -f "$log"' EXIT
${CLAWD_TEST_FILTER_SWIFT:-swift} test --disable-index-store --filter "$filter" > "$log" 2>&1
rc=$?
cat "$log"

text=$(sed 's/'"$(printf '\033')"'\[[0-9;]*m//g' "$log")
xctest=$(printf '%s\n' "$text" | sed -n 's/^.*Executed \([0-9][0-9]*\) tests\{0,1\},.*$/\1/p' | tail -n 1)
testing=$(printf '%s\n' "$text" | sed -n 's/^.*Test run with \([0-9][0-9]*\) tests\{0,1\}.*$/\1/p' | tail -n 1)
count=$(( ${xctest:-0} + ${testing:-0} ))
echo "test-filter: $filter ran $count test(s), minimum $want, swift exit $rc"

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
if [ "$count" -lt "$want" ]; then
  echo "test-filter: FAIL $filter: $count test(s) ran, $want required" >&2
  exit 1
fi
exit 0
