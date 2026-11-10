#!/bin/bash
# Test of scripts/test-filter.sh, which is its own negative control: a stub stands in for `swift` and the helper must fail on a filter that
# matches nothing, on a failing test and on too few tests, and must pass on a matching run (XCTest and Swift Testing summary lines).
# Output: PASS <id> / FAIL <id> per case, then "test-filter.test: pass=N fail=M".
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/test-filter-test.XXXXXX")" || { echo "cannot create a stage"; exit 2; }
pass=0; fail=0

# stub <name> <exit status> <lines...>: writes $STAGE/<name>, a fake `swift` printing the lines and exiting with the status.
stub() {
  local name=$1 rc=$2; shift 2
  { echo '#!/bin/bash'; for line in "$@"; do printf 'printf "%%s\\n" %q\n' "$line"; done; echo "exit $rc"; } > "$STAGE/$name"
  chmod +x "$STAGE/$name"
}
# case <id> <expected exit> <stub> <min> [filter]
check() {
  local id=$1 want=$2 stubname=$3 min=$4 filter=${5:-Chat}
  CLAWD_TEST_FILTER_SWIFT="$STAGE/$stubname" CLAWD_TEST_BASELINE="$STAGE/baseline.txt" bash "$REPO/scripts/test-filter.sh" "$filter" "$min" > "$STAGE/$id.out" 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass + 1)); echo "PASS $id"; else fail=$((fail + 1)); echo "FAIL $id (exit $rc, wanted $want)"; fi
}

printf 'Chat=6\nScene=3\n' > "$STAGE/baseline.txt"
stub nomatch 0 "Building for debugging..." "Build complete! (1.68 sec)" "warning: No matching test cases were run"
stub testing6 0 "Build complete!" "✔ Test run with 6 tests in 1 suite passed after 0.012 seconds."
stub testing5 0 "Build complete!" "✔ Test run with 5 tests in 1 suite passed after 0.012 seconds."
stub testing1 0 "Build complete!" "✔ Test run with 1 test in 1 suite passed after 0.001 seconds."
stub xctest4 0 "Test Suite 'All tests' passed at 2026-10-23 21:00:00." "	 Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
stub both 0 "	 Executed 2 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds" "✔ Test run with 4 tests in 1 suite passed after 0.012 seconds."
stub failing 1 "Build complete!" "✘ Test run with 6 tests in 1 suite failed after 0.012 seconds with 1 issue."
stub buildfail 1 "error: cannot find 'Nope' in scope"

check no-match-fails 1 nomatch 1
check min-zero-lets-a-measuring-run-pass 0 nomatch 0
check failing-test-fails 1 failing 1
check build-failure-fails 1 buildfail 0
check matching-swift-testing-run-passes 0 testing6 6
check too-few-tests-fails 1 testing5 6
check singular-test-line-counts 0 testing1 1
check xctest-summary-counts 0 xctest4 4
check xctest-and-swift-testing-counts-add 0 both 6
check xctest-summary-too-few-fails 1 xctest4 5
check baseline-reads-the-suite-entry 0 testing6 @baseline Chat
check baseline-too-few-fails 1 testing5 @baseline Chat
check baseline-missing-entry-is-refused 2 testing6 @baseline NoSuchSuite
check non-numeric-min-is-refused 2 testing6 many
if bash "$REPO/scripts/test-filter.sh" > /dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL no-arguments-is-refused"; else pass=$((pass + 1)); echo "PASS no-arguments-is-refused"; fi

if grep -q 'ran 0 test' "$STAGE/no-match-fails.out"; then pass=$((pass + 1)); echo "PASS count-is-printed"; else fail=$((fail + 1)); echo "FAIL count-is-printed"; fi
echo "test-filter.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
