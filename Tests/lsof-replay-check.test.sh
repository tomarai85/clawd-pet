#!/bin/bash
# Test of the verdict of scripts/lsof-replay-check.sh (done-bar 2b). The check counts non-read descriptors on Aqua paths and network
# descriptors in every sample; its verdict must fail when either count is above zero. This test runs the whole check three times
# against the real replayed agent (headless --test-replay, fake HOME, no window), with the lsof seam (CLAWD_LSOF) pointing at
# Tests/stubs/lsof-inject: a transparent run, a run in which the agent's listing gains one write descriptor on an Aqua path
# (nonread=1), and one in which it gains a network descriptor (net=1). The last two must exit non-zero.
# CLAWD_LSOF_CHECK_SCRIPT points the test at a copy (the negative control runs it against a reverted copy).
# Output: PASS <id> / FAIL <id> per case, then "lsof-replay-check.test: pass=N fail=M".
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${CLAWD_LSOF_CHECK_SCRIPT:-$REPO/scripts/lsof-replay-check.sh}"
INJECT="$REPO/Tests/stubs/lsof-inject"
STAGE="$REPO/.build/lsof-check-test/$(date +%s)-$$"
mkdir -p "$STAGE" || { echo "cannot create $STAGE"; exit 2; }
[ -x "$SCRIPT" ] || { echo "no check script at $SCRIPT"; exit 2; }

pass=0; fail=0
verdict() { # id, then a command whose success is the check
  local id="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "PASS $id"; else fail=$((fail + 1)); echo "FAIL $id"; fi
}
count_of() { sed -n "s/^$2: \([0-9][0-9]*\)\$/\1/p" "$1" | head -n 1; }

run_case() { # name, inject value (may be empty)
  CLAWD_LSOF="$INJECT" CLAWD_LSOF_INJECT="$2" /bin/bash "$SCRIPT" > "$STAGE/$1.out" 2>&1
  echo $? > "$STAGE/$1.rc"
}
run_case transparent "" &
run_case nonread nonread &
run_case net net &
wait

rc_transparent="$(cat "$STAGE/transparent.rc")"; rc_nonread="$(cat "$STAGE/nonread.rc")"; rc_net="$(cat "$STAGE/net.rc")"
verdict lsof-wrapper-is-transparent test "$rc_transparent" = 0
verdict lsof-transparent-run-counts-zero bash -c "[ \"$(count_of "$STAGE/transparent.out" AQUA-NONREAD-FDS)\" = 0 ] && [ \"$(count_of "$STAGE/transparent.out" NET-FDS)\" = 0 ]"
verdict lsof-nonread-sample-is-counted bash -c "[ \"$(count_of "$STAGE/nonread.out" AQUA-NONREAD-FDS)\" -ge 1 ] 2>/dev/null"
verdict lsof-nonread-sample-fails-the-verdict bash -c "[ '$rc_nonread' != 0 ] && grep -q '^FAIL: .*non-read-only' '$STAGE/nonread.out'"
verdict lsof-net-sample-is-counted bash -c "[ \"$(count_of "$STAGE/net.out" NET-FDS)\" -ge 1 ] 2>/dev/null"
verdict lsof-net-sample-fails-the-verdict bash -c "[ '$rc_net' != 0 ] && grep -q '^FAIL: .*network' '$STAGE/net.out'"
verdict lsof-injected-runs-still-saw-the-replay bash -c "grep -q 'REPLAY-SCENES: .*sent' '$STAGE/nonread.out' && grep -q 'REPLAY-SCENES: .*sent' '$STAGE/net.out'"

echo "lsof-replay-check.test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
