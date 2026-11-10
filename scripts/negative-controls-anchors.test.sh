#!/bin/bash
# Test of `scripts/negative-controls --anchors`: in a temporary COPY (the tree is never mutated) the check must pass on the tree's own sources
# and must exit 1 and name the row when one anchor's text is gone from its file.
# Output: PASS <id> / FAIL <id> per case, then "negative-controls-anchors.test: pass=N fail=M".
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO/.build/nc-anchors-test/$(date +%s)-$$"
mkdir -p "$STAGE/scripts" || { echo "cannot create $STAGE"; exit 2; }
cp -R "$REPO/scripts/." "$STAGE/scripts/" && cp -R "$REPO/Sources" "$STAGE/Sources" && ln -s "$REPO/Tests" "$STAGE/Tests" && ln -s "$REPO/launcher" "$STAGE/launcher" && ln -s "$REPO/chat-page" "$STAGE/chat-page" || { echo "cannot copy"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
pass=0; fail=0

clean_rc() { /usr/bin/python3 "$STAGE/scripts/negative-controls" --anchors > "$STAGE/clean.out" 2>&1; }
verdict_clean() { clean_rc && grep -q '^negative-controls anchors: \([0-9]*\) of \1 row(s) apply$' "$STAGE/clean.out"; }

if verdict_clean; then pass=$((pass + 1)); echo "PASS anchors-pass-on-the-tree"; else fail=$((fail + 1)); echo "FAIL anchors-pass-on-the-tree"; fi

# stale fixture: the guarded line of "panel-without-nonactivating-style" is gone from PetPanel.swift
sed -i '' 's/\[\.borderless, \.nonactivatingPanel\]/[.borderless]/' "$STAGE/Sources/ClawdDesktop/PetPanel.swift"
/usr/bin/python3 "$STAGE/scripts/negative-controls" --anchors > "$STAGE/stale.out" 2> "$STAGE/stale.err"; rc=$?
if [ "$rc" = 1 ] && grep -q 'panel-without-nonactivating-style' "$STAGE/stale.err" && grep -q 'of .* row(s) apply' "$STAGE/stale.out"; then
  pass=$((pass + 1)); echo "PASS anchors-stale-row-exits-1-and-is-named"
else
  fail=$((fail + 1)); echo "FAIL anchors-stale-row-exits-1-and-is-named (rc=$rc)"
fi
# misnamed fixture: the test the row "ignored-clicks-are-counted" expects is renamed in the copied table only
sed -i '' 's/\["Click_clicksDuringTheRunAreNotCounted"\]/["Click_noSuchTestAnywhere"]/' "$STAGE/scripts/negative-controls"
/usr/bin/python3 "$STAGE/scripts/negative-controls" --anchors > "$STAGE/misnamed.out" 2> "$STAGE/misnamed.err"; rc=$?
if [ "$rc" = 1 ] && grep -q 'ignored-clicks-are-counted: expects the test Click_noSuchTestAnywhere' "$STAGE/misnamed.err"; then
  pass=$((pass + 1)); echo "PASS anchors-misnamed-expected-test-exits-1-and-is-named"
else
  fail=$((fail + 1)); echo "FAIL anchors-misnamed-expected-test-exits-1-and-is-named (rc=$rc)"
fi
echo "negative-controls-anchors.test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
