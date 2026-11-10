#!/bin/bash
# Test of scripts/attended-check.sh (spec section 6 item 1(b) as replaced in "r4 change"; round brief r4 B.2 and B.4).
# The script only ever runs in its sandbox mode, where EVERY external effect comes from a stub in Tests/attended-stubs: a launchctl
# that answers `list` from numbered files, and a sampler whose frontmost pids, synthetic clock and "the user's clicks" (INPUT lines
# appended to a fixture agent.log) come from a scenario file; the window lists come from numbered files. No real launchctl, no real
# window list, no real frontmost read, no window, no event. Real mode needs --real, which no line of this file ever passes.
#
# One scenario per FAIL / NOT RUN row of the brief (and per boundary). Scenarios run in parallel, each in its own sandbox under
# .build/attended-check-test/. Every scenario asserts the verdict, the exit code and the EXACT set of reason codes, so a check that is
# removed turns its own scenario red rather than being masked by another reason.
# The last line, "attended-check.test: pass=N fail=M", is printed only from executed assertions.
#
# Two PATH shims (Tests/attended-stubs/shim/head and tail) put a rotation of agent.log INSIDE the script's analysis of the logs, between
# two of its reads, which no stub of an external effect can reach; a scenario puts the shim directory first in PATH (shim_env).
#
# Timing of the scenarios. The script opens its window when the stub sampler has written its first samples (sample index 2 to 4, about
# 60 ms in). Every event a scenario wants INSIDE the window is therefore scheduled at sample index 20 or later (400 ms), and the
# scenarios about events OUTSIDE the window use sample index 0 (before the first sample) or the lsappinfo hooks (after the frozen end).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/attended-check.sh"
STUBS="$REPO/Tests/attended-stubs"
CHECK_BASH="$(command -v "${CLAWD_TEST_BASH:-bash}")"
JOBS="${CLAWD_TEST_JOBS:-6}"
[ "$(id -u)" -ne 0 ] || { echo "attended-check.test: refuses to run as root"; exit 2; }
[ -x "$CHECK_BASH" ] || { echo "attended-check.test: no interpreter: ${CLAWD_TEST_BASH:-bash}"; exit 2; }
STAGE="$REPO/.build/attended-check-test/$(date +%s)-$$"
RESDIR="$STAGE/res"
mkdir -p "$RESDIR" || { echo "cannot create $STAGE"; exit 2; }
echo "attended-check.test: interpreter = $CHECK_BASH $("$CHECK_BASH" -c 'echo "$BASH_VERSION"')"

LABEL="com.tomtim.clawd-pet"
TS=1792000000

. "$REPO/Tests/check-harness.sh"

# ---- the sandbox of one scenario -----------------------------------------------------------------------------------------------------
# new_sandbox NAME: a fake HOME with an installed, loaded, healthy pet; the stub scenario of three click cycles, one of them a drag.
new_sandbox() {
  SB="$STAGE/$1"
  ROOT_="$SB/home/Library/Application Support/clawd-pet"
  LOG="$ROOT_/agent.log"; LOG1="$ROOT_/agent.log.1"; STATUS="$ROOT_/status.json"
  STUB="$SB/stub"
  mkdir -p "$ROOT_" "$SB/home/Library/LaunchAgents" "$STUB" "$SB/evidence" || return 1
  : > "$SB/.attended-sandbox"
  : > "$SB/home/Library/LaunchAgents/$LABEL.plist"
  SEQ=0
  printf '%s\n%s\n' "$TS.000001 STATE scene=idle" "$TS.500001 EVENT key=listening lease=none" > "$LOG"
  LEDGER_F="$ROOT_/focus-violations.log"
  MANIFEST_LEDGER=1
  set_manifest absent absent
  set_status 0 0
  ledger_ok
  printf '{"xFrac":0.1,"feetFrac":0.0}\n' > "$ROOT_/state.json"
  echo 4242 > "$STUB/launchctl.1"; echo 4242 > "$STUB/launchctl.2"
  echo 777 > "$STUB/front.start"; echo 777 > "$STUB/front.now"
  set_windows 1 4242 100.0 200.0 48.0 48.0
  set_windows 2 4242 140.0 200.0 48.0 48.0
  : > "$STUB/scenario"
  sc_drag_cycle 25; sc_click_cycle 40; sc_click_cycle 50
  EXTRA_ENV=""; SECONDS_ARG=2
}

# set_manifest REC_AGENT_LOG REC_AGENT_LOG1: each "absent" or "<bytes> <sha256>"; "none" leaves the logbase line out
set_manifest() {
  {
    echo "schema 1"
    echo "file $ROOT_/bin/clawd-pet-agent"
    echo "dir $ROOT_"
    if [ "${MANIFEST_LEDGER:-1}" = 1 ]; then echo "file $ROOT_/focus-violations.log"; echo "file $ROOT_/focus-violations.log.partial"; fi
    echo "log $LOG"
    echo "log $LOG1"
    [ "$1" = none ] || echo "logbase $LOG $1"
    [ "$2" = none ] || echo "logbase $LOG1 $2"
    echo "end"
  } > "$ROOT_/manifest"
}
rec_of() { printf '%s %s' "$(/usr/bin/stat -f %z "$1")" "$(/usr/bin/shasum -a 256 < "$1" | cut -d' ' -f1)"; }
# set_status FOCUS_VIOLATIONS DISPLAY_CHANGES [LEDGER_FAILURES]: the running agent's status.json (pid 4242, the agent of the sandbox)
set_status() { printf '{"focusViolations":%s,"wakeCount":0,"displayChangeCount":%s,"scene":"idle","sourceBEnabled":false,"idleBudgetMode":false,"pid":4242%s}\n' "$1" "$2" "${3:+,\"ledgerFailures\":$3}" > "$STATUS"; }

# The focus-violation ledger of the sandbox: the header, and one BOOT line for the sandbox's agent (pid 4242).
LEDGER_HEADER='LEDGER 1 born=1792000000 how=install'
BOOT_4242='BOOT 1792000000.000100 pid=4242 counter=0 violations=0'
write_ledger() { printf '%s\n' "$@" > "$LEDGER_F"; }
ledger_ok() { write_ledger "$LEDGER_HEADER" "$BOOT_4242"; }
sc_ledger() { sc_append "$1" "$LEDGER_F" "$2"; }

W_TOM='WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10'
W_OFF='WINDOW 4242 3 0 0.0 0.0 1.0 1.0 52'
set_windows() { # n pid x y w h: window list number n with a decoy app window, an off-screen window of the agent and the panel
  { echo "$W_TOM"; echo "$W_OFF"; printf 'WINDOW %s 3 1 %s %s %s %s 51\n' "$2" "$3" "$4" "$5" "$6"; } > "$STUB/windows.$1"
}

# sc_append INDEX FILE TEXT: when the stub sampler reaches sample INDEX it appends TEXT and a newline to FILE
sc_append() {
  local cmd
  cmd="printf '%s\\n' $(printf '%q' "$3") >> $(printf '%q' "$2")"
  printf '%s shell %s\n' "$1" "$cmd" >> "$STUB/scenario"
}
sc_shell() { printf '%s shell %s\n' "$1" "$2" >> "$STUB/scenario"; }
sc_input() { SEQ=$((SEQ + 1)); sc_append "$1" "$LOG" "$(printf '%s.%06d INPUT kind=%s tag=0000000000000000 src=0' "$TS" "$((SEQ + 10))" "$2")"; }
sc_click_cycle() { sc_input "$1" mouseDown; sc_input "$(( $1 + 2 ))" mouseUp; }
sc_drag_cycle() { sc_input "$1" mouseDown; sc_input "$(( $1 + 1 ))" mouseDragged; sc_input "$(( $1 + 2 ))" mouseDragged; sc_input "$(( $1 + 3 ))" mouseDragged; sc_input "$(( $1 + 4 ))" mouseUp; }
sc_clear() { : > "$STUB/scenario"; }

run_check() { # extra arguments -> OUT (stdout), RC, JSON (the evidence file)
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
    CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" $EXTRA_ENV \
    "$CHECK_BASH" "$SCRIPT" --seconds "$SECONDS_ARG" "$@" 2>"$SB/stderr")"
  RC=$?
  JSON="$(ls "$SB"/evidence/attended-check-*.json 2>/dev/null | head -n 1)"
}
jget() { /usr/bin/plutil -extract "$1" raw -o - "$JSON" 2>/dev/null; }
codes() { /usr/bin/plutil -extract "$1" json -o - "$JSON" 2>/dev/null | tr -d '[]" ' | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort | paste -sd, -; }
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

# expect LABEL VERDICT EXIT FAIL-CODES NOTRUN-CODES (comma lists; empty = none)
expect() {
  local label="$1" verdict="$2" rc="$3" fc="$4" nc="$5"
  check "$label: verdict $verdict" equals "$(jget verdict)" "$verdict"
  check "$label: exit $rc" equals "$RC" "$rc"
  check "$label: fail codes [$fc]" equals "$(codes fail_codes)" "$fc"
  check "$label: not-run codes [$nc]" equals "$(codes notrun_codes)" "$nc"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "attended-check: $verdict"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: launchctl was only ever asked to list" bash -c "[ ! -s '$STUB/launchctl.violations' ] && ! grep -v '^launchctl list ' '$STUB/launchctl.calls'"
}

# ---- scenarios -----------------------------------------------------------------------------------------------------------------------

scn_pass_baseline() {
  new_sandbox pass-baseline; run_check
  expect "baseline" PASS 0 "" ""
  check "baseline: 3 mouseDown, 3 mouseDragged, 3 mouseUp counted from the window offset" bash -c "[ \"$(jget window.input_mouseDown)\" = 3 ] && [ \"$(jget window.input_mouseDragged)\" = 3 ] && [ \"$(jget window.input_mouseUp)\" = 3 ]"
  check "baseline: the drag sequence completed" equals "$(jget window.drag_sequence_completed)" true
  check "baseline: the panel moved 40.0 pt" num_eq "$(jget panel.origin_moved_pt)" 40
  check "baseline: ... and read at an equal size" equals "$(jget panel.size_equal)" true
  check "baseline: history proved, offset 0 (both logs absent at install)" bash -c "[ \"$(jget history.proved)\" = true ] && [ \"$(jget history.since_install_offset_bytes)\" = 0 ]"
  check "baseline: no FOCUS_VIOLATION anywhere" bash -c "[ \"$(jget history.focus_violation_lines_since_install)\" = 0 ] && [ \"$(jget window.focus_violation_lines)\" = 0 ]"
  check "baseline: the agent was never the frontmost app" equals "$(jget samples.agent_frontmost)" 0
  check "baseline: the longest sampler gap is the 20 ms tick" equals "$(jget samples.max_gap_ms)" 20
  check "baseline: more than 50 samples" bash -c "[ \"$(jget samples.count)\" -gt 50 ]"
  check "baseline: the agent pid was read twice and is the same" bash -c "[ \"$(jget agent_pid.start)\" = 4242 ] && [ \"$(jget agent_pid.end)\" = 4242 ]"
  check "baseline: status counters recorded at both ends" bash -c "[ \"$(jget status_json.focusViolations_start)\" = 0 ] && [ \"$(jget status_json.displayChangeCount_end)\" = 0 ]"
  check "baseline: the evidence names its scope (activation outside the agent; key/main by the agent's own notifications; no external key-window claim)" bash -c "s=\"$(jget scope)\"; case \"\$s\" in *'observed outside the agent'*'frontmost application'*'agent'*'own notifications'*'External observation of the key window is not claimed'*) exit 0 ;; *) exit 1 ;; esac"
  check "baseline: stdout prints the same scope" contains "$OUT" "External observation of the key window is not claimed"
  check "baseline: stdout asks the user to click and drag Clawd while typing in another app, with the seconds" contains "$OUT" "click and drag Clawd a few times while typing in another app; 2 s"
  check "baseline: stdout counts down 2 then 1" equals "$(printf '%s\n' "$OUT" | grep '^attended-check: [0-9]* s left$' | tr '\n' '|')" "attended-check: 2 s left|attended-check: 1 s left|"
  check "baseline: the window's INPUT lines are kept as evidence" bash -c "[ \"\$(grep -c ' INPUT ' '$(jget files.window_input_lines)')\" = 9 ]"
  check "baseline: the samples are kept as evidence" bash -c "[ \"\$(grep -c '^[0-9]' '$(jget files.samples)')\" -gt 50 ]"
  spid="$(head -n 1 "$(jget files.samples)" | sed 's/^SAMPLING pid=//')"
  check "baseline: the sampler the script started is gone when it exits" bash -c "case '$spid' in ''|*[!0-9]*) exit 1 ;; esac; ! kill -0 '$spid' 2>/dev/null"
}

scn_pass_retained_logs() {
  # Both logs were retained at install. Their old lines (no FOCUS_VIOLATION among them) predate the install: they do not count as input, and
  # the install-time proof of the logs holds, which is supporting detail of the history report.
  new_sandbox pass-retained
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.100001 INPUT kind=mouseDown tag=0000000000000000 src=0" > "$LOG"
  printf '%s\n' "older generation" "with a FOCUS_VIOLATION word" > "$LOG1"
  set_manifest "$(rec_of "$LOG")" "$(rec_of "$LOG1")"
  retained_bytes="$(/usr/bin/stat -f %z "$LOG")"
  run_check
  expect "retained logs" PASS 0 "" ""
  check "retained logs: the since-install offset is the recorded size of agent.log" equals "$(jget history.since_install_offset_bytes)" "$retained_bytes"
  check "retained logs: the install-time proof holds, neither log changed in content" equals "$(jget history.proved)" true
  check "retained logs: no FOCUS_VIOLATION line in the retained logs" equals "$(jget ledger.retained_logs.focus_violation_lines)" 0
  check "retained logs: only the window's own 3 mouseDown count (the old INPUT line does not)" equals "$(jget window.input_mouseDown)" 3
}
scn_fail_retained_old_violation() {
  # A FOCUS_VIOLATION line in a retained log, from before this window and with the install-time proof holding: the whole retained content
  # is scanned, so it is a FAIL (a past violation is not forgiven by a clean window).
  new_sandbox fail-retained-old
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.200001 FOCUS_VIOLATION trigger=click notification=NSWindowDidBecomeKeyNotification" > "$LOG"
  set_manifest "$(rec_of "$LOG")" absent
  run_check
  expect "an old FOCUS_VIOLATION line in a retained agent.log with the install-time proof holding" FAIL 1 "focus-violation-line" ""
  check "old retained violation: the install-time proof held and did not excuse it" equals "$(jget history.proved)" true
}

# ---- FAIL rows ----
scn_fail_counter() {
  new_sandbox fail-counter; set_status 2 0; run_check
  expect "focusViolations 2 at the start, no log line" FAIL 1 "focusViolations-nonzero" ""
  check "focusViolations: the counter is reported" equals "$(jget status_json.focusViolations_start)" 2
}
scn_fail_counter_in_window() {
  new_sandbox fail-counter-window
  sc_shell 15 "printf '{\"focusViolations\":1,\"wakeCount\":0,\"displayChangeCount\":0,\"scene\":\"idle\",\"sourceBEnabled\":false,\"idleBudgetMode\":false}\n' > $(printf '%q' "$STATUS")"
  run_check
  expect "focusViolations becomes 1 during the window" FAIL 1 "focusViolations-nonzero" ""
}
scn_fail_line_stale_counter() {
  new_sandbox fail-line-stale
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  run_check
  expect "a FOCUS_VIOLATION line since install with a stale zero counter" FAIL 1 "focus-violation-line" ""
  check "stale counter: the counter really is 0" equals "$(jget status_json.focusViolations_end)" 0
  check "stale counter: the history count is 1" equals "$(jget history.focus_violation_lines_since_install)" 1
}
scn_fail_line_in_window() {
  new_sandbox fail-line-window
  sc_append 12 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeMainNotification"
  run_check
  expect "a FOCUS_VIOLATION line in the window" FAIL 1 "focus-violation-line" ""
  check "FOCUS_VIOLATION in the window: counted in the window and in the history" bash -c "[ \"$(jget window.focus_violation_lines)\" = 1 ] && [ \"$(jget history.focus_violation_lines_since_install)\" = 1 ]"
}
scn_fail_agent_frontmost() {
  new_sandbox fail-front
  printf '%s front 4242\n%s front 777\n' 15 17 >> "$STUB/scenario"
  run_check
  expect "the agent's pid is frontmost in a sample" FAIL 1 "agent-frontmost" ""
  check "agent frontmost: the samples that showed it are counted" bash -c "[ \"$(jget samples.agent_frontmost)\" -ge 1 ]"
}
scn_fail_agent_seen_by_the_sampler_alone() {
  # One sample names the agent and the system's answer never does, so no independent look can see it: only the sampler's own count of
  # agent samples makes this a FAIL (mutation row attended-agent-frontmost-ignored). A look that lands on that sample disagrees once with a
  # pid that is not the agent's, which the window tolerates. Not expect(): when load delays the next sample past two looks, both disagree
  # and the window also says sampler-stale (Codex on a2c9368, MINOR); the claim here is the FAIL and its code, so that one not-run code is
  # tolerated and FAIL still outranks it.
  local label="the sampler alone names the agent's pid in one sample"
  new_sandbox fail-front-sampler-only
  printf '%s sampler 4242\n%s sampler 777\n' 15 16 >> "$STUB/scenario"
  run_check
  check "$label: verdict FAIL" equals "$(jget verdict)" FAIL
  check "$label: exit 1" equals "$RC" 1
  check "$label: fail codes [agent-frontmost]" equals "$(codes fail_codes)" "agent-frontmost"
  check "$label: not-run codes empty, or sampler-stale alone (two looks on that sample)" bash -c "case '$(codes notrun_codes)' in ''|sampler-stale) exit 0 ;; *) exit 1 ;; esac"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "attended-check: FAIL"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: launchctl was only ever asked to list" bash -c "[ ! -s '$STUB/launchctl.violations' ] && ! grep -v '^launchctl list ' '$STUB/launchctl.calls'"
  check "sampler alone: no independent look named the agent" equals "$(jget sampler_freshness.independent_looks_naming_the_agent)" 0
}
scn_fail_agent_frontmost_at_start() {
  new_sandbox fail-front-start; echo 4242 > "$STUB/front.start"; run_check
  expect "the agent's pid is frontmost from the first sample" FAIL 1 "agent-frontmost" ""
}
scn_fail_agent_frontmost_after_last_input() {
  # The last INPUT line is at sample 52; the agent is frontmost at sample 92 (800 ms later). Sampling must run on for 1 s after the last INPUT line.
  new_sandbox fail-front-late
  printf '%s front 4242\n%s front 777\n' 92 94 >> "$STUB/scenario"
  run_check
  expect "the agent is frontmost 800 ms after the last INPUT line" FAIL 1 "agent-frontmost" ""
}
scn_fail_beats_notrun() {
  new_sandbox fail-beats-notrun; set_status 1 0; sc_clear; sc_input 25 mouseDown; run_check
  expect "a nonzero counter with one click only" FAIL 1 "focusViolations-nonzero" "no-drag-sequence,too-few-mousedowns"
}
scn_fail_with_history_incomplete() {
  new_sandbox fail-hist-incomplete; set_manifest none none
  sc_append 12 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeKeyNotification"
  run_check
  expect "a FOCUS_VIOLATION line in the window while the install-time proof is unavailable" FAIL 1 "focus-violation-line" ""
  check "unavailable proof: the since-install count is not reported (null)" equals "$(jget history.focus_violation_lines_since_install)" ""
}
scn_old_violation_history_incomplete() {
  # The isolating fixture's twin (the violation sits in agent.log): the install-time proof is unavailable and the retained-log scan must
  # still find it. It is the only source: the ledger is clean, the counter is 0, no ledgerFailures, sampling is clean.
  new_sandbox old-violation-hist; set_manifest none none
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  run_check
  expect "a violation only in the retained agent.log, the install-time proof unavailable" FAIL 1 "focus-violation-line" ""
  check "agent.log twin: the proof really was unavailable" equals "$(jget history.proved)" false
  check "agent.log twin: the counter is 0 and the ledger holds no violation" bash -c "[ \"$(jget status_json.focusViolations_end)\" = 0 ] && [ \"$(jget ledger.violation_lines_end)\" = 0 ]"
}
scn_fail_retained_log1_violation_proof_failed() {
  # The isolating fixture: the violation is only in a retained agent.log.1, the ledger is clean, status.json says 0 and has no ledgerFailures,
  # sampling is clean, and the install-time proof failed (agent.log.1's hash differs from its record). No other FAIL path can mask it.
  new_sandbox fail-log1-isolated
  printf '%s\n' "older generation one" "older generation two" > "$LOG1"
  set_manifest absent "$(rec_of "$LOG1")"
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG1"
  run_check
  expect "a violation only in a retained agent.log.1, the install-time proof failed" FAIL 1 "focus-violation-line" ""
  check "isolated log scan: the proof really failed" equals "$(jget history.proved)" false
  check "isolated log scan: the ledger holds no violation and status.json says 0" bash -c "[ \"$(jget ledger.violation_lines_end)\" = 0 ] && [ \"$(jget status_json.focusViolations_start)\" = 0 ] && [ \"$(jget status_json.focusViolations_end)\" = 0 ]"
  check "isolated log scan: the retained scan found exactly the one line" equals "$(jget ledger.retained_logs.focus_violation_lines)" 1
}

# ---- NOT RUN rows: preconditions ----
scn_nr_no_manifest() {
  new_sandbox nr-no-manifest; rm -- "$ROOT_/manifest"; run_check
  expect "no manifest" "NOT RUN" 3 "" "not-installed"
  check "no manifest: nothing was sampled (the window did not run)" equals "$(jget window_ran)" false
}
scn_nr_no_plist() {
  new_sandbox nr-no-plist; rm -- "$SB/home/Library/LaunchAgents/$LABEL.plist"; run_check
  expect "no LaunchAgent plist" "NOT RUN" 3 "" "not-installed"
}
scn_nr_not_loaded() {
  new_sandbox nr-not-loaded; echo unloaded > "$STUB/launchctl.1"; run_check
  expect "launchctl does not list the label" "NOT RUN" 3 "" "not-loaded"
  check "not loaded: no window list was asked for" bash -c "[ ! -e '$STUB/windows.count' ]"
}
scn_nr_no_pid() {
  new_sandbox nr-no-pid; echo nopid > "$STUB/launchctl.1"; run_check
  expect "loaded without a process" "NOT RUN" 3 "" "not-loaded"
}
scn_nr_status_missing() {
  new_sandbox nr-status-missing; rm -- "$STATUS"; run_check
  expect "no status.json" "NOT RUN" 3 "" "status-unreadable"
}
scn_nr_status_unreadable_at_the_end() {
  # status.json is there at the start and gone at the end of the window (the end counters are read after the last read of the stage window).
  new_sandbox nr-status-gone-end; sc_shell 60 "rm -- $(printf '%q' "$STATUS")"; run_check
  expect "status.json disappears during the window" "NOT RUN" 3 "" "status-unreadable"
}
scn_nr_status_incomplete() {
  new_sandbox nr-status-incomplete; printf '{"focusViolations":0,"scene":"idle"}\n' > "$STATUS"; run_check
  expect "status.json without displayChangeCount" "NOT RUN" 3 "" "status-unreadable"
}
scn_nr_panel_missing_start() {
  new_sandbox nr-panel-missing-start; { echo "$W_TOM"; echo "$W_OFF"; } > "$STUB/windows.1"; run_check
  expect "no on-screen window of the agent at the start" "NOT RUN" 3 "" "panel-not-found"
  check "no panel at the start: the window did not run" equals "$(jget window_ran)" false
}
scn_nr_panel_missing_end() {
  new_sandbox nr-panel-missing-end; { echo "$W_TOM"; echo "$W_OFF"; } > "$STUB/windows.2"; run_check
  expect "no on-screen window of the agent at the end" "NOT RUN" 3 "" "panel-not-found"
}
scn_nr_lister_fails_start() {
  new_sandbox nr-lister-start; : > "$STUB/windows.fail.1"; run_check
  expect "the window lister fails at the start" "NOT RUN" 3 "" "window-lister-failed"
}
scn_nr_lister_fails_end() {
  new_sandbox nr-lister-end; : > "$STUB/windows.fail.2"; run_check
  expect "the window lister fails at the end" "NOT RUN" 3 "" "window-lister-failed"
}
scn_nr_lister_truncated() {
  new_sandbox nr-lister-truncated; : > "$STUB/windows.truncated.1"; run_check
  expect "the window list has no footer (truncated)" "NOT RUN" 3 "" "window-lister-failed"
}
scn_nr_sampler_fails() {
  new_sandbox nr-sampler-fails; : > "$STUB/sampler.fail"; run_check
  expect "the sampler exits at once" "NOT RUN" 3 "" "sampler-failed"
}

# ---- NOT RUN rows: history ----
scn_nr_history_no_logbase() {
  new_sandbox nr-hist-none; set_manifest none none; run_check
  expect "the manifest has no logbase lines" PASS 0 "" ""
  check "the manifest has no logbase lines: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_manifest_incomplete() {
  new_sandbox nr-hist-noend; set_manifest absent absent; sed '$d' "$ROOT_/manifest" > "$ROOT_/manifest.cut"; mv "$ROOT_/manifest.cut" "$ROOT_/manifest"; run_check
  expect "the manifest has no end line" PASS 0 "" ""
  check "the manifest has no end line: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_rotated_same_size() {
  # agent.log.1 was retained at install; now it has the same size and different content (the log rotated since install).
  new_sandbox nr-hist-rotated
  printf '%s\n' "older generation, line one" "older generation, line two" > "$LOG1"
  set_manifest absent "$(rec_of "$LOG1")"
  printf '%s\n' "newer generation, line one" "newer generation, line two" > "$LOG1"
  run_check
  expect "agent.log.1 has its recorded size and different content" PASS 0 "" ""
  check "agent.log.1 has its recorded size and different content: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
  check "rotation since install: the report says the content differs" contains "$(jget history.agent_log_1)" "content differs"
}
scn_nr_history_log_prefix_differs() {
  new_sandbox nr-hist-prefix
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.500001 EVENT key=listening lease=none" > "$LOG"
  set_manifest "$(rec_of "$LOG")" absent
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.500001 EVENT key=listenXXX lease=none" > "$LOG"
  run_check
  expect "the first recorded bytes of agent.log differ (same size)" PASS 0 "" ""
  check "the first recorded bytes of agent.log differ (same size): the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_log_shorter() {
  new_sandbox nr-hist-shorter
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.500001 EVENT key=listening lease=none" > "$LOG"
  set_manifest "$(rec_of "$LOG")" absent
  printf '%s\n' "$TS.000001 STATE scene=idle" > "$LOG"
  run_check
  expect "agent.log is shorter than its recorded size" PASS 0 "" ""
  check "agent.log is shorter than its recorded size: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_log1_appeared() {
  new_sandbox nr-hist-log1-new; printf 'rotated in\n' > "$LOG1"; run_check
  expect "agent.log.1 was absent at install and exists now" PASS 0 "" ""
  check "agent.log.1 was absent at install and exists now: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_log1_gone() {
  new_sandbox nr-hist-log1-gone
  printf 'older generation\n' > "$LOG1"; set_manifest absent "$(rec_of "$LOG1")"; rm -- "$LOG1"; run_check
  expect "agent.log.1 was retained at install and is gone now" PASS 0 "" ""
  check "agent.log.1 was retained at install and is gone now: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_malformed() {
  new_sandbox nr-hist-malformed; set_manifest "banana" absent; run_check
  expect "a malformed logbase record" PASS 0 "" ""
  check "a malformed logbase record: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}
scn_nr_history_duplicate_record() {
  new_sandbox nr-hist-duplicate; set_manifest absent absent
  { sed '$d' "$ROOT_/manifest"; echo "logbase $LOG absent"; echo end; } > "$ROOT_/manifest.new"; mv "$ROOT_/manifest.new" "$ROOT_/manifest"
  run_check
  expect "two logbase records for the same log" PASS 0 "" ""
  check "two logbase records for the same log: the install-time proof is not available (supporting detail only)" equals "$(jget history.proved)" false
}

# ---- NOT RUN rows: the window ----
scn_nr_agent_pid_changed() {
  new_sandbox nr-pid-changed; echo 5555 > "$STUB/launchctl.2"; set_windows 2 5555 140.0 200.0 48.0 48.0; run_check
  expect "the agent's pid differs between the start and the end" "NOT RUN" 3 "" "agent-pid-changed"
}
scn_nr_agent_gone_at_end() {
  new_sandbox nr-pid-gone; echo unloaded > "$STUB/launchctl.2"; run_check
  expect "the agent is gone at the end" "NOT RUN" 3 "" "agent-pid-changed"
}
scn_nr_frontmost_unreadable() {
  new_sandbox nr-front-unreadable; printf '%s front -1\n%s front 777\n' 20 21 >> "$STUB/scenario"; run_check
  expect "one frontmost sample cannot be read" "NOT RUN" 3 "" "frontmost-read-failed"
}
scn_nr_gap_51() {
  new_sandbox nr-gap-51; printf '%s gap 31\n' 40 >> "$STUB/scenario"; run_check
  expect "a 51 ms gap between samples" "NOT RUN" 3 "" "sampler-gap"
  check "a 51 ms gap: the longest gap is reported" equals "$(jget samples.max_gap_ms)" 51
}
scn_pass_gap_50() {
  new_sandbox pass-gap-50; printf '%s gap 30\n' 40 >> "$STUB/scenario"; run_check
  expect "a gap of exactly 50 ms is allowed" PASS 0 "" ""
  check "gap 50: the longest gap is 50" equals "$(jget samples.max_gap_ms)" 50
}
scn_nr_frontmost_changed() {
  new_sandbox nr-front-changed; printf '%s front 888\n%s front 777\n' 25 26 >> "$STUB/scenario"; run_check
  expect "the frontmost app changes to another app" "NOT RUN" 3 "" "frontmost-changed"
}
scn_nr_display_changed() {
  new_sandbox nr-display
  sc_shell 15 "printf '{\"focusViolations\":0,\"wakeCount\":0,\"displayChangeCount\":1,\"scene\":\"idle\",\"sourceBEnabled\":false,\"idleBudgetMode\":false}\n' > $(printf '%q' "$STATUS")"
  run_check
  expect "displayChangeCount changes during the window" "NOT RUN" 3 "" "display-changed"
}
scn_nr_display_changed_during_the_end_re_read() {
  # The end read of the stage window finds another size (a drop motion is playing) and reads it again until the old size is back, up to 3 s.
  # During that re-read (the start of the 3rd window list) the display configuration changes: the stage window comes back at its old size,
  # moved by 40 pt (a move that reads as drag evidence), and displayChangeCount is 1. The old code read the counters BEFORE the re-read
  # and paired the old count (0) with the new position: PASS.
  new_sandbox nr-display-end-re-read
  set_windows 2 4242 140.0 200.0 120.0 80.0
  set_windows 4 4242 140.0 200.0 48.0 48.0
  printf '%s\n' "printf '{\"focusViolations\":0,\"wakeCount\":0,\"displayChangeCount\":1,\"scene\":\"idle\",\"sourceBEnabled\":false,\"idleBudgetMode\":false}\n' > $(printf '%q' "$STATUS")" > "$STUB/windows.hook.3"
  run_check
  expect "displayChangeCount changes while the end panel is re-read" "NOT RUN" 3 "" "display-changed"
  check "display change during the re-read: the panel came back at its old size ..." equals "$(jget panel.size_equal)" true
  check "display change during the re-read: ... moved by 40 pt (the evidence the old code would have used)" num_eq "$(jget panel.origin_moved_pt)" 40
  check "display change during the re-read: the end counter is the new one" equals "$(jget status_json.displayChangeCount_end)" 1
  check "display change during the re-read: the window really was re-read (4 window lists: the start, the end and two re-reads)" bash -c "[ \"\$(cat '$STUB/windows.count')\" -ge 4 ]"
}
scn_nr_two_mousedowns() {
  new_sandbox nr-two-downs; sc_clear; sc_drag_cycle 25; sc_click_cycle 40; run_check
  expect "two mouseDown only" "NOT RUN" 3 "" "too-few-mousedowns"
  check "two mouseDown: the count is 2" equals "$(jget window.input_mouseDown)" 2
}
scn_nr_old_input_lines() {
  # Six old INPUT lines (three downs, a drag, three ups) before the window, no input in the window, and the panel moved anyway.
  new_sandbox nr-old-input; sc_clear
  { printf '%s\n' "$TS.000001 STATE scene=idle"
    for k in 1 2 3; do printf '%s.%06d INPUT kind=mouseDown tag=0000000000000000 src=0\n' "$TS" "$k"; done
    printf '%s.000010 INPUT kind=mouseDragged tag=0000000000000000 src=0\n' "$TS"
    for k in 21 22 23; do printf '%s.%06d INPUT kind=mouseUp tag=0000000000000000 src=0\n' "$TS" "$k"; done
  } > "$LOG"
  run_check
  expect "old INPUT lines before the window and no input in it" "NOT RUN" 3 "" "no-drag-sequence,too-few-mousedowns"
  check "old INPUT lines: the window counted none" equals "$(jget window.input_mouseDown)" 0
}
scn_nr_no_drag_lines() {
  new_sandbox nr-no-drag; sc_clear; sc_click_cycle 25; sc_click_cycle 40; sc_click_cycle 50; run_check
  expect "three clicks, no drag line, and the panel moved" "NOT RUN" 3 "" "no-drag-sequence"
}
scn_nr_drag_without_up() {
  new_sandbox nr-drag-no-up; sc_clear; sc_click_cycle 25; sc_click_cycle 40; sc_input 50 mouseDown; sc_input 51 mouseDragged; sc_input 52 mouseDragged; run_check
  expect "the only drag has no mouseUp after it" "NOT RUN" 3 "" "no-drag-sequence"
}
scn_nr_drag_before_down() {
  new_sandbox nr-drag-order; sc_clear; sc_input 24 mouseDragged; sc_input 25 mouseUp; sc_click_cycle 40; sc_click_cycle 50; sc_click_cycle 60; run_check
  expect "a drag and an up that come before any down" "NOT RUN" 3 "" "no-drag-sequence"
}
scn_nr_panel_unmoved_jiggle() {
  # down, drag, up are logged, but the panel's on-screen origin did not move; state.json differs from before (it must not matter).
  new_sandbox nr-jiggle; set_windows 2 4242 100.0 200.0 48.0 48.0
  sc_shell 12 "printf '{\"xFrac\":0.5,\"feetFrac\":0.0}\n' > $(printf '%q' "$ROOT_/state.json")"
  run_check
  expect "a jiggle: down, drag, up and an unchanged panel origin, state.json changed" "NOT RUN" 3 "" "panel-not-moved"
  check "a jiggle: the origin moved 0 pt" num_eq "$(jget panel.origin_moved_pt)" 0
}
scn_nr_panel_moved_2_9() {
  new_sandbox nr-moved-2-9; set_windows 2 4242 102.9 200.0 48.0 48.0; run_check
  expect "the panel's origin moved 2.9 pt" "NOT RUN" 3 "" "panel-not-moved"
}
scn_nr_panel_moved_diagonal() {
  new_sandbox nr-moved-diag; set_windows 2 4242 102.1 202.1 48.0 48.0; run_check
  expect "the origin moved 2.1 pt on each axis (2.97 pt in all)" "NOT RUN" 3 "" "panel-not-moved"
}
scn_pass_panel_moved_3_0() {
  new_sandbox pass-moved-3; set_windows 2 4242 103.0 200.0 48.0 48.0; run_check
  expect "the panel's origin moved exactly 3.0 pt" PASS 0 "" ""
}
scn_pass_panel_moved_diagonal() {
  new_sandbox pass-moved-diag; set_windows 2 4242 102.2 202.2 48.0 48.0; run_check
  expect "the origin moved 3.11 pt in all, 2.2 pt on each axis" PASS 0 "" ""
}
# The stage window is taller while a drop motion plays (A3 after a drag: 3 more units, 1.75 to 1.92 s), and a drag at the end of the window
# can leave that motion playing when the end read happens. The end read is repeated every 0.2 s for 15 re-reads (3 s: the longest motion
# with margin). Window lists: 1 is the start, 2 the end read, 3 to 17 the 15 re-reads.
scn_nr_scene_changed() {
  new_sandbox nr-scene; set_windows 2 4242 140.0 200.0 120.0 80.0; run_check
  expect "the stage window's size differs between the reads, also at every re-read" "NOT RUN" 3 "" "scene-changed"
  check "scene changed: the window was read again for the whole grace (the start, the end and 15 re-reads: 17 window lists)" bash -c "[ \"\$(cat '$STUB/windows.count')\" -ge 17 ]"
}
scn_pass_scene_settles() {
  new_sandbox pass-scene-settles; set_windows 2 4242 140.0 200.0 120.0 80.0; set_windows 3 4242 140.0 200.0 48.0 48.0; run_check
  expect "the size differs at first and is equal at the re-read within the grace" PASS 0 "" ""
}
scn_pass_scene_settles_after_a_drop_motion() {
  # The motion ends 2.9 s after the end read: the size returns at the 15th and last re-read (window list 17).
  new_sandbox pass-scene-drop; set_windows 2 4242 140.0 200.0 120.0 80.0; set_windows 17 4242 140.0 200.0 48.0 48.0; run_check
  expect "the size returns at the last re-read of the 3 s grace (a drop motion that outlasts the 1 s of the old grace)" PASS 0 "" ""
}
scn_nr_scene_settles_too_late() {
  new_sandbox nr-scene-late; set_windows 2 4242 140.0 200.0 120.0 80.0; set_windows 18 4242 140.0 200.0 48.0 48.0; run_check
  expect "the size returns one re-read after the grace: it never returned in time" "NOT RUN" 3 "" "scene-changed"
}
scn_nr_rotation() {
  # agent.log is rotated at sample 20: the old file becomes agent.log.1, and the new agent.log holds more than the old size of
  # padding followed by a full set of clicks. Rotation is an expected event and never a gap: the ledger is the window's record, the
  # verdict is PASS, and the report carries the note.
  new_sandbox pass-rotation; sc_clear
  local pad new
  pad="$(printf 'STATE scene=idle padding line to make the new log longer than the old one....\n%.0s' 1 2 3)"
  new="$SB/new-log"
  { printf '%s\n' "$pad"; } > "$new"
  sc_shell 20 "mv $(printf '%q' "$LOG") $(printf '%q' "$LOG1") && cp $(printf '%q' "$new") $(printf '%q' "$LOG")"
  sc_drag_cycle 22; sc_click_cycle 40; sc_click_cycle 50
  run_check
  expect "agent.log is rotated during the window" PASS 0 "" ""
  check "rotation: the evidence says so" equals "$(jget window.rotated)" true
  check "rotation: ... as a note, not a gap" contains "$(jget window.log_window_rotated)" "not a gap"
  check "rotation: ... and the stdout carries the note log-window-rotated" contains "$OUT" "note log-window-rotated"
}
scn_nr_sampler_stalls() {
  new_sandbox nr-stall; printf '%s stall\n' 60 >> "$STUB/scenario"; SECONDS_ARG=2; run_check
  expect "the sampler stops producing but keeps running" "NOT RUN" 3 "" "sampler-stalled"
}
scn_nr_sampler_dies() {
  # The sampler exits at sample 70 without a footer. The window (6 s) outlasts it, so the clock is stale-but-enough at the end.
  new_sandbox nr-dies; sc_clear; sc_drag_cycle 25; sc_click_cycle 40; sc_click_cycle 50
  printf '%s die\n' 70 >> "$STUB/scenario"; SECONDS_ARG=6; run_check
  expect "the sampler dies before the window ends" "NOT RUN" 3 "" "sampler-stalled"
}

# ---- the observation window is the sampled window (carry-over finding 1) -------------------------------------------------------------------
# The script reads its start facts after the stub sampler's first samples and freezes its end facts while the sampler still runs. The
# lsappinfo stub's proof calls come at known points (calls 1 and 2 at the start of the window, 3 and 4 at its end, right after the end
# offset is frozen; the looks the script takes inside the window are counted apart), so a hook on one of them puts a line into agent.log
# at an exact moment of the script's run.
sc_hook() { printf '%s\n' "$2" > "$STUB/lsappinfo.hook.$1"; }
hook_lines() { # call-number, then INPUT kinds: the lines are appended to agent.log by the lsappinfo stub at that call
  local at="$1" kind cmd=""
  shift
  for kind in "$@"; do SEQ=$((SEQ + 1)); cmd="$cmd printf '%s\\n' $(printf '%q' "$(printf '%s.%06d INPUT kind=%s tag=0000000000000000 src=0' "$TS" "$((SEQ + 10))" "$kind")") >> $(printf '%q' "$LOG");"; done
  sc_hook "$at" "$cmd"
}
scn_nr_events_before_the_first_sample() {
  # Three clicks and a drag are logged before the sampler has written a sample (sample index 0), and the panel really moved afterwards.
  # They are outside the sampled window and must not count: the window sees no input at all.
  new_sandbox nr-before-first-sample; sc_clear
  sc_input 0 mouseDown; sc_input 0 mouseDragged; sc_input 0 mouseUp; sc_input 0 mouseDown; sc_input 0 mouseUp; sc_input 0 mouseDown; sc_input 0 mouseUp
  run_check
  expect "a drag and three clicks logged before the first sample" "NOT RUN" 3 "" "no-drag-sequence,too-few-mousedowns"
  check "events before the first sample: the window counted none of them" equals "$(jget window.input_mouseDown)" 0
  check "events before the first sample: the window's start offset is past them" bash -c "[ \"$(jget window.input_bytes_start)\" -gt \"$(/usr/bin/stat -f %z "$LOG1" 2>/dev/null || echo 0)\" ] && [ \"$(jget window.input_bytes_start)\" -ge 400 ]"
}
scn_pass_events_after_the_window_opened() {
  # The positive control: the same nine lines, appended right after the start facts were read (lsappinfo call 1), do count.
  new_sandbox pass-after-open; sc_clear
  hook_lines 1 mouseDown mouseDragged mouseUp mouseDown mouseUp mouseDown mouseUp
  run_check
  expect "lines appended right after the window opened count" PASS 0 "" ""
  check "events after the window opened: 3 mouseDown counted" equals "$(jget window.input_mouseDown)" 3
}
scn_nr_events_after_the_frozen_end() {
  # One drag cycle and one click cycle in the window (2 mouseDown), then the third click cycle is logged right after the end offset was
  # frozen (lsappinfo call 3), while the sampler is still running. It is not part of the window.
  new_sandbox nr-after-end; sc_clear; sc_drag_cycle 25; sc_click_cycle 40
  hook_lines 3 mouseDown mouseUp
  run_check
  expect "a third click logged after the end offset was frozen" "NOT RUN" 3 "" "too-few-mousedowns"
  check "events after the frozen end: only the 2 mouseDown of the window counted" equals "$(jget window.input_mouseDown)" 2
  check "events after the frozen end: the end offset is before the late lines (the file is longer than the window)" bash -c "[ \"\$(/usr/bin/stat -f %z '$LOG')\" -gt \"$(jget window.input_bytes_end)\" ]"
}
scn_fail_violation_after_the_frozen_end() {
  # A FOCUS_VIOLATION is not window input: it counts to the end of the file, wherever the script can see it.
  new_sandbox fail-after-end
  hook_lines 3 mouseDown
  sc_hook 3 "printf '%s\\n' '$TS.990001 FOCUS_VIOLATION trigger=click notification=NSWindowDidBecomeKeyNotification' >> $(printf '%q' "$LOG")"
  run_check
  expect "a FOCUS_VIOLATION logged after the end offset was frozen" FAIL 1 "focus-violation-line" ""
  check "violation after the frozen end: counted in the window's violation count (not only in the history)" equals "$(jget window.focus_violation_lines)" 1
}
scn_window_facts_are_inside_the_sampled_time() {
  new_sandbox window-facts; run_check
  expect "window facts" PASS 0 "" ""
  check "window facts: the sampled window starts after the first sample and ends after it starts" bash -c "[ \"$(jget window.sampled_ms_start)\" -ge 100000 ] && [ \"$(jget window.sampled_ms_end)\" -gt \"$(jget window.sampled_ms_start)\" ]"
  check "window facts: the input offsets bound the window (start before end)" bash -c "[ \"$(jget window.input_bytes_start)\" -lt \"$(jget window.input_bytes_end)\" ]"
  check "window facts: the frozen end offset is the size of agent.log at the end" equals "$(jget window.input_bytes_end)" "$(/usr/bin/stat -f %z "$LOG")"
  check "window facts: the sampler kept producing for at least 100 ms after the end facts were frozen (they are read before it is stopped)" bash -c "[ \$(( $(jget samples.last_ms) - $(jget window.sampled_ms_end) )) -ge 100 ]"
}

# ---- rotation: the rotated file is read as well (carry-over finding 2) ----------------------------------------------------------------------
rotate_cmd() { # new-log-file: rename agent.log to agent.log.1 and start a new agent.log from the given file
  printf 'mv %s %s && cp %s %s' "$(printf '%q' "$LOG")" "$(printf '%q' "$LOG1")" "$(printf '%q' "$1")" "$(printf '%q' "$LOG")"
}
scn_fail_rotation_after_violation() {
  new_sandbox fail-rot-after-violation
  printf 'STATE scene=idle padding line to make the new log differ from the old one....\n' > "$SB/new-log"
  sc_append 30 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeKeyNotification"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a FOCUS_VIOLATION recorded, then agent.log rotated before the end" FAIL 1 "focus-violation-line" ""
  check "rotation after a violation: the violation in the rotated file is counted" equals "$(jget window.rotated_file_focus_violation_lines)" 1
  check "rotation after a violation: the rotated file was identified by its inode (agent.log.1)" equals "$(jget window.rotated_file)" "$LOG1"
  check "rotation after a violation: the window's input lines (before the rotation) still count" equals "$(jget window.input_mouseDown)" 3
}
# ---- near agent.log's limit (amendment agent-log-retention: agent.log rotates at 3 MiB, so both retained files can hold about 3 MiB) -------
pad_log() { # FILE BYTES: idle STATE lines appended to FILE up to about BYTES (whole lines)
  /usr/bin/perl -e 'my ($f, $n, $ts) = @ARGV; open(my $h, ">>", $f) or die; my $l = "$ts.000002 STATE scene=idle padding near the agent log limit " . ("." x 64) . "\n"; print $h $l x int($n / length($l));' "$1" "$2" "$TS"
}
scn_pass_rotation_inside_the_window_near_the_limit() {
  # agent.log holds about 3 MiB when the window opens and rotates inside it: the rotated file and the new one are read as for a small log.
  new_sandbox pass-rot-near-limit
  pad_log "$LOG" 3140000
  printf 'STATE scene=idle padding line to make the new log differ from the old one....\n' > "$SB/new-log"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a 3 MiB agent.log rotating inside a clean window" PASS 0 "" ""
  check "near the limit: the rotated file was identified by its inode (agent.log.1)" equals "$(jget window.rotated_file)" "$LOG1"
  check "near the limit: the window's input lines before the rotation count" equals "$(jget window.input_mouseDown)" 3
}
scn_fail_retained_violation_at_the_end_of_a_near_limit_log1() {
  # A FOCUS_VIOLATION line after about 3 MiB of agent.log.1: the scan of the retained logs reads the whole file.
  new_sandbox fail-retained-near-limit
  pad_log "$LOG1" 3140000
  printf '%s\n' "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSWindowDidBecomeKeyNotification" >> "$LOG1"
  run_check
  expect "a FOCUS_VIOLATION line at the end of a 3 MiB retained agent.log.1" FAIL 1 "focus-violation-line" ""
  check "near-limit retained violation: found by the scan of the retained logs" equals "$(jget ledger.retained_logs.focus_violation_lines)" 1
}
scn_pass_history_proof_with_a_near_limit_log1() {
  # agent.log.1 of about 3 MiB retained at install and unchanged: the install-time proof holds as for a small file.
  new_sandbox pass-hist-near-limit
  pad_log "$LOG1" 3140000
  set_manifest "$(rec_of "$LOG")" "$(rec_of "$LOG1")"
  run_check
  expect "a 3 MiB agent.log.1 retained at install and unchanged" PASS 0 "" ""
  check "near-limit agent.log.1 unchanged since install: the install-time proof holds" equals "$(jget history.proved)" true
}
scn_nr_history_near_limit_log1_changed_at_its_end() {
  # agent.log.1 of about 3 MiB retained at install, then its last line replaced by another of the same length: same size, different content
  # only at the very end. The proof compares the hash of the whole recorded length, so it is no longer available.
  new_sandbox nr-hist-near-limit-end
  pad_log "$LOG1" 3140000
  printf '%s\n' "$TS.400001 STATE scene=idle the last line of generation A" >> "$LOG1"
  set_manifest "$(rec_of "$LOG")" "$(rec_of "$LOG1")"
  /usr/bin/perl -i -pe 's/generation A/generation B/ if eof' "$LOG1"
  check "near-limit agent.log.1 changed at its end: the fixture kept the size it was recorded with" equals "$(/usr/bin/stat -f %z "$LOG1")" "$(rec_of "$LOG1" | cut -d' ' -f1)"
  run_check
  expect "a 3 MiB agent.log.1 whose last line changed after install (same size)" PASS 0 "" ""
  check "near-limit agent.log.1 changed at its end: the install-time proof is not available" equals "$(jget history.proved)" false
}
scn_fail_rotation_violation_in_new_file() {
  # The new agent.log is SHORTER than the old one's start offset and holds the violation near its top: reading the new file from the
  # old offset would miss it.
  new_sandbox fail-rot-new-file
  printf 'STATE scene=idle padding line one to make the start offset large........................\nSTATE scene=idle padding line two to make the start offset large........................\n' >> "$LOG"
  printf '%s\n' "$TS.950001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$SB/new-log"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a violation near the top of a new, shorter agent.log" FAIL 1 "focus-violation-line" ""
  check "violation in a shorter new file: counted in the window" equals "$(jget window.focus_violation_lines)" 1
}
scn_fail_rotation_old_violation_since_install() {
  # A FOCUS_VIOLATION from before the window but since install (the counter is stale at 0), then a rotation: the rotated file carries it.
  new_sandbox fail-rot-since-install
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  printf 'STATE scene=idle new generation after rotation....................................\n' > "$SB/new-log"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a since-install violation in the file that is rotated away" FAIL 1 "focus-violation-line" ""
  check "since-install violation after a rotation: counted in the history" equals "$(jget history.focus_violation_lines_since_install)" 1
}
scn_fail_rotation_retained_violation_counts() {
  # Both logs were retained at install; the retained agent.log holds an old FOCUS_VIOLATION. A rotation moves that file to agent.log.1.
  # The whole retained content is scanned, whether or not the line lies before the recorded offset: it is a FAIL.
  new_sandbox fail-rot-retained
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.200001 FOCUS_VIOLATION trigger=click notification=NSWindowDidBecomeKeyNotification" > "$LOG"
  set_manifest "$(rec_of "$LOG")" absent
  printf 'STATE scene=idle new generation after rotation....................................\n' > "$SB/new-log"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a retained violation in the file that is rotated away" FAIL 1 "focus-violation-line" ""
  check "retained violation after a rotation: not in the window and not since the install offset, found by the retained scan" bash -c "[ \"$(jget history.focus_violation_lines_since_install)\" = 0 ] && [ \"$(jget window.rotated_file_focus_violation_lines)\" = 0 ] && [ \"$(jget ledger.retained_logs.focus_violation_lines)\" = 1 ]"
}
scn_nr_rotation_twice() {
  # Two rotations in the window, and the clicks were logged before them: agent.log.1 is no longer the file agent.log was at the start, so
  # the lines the first file held are gone and no click or drag can be proved. Rotation itself is no reason: the lost INPUT lines are.
  new_sandbox nr-rot-twice
  printf 'STATE scene=idle first new generation............................................\n' > "$SB/new-log"
  printf 'STATE scene=idle second new generation...........................................\n' > "$SB/new-log2"
  sc_shell 60 "$(rotate_cmd "$SB/new-log")"
  sc_shell 70 "$(rotate_cmd "$SB/new-log2")"
  run_check
  expect "agent.log rotated twice in the window, the clicks lost with the first file" "NOT RUN" 3 "" "no-drag-sequence,too-few-mousedowns"
  check "rotated twice: no rotated file is named" equals "$(jget window.rotated_file)" ""
}
scn_pass_rotated_twice_in_window() {
  # The amendment's fixture: agent.log rotates twice during the window, the ledger is clean, the counter is 0, sampling is clean, and the
  # clicks are in the file that survives: PASS. The report may carry the note log-window-rotated; it is never a verdict input.
  new_sandbox pass-rot-twice; sc_clear
  printf 'STATE scene=idle first new generation............................................\n' > "$SB/new-log"
  printf 'STATE scene=idle second new generation...........................................\n' > "$SB/new-log2"
  sc_shell 20 "$(rotate_cmd "$SB/new-log")"
  sc_shell 21 "$(rotate_cmd "$SB/new-log2")"
  sc_drag_cycle 25; sc_click_cycle 40; sc_click_cycle 50
  run_check
  expect "agent.log rotated twice during the window, ledger clean, counter 0, sampling clean" PASS 0 "" ""
  check "rotated twice: the note log-window-rotated is in the report" equals "$(jget window.rotated)" true
}

# ---- rotation after the end facts are frozen (Codex on the check scripts, finding a: the log is read AFTER the freeze) --------------------------
# The script freezes agent.log's size and inode while the sampler still runs, stops it, and only then reads the logs. agent.log reaches its
# size limit and rotates at any moment, so it can rotate between the freeze and the reads, or between two of the reads. The lsappinfo stub's
# 3rd proof call is the end check, right after the freeze (the looks inside the window are counted apart, see the stub).
shim_env() { EXTRA_ENV="PATH=$STUBS/shim:/usr/bin:/bin:/usr/sbin:/sbin"; }
scn_fail_rotation_after_the_freeze() {
  # A FOCUS_VIOLATION is in the window's log (the counter is a stale 0); agent.log rotates right after the end facts were frozen. The old
  # code believed the freeze (not rotated), read the INPUT bytes and the violations from the NEW agent.log, and never saw the violation.
  new_sandbox fail-rot-after-freeze
  printf 'STATE scene=idle padding line to make the new log differ from the old one....\n' > "$SB/new-log"
  sc_append 30 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeKeyNotification"
  sc_hook 3 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "a FOCUS_VIOLATION in the window, then agent.log rotated right after the end facts were frozen" FAIL 1 "focus-violation-line" ""
  check "rotation after the freeze: the violation in the rotated file is counted" equals "$(jget window.rotated_file_focus_violation_lines)" 1
  check "rotation after the freeze: the rotated file was identified by its inode (agent.log.1)" equals "$(jget window.rotated_file)" "$LOG1"
  check "rotation after the freeze: the window's INPUT lines are read from the rotated file" equals "$(jget window.input_mouseDown)" 3
  check "rotation after the freeze: the freeze itself saw no rotation (the same inode at both ends)" equals "$(jget window.agent_log_inode_start)" "$(jget window.agent_log_inode_end)"
  check "rotation after the freeze: the rotation is noted in the evidence" contains "$(jget window.log_window_rotated)" "not a gap"
}
scn_pass_rotation_after_the_freeze_without_a_violation() {
  # No violation: the rotation after the freeze is a note, never a gap; the INPUT lines are read from the rotated file.
  new_sandbox pass-rot-after-freeze
  printf 'STATE scene=idle padding line to make the new log differ from the old one....\n' > "$SB/new-log"
  sc_hook 3 "$(rotate_cmd "$SB/new-log")"
  run_check
  expect "agent.log rotated right after the end facts were frozen, no violation anywhere" PASS 0 "" ""
  check "rotation after the freeze, no violation: the rotation is noted" equals "$(jget window.rotated)" true
}
scn_fail_rotation_between_the_reads_of_the_analysis() {
  # The finding's own trigger. The freeze and the first look at the log generation are before the rotation, the INPUT bytes are read from
  # agent.log (the 3 clicks and the drag are all there), THEN agent.log rotates (the head shim runs the rotation right after that read),
  # and the FOCUS_VIOLATION read finds only the new agent.log. The old code said PASS here.
  new_sandbox fail-rot-between-reads; shim_env
  printf 'STATE scene=idle padding line to make the new log differ from the old one....\n' > "$SB/new-log"
  sc_append 30 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeKeyNotification"
  rotate_cmd "$SB/new-log" > "$STUB/head.hook"
  run_check
  expect "a FOCUS_VIOLATION in the window, agent.log rotates between the read of the INPUT bytes and the read of the violations" FAIL 1 "focus-violation-line" ""
  check "rotation between the reads: the shim did rotate agent.log (it is the new, short file now)" bash -c "[ -e '$STUB/head.hook.fired' ] && [ -f '$LOG1' ] && [ \"\$(grep -c FOCUS_VIOLATION '$LOG1')\" = 1 ] && ! grep -q FOCUS_VIOLATION '$LOG'"
  check "rotation between the reads: the violation in the rotated file is counted" equals "$(jget window.rotated_file_focus_violation_lines)" 1
  check "rotation between the reads: the analysis was repeated, so the INPUT lines come from the rotated file" equals "$(jget window.input_mouseDown)" 3
}
scn_pass_with_the_head_shim_and_no_rotation() {
  # The control of the test above: the same shim in PATH, nothing to run, no violation: the shim is transparent and the verdict is PASS.
  new_sandbox pass-head-shim; shim_env
  run_check
  expect "the head shim in PATH and no rotation" PASS 0 "" ""
}
scn_nr_log_keeps_rotating_while_it_is_read() {
  # agent.log rotates before every `tail -c +N` read from the end of the window on: no analysis ever sees one generation. The script must
  # stop trying (5 analyses), say so, and not PASS; it must not loop for ever.
  new_sandbox nr-rot-always; shim_env
  printf 'STATE scene=idle padding line to make each new log differ from the one before it.\n' > "$SB/new-log"
  printf '%s\n' "$(printf 'mv %s %s && cp %s %s' "$(printf '%q' "$LOG")" "$(printf '%q' "$LOG1")" "$(printf '%q' "$SB/new-log")" "$(printf '%q' "$LOG")")" > "$STUB/tail.hook"
  sc_hook 3 "touch $(printf '%q' "$STUB/tail.rotate")"
  run_check
  expect "agent.log rotates before every read of it after the end of the window" "NOT RUN" 3 "" "no-drag-sequence,too-few-mousedowns"
  check "a log that keeps rotating: the evidence says that no analysis saw one generation" contains "$(jget window.rotation_note)" "never read as one generation"
}

# ---- the sampler's frontmost value is live (finding "sampler freshness") -------------------------------------------------------------------
scn_nr_sampler_stale_at_the_end() {
  # The system's frontmost app is 888 at the end check (the 3rd proof call, right after the end facts are frozen) and the sampler keeps
  # reporting 777: a cached value. The looks inside the window all agreed (the stub's answer is 777 until then), so only the end check can
  # say NOT RUN.
  new_sandbox nr-stale-end; sc_hook 3 "printf '%s' 888 > $(printf '%q' "$STUB/front.now")"; run_check
  expect "the sampler keeps its old frontmost pid after the system's changed" "NOT RUN" 3 "" "sampler-stale"
  check "stale sampler: the evidence shows both pids at the end" contains "$(jget sampler_freshness.end)" "sampler=777 system=888"
  check "stale sampler: the start was consistent" contains "$(jget sampler_freshness.start)" "sampler=777 system=777"
}
scn_nr_sampler_stale_at_the_start() {
  # The system says 888 at the start check (the first proof call sets it; the check looks 5 times and gives up) and is back to 777 at the
  # first look inside the window: only the start check disagreed, the looks inside the window and the end check agree.
  new_sandbox nr-stale-start; sc_hook 1 "printf '%s' 888 > $(printf '%q' "$STUB/front.now")"; poll_world 1 777; run_check
  expect "the sampler disagrees with the system only at the start of the window" "NOT RUN" 3 "" "sampler-stale"
  check "stale sampler at the start: the end was consistent again" contains "$(jget sampler_freshness.end)" "sampler=777 system=777"
  check "stale sampler at the start: the evidence shows both pids" contains "$(jget sampler_freshness.start)" "sampler=777 system=888"
  check "stale sampler at the start: the script looked more than once before it gave up" bash -c "[ \"\$(grep -c 'lsappinfo front' '$STUB/lsappinfo.calls')\" -ge 5 ]"
}
scn_nr_system_front_unreadable() {
  # lsappinfo fails for the start check and works from the first look inside the window on (that look removes the failure file): only the
  # start check is unproven.
  new_sandbox nr-lsappinfo-fails; : > "$STUB/lsappinfo.fail"; printf '%s\n' "rm -- $(printf '%q' "$STUB/lsappinfo.fail")" > "$STUB/lsappinfo.poll.hook.1"; run_check
  expect "lsappinfo gives no answer" "NOT RUN" 3 "" "sampler-freshness-unproven"
  check "lsappinfo fails only at the start: the end check was fine" contains "$(jget sampler_freshness.end)" "sampler=777 system=777"
}
scn_nr_system_front_unreadable_at_the_end() {
  # lsappinfo works for the start check and the looks inside the window, and fails for the end check (the 3rd proof call creates the file).
  new_sandbox nr-lsappinfo-fails-end; sc_hook 3 "touch $(printf '%q' "$STUB/lsappinfo.fail")"; run_check
  expect "lsappinfo gives no answer at the end of the window" "NOT RUN" 3 "" "sampler-freshness-unproven"
  check "lsappinfo fails only at the end: the start check was fine" contains "$(jget sampler_freshness.start)" "sampler=777 system=777"
}
scn_pass_freshness_is_recorded() {
  new_sandbox pass-fresh; run_check
  expect "a live sampler" PASS 0 "" ""
  check "live sampler: start and end freshness are in the evidence" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
  check "live sampler: the window made looks of its own, and none disagreed" bash -c "[ \"$(jget sampler_freshness.window_looks)\" -ge 3 ] && [ \"$(jget sampler_freshness.window_longest_disagreement_looks)\" = 0 ] && [ \"$(jget sampler_freshness.window_longest_unreadable_looks)\" = 0 ]"
}
# poll_world CALL PID: the system's frontmost pid becomes PID at the start of the CALLth look-call (the stub counts the looks inside the window
# apart from the checks at the two ends; one look is two calls, front and info) while the stub sampler keeps printing its own pid.
poll_world() { printf '%s\n' "printf '%s' $2 > $(printf '%q' "$STUB/front.now")" > "$STUB/lsappinfo.poll.hook.$1"; }
scn_nr_sampler_cached_inside_the_window() {
  # The finding's trigger. The sampler keeps printing 777 (a cached pid) for the whole window. The system's frontmost app goes 777 -> 888
  # at the 3rd look and back to 777 at the 6th, so the two end checks both match (sampler=777 system=777) and the sampler shows no change.
  # The old code said PASS: it looked only at the two ends.
  new_sandbox nr-stale-inside; poll_world 5 888; poll_world 11 777; run_check
  expect "the system's frontmost app changes and returns inside the window, the sampler keeps its old pid, both end checks match" "NOT RUN" 3 "" "sampler-stale"
  check "stale sampler inside the window: both end checks matched (the finding's condition)" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
  check "stale sampler inside the window: the evidence names the disagreement and its length (3 looks in a row)" bash -c "[ \"$(jget sampler_freshness.window_longest_disagreement_looks)\" = 3 ] && [ \"$(jget sampler_freshness.window_disagreement)\" = 'sampler=777 system=888' ]"
  check "stale sampler inside the window: the sampler really showed no change (no frontmost-changed, the agent was never seen)" bash -c "[ \"$(jget samples.frontmost_changes)\" = 0 ] && [ \"$(jget samples.agent_frontmost)\" = 0 ]"
}
scn_pass_one_late_look_is_not_stale() {
  # The control: the system's answer differs from the sampler's at ONE look (the 3rd) and is back at the next: the lag of a sampler one
  # tick behind a real switch. STALE_LOOKS in a row are needed. The tolerance is for a pid that is NOT the agent's: with 4242 in place of
  # 888 the same single look is a FAIL (scn_fail_agent_seen_by_one_look_with_a_cached_sampler).
  new_sandbox pass-late-look; poll_world 5 888; poll_world 7 777; run_check
  expect "the system's answer differs from the sampler's at one look inside the window, and the pid is not the agent's" PASS 0 "" ""
  check "one late look: exactly one look disagreed" equals "$(jget sampler_freshness.window_longest_disagreement_looks)" 1
  check "one late look: no independent look named the agent" equals "$(jget sampler_freshness.independent_looks_naming_the_agent)" 0
}
scn_fail_agent_seen_by_one_look_with_a_cached_sampler() {
  # Codex c1 (Sprint 10 round 1). The sampler keeps printing 777 for the whole window (cached). The real frontmost goes 777 -> 4242 (the
  # agent) at the 3rd look and back at the 4th: one look inside the window sees the agent. The one-mismatch tolerance dropped it (the
  # longest disagreement is 1, STALE_LOOKS is 2) and the agent-frontmost count comes from the sampler's rows only, which show no 4242: PASS.
  new_sandbox fail-agent-one-look; poll_world 5 4242; poll_world 7 777; run_check
  expect "one independent look inside the window names the agent while the sampler keeps its old pid" FAIL 1 "agent-frontmost" ""
  check "agent seen by one look: the sampler showed nothing (no agent sample, no change): the look is the only evidence" bash -c "[ \"$(jget samples.agent_frontmost)\" = 0 ] && [ \"$(jget samples.frontmost_changes)\" = 0 ]"
  check "agent seen by one look: it was exactly one look, which the tolerance of one disagreement would have dropped" bash -c "[ \"$(jget sampler_freshness.window_longest_disagreement_looks)\" = 1 ] && [ \"$(jget sampler_freshness.independent_looks_naming_the_agent)\" = 1 ]"
  check "agent seen by one look: the reason names the independent look and where it was" bash -c "r=\"\$(/usr/bin/plutil -extract fail_reasons json -o - '$JSON')\"; case \"\$r\" in *'independent look'*'the first one at: window'*) exit 0 ;; *) exit 1 ;; esac"
}
scn_fail_agent_seen_by_the_end_check_with_a_cached_sampler() {
  # The same on the check at the end of the window: the system names the agent (4242), the sampler still says 777. The mismatch is NOT RUN
  # (sampler-stale), and the sighting is a FAIL on top of it.
  new_sandbox fail-agent-end-check; sc_hook 3 "printf '%s' 4242 > $(printf '%q' "$STUB/front.now")"; run_check
  expect "the end check's own look names the agent while the sampler keeps its old pid" FAIL 1 "agent-frontmost" "sampler-stale"
  check "agent seen by the end check: the sampler showed no agent sample" equals "$(jget samples.agent_frontmost)" 0
  check "agent seen by the end check: the look is counted, and the reason says it was at the end" bash -c "[ \"$(jget sampler_freshness.independent_looks_naming_the_agent)\" -ge 1 ] && case \"\$(/usr/bin/plutil -extract fail_reasons json -o - '$JSON')\" in *'the first one at: end '*) exit 0 ;; *) exit 1 ;; esac"
}
scn_fail_agent_seen_by_the_start_check_with_a_cached_sampler() {
  # And on the check at the start: the system names the agent at the start check (the first proof call sets it; the check looks 5 times
  # and gives up) and is back to 777 from the first look inside the window.
  new_sandbox fail-agent-start-check; sc_hook 1 "printf '%s' 4242 > $(printf '%q' "$STUB/front.now")"; poll_world 1 777; run_check
  expect "the start check's own look names the agent while the sampler keeps its old pid" FAIL 1 "agent-frontmost" "sampler-stale"
  check "agent seen by the start check: the reason says it was at the start" bash -c "case \"\$(/usr/bin/plutil -extract fail_reasons json -o - '$JSON')\" in *'the first one at: start '*) exit 0 ;; *) exit 1 ;; esac"
}
scn_nr_sampler_cached_while_the_end_panel_is_re_read() {
  # The same trigger as the next scenario with another app (888) instead of the agent: the cached sampler says 777 while the real frontmost
  # app is 888 for the looks of the end read (two or more in a row), and 777 again at the end check. Not a focus violation, but the
  # sampler has stopped following the system: NOT RUN sampler-stale. The looks of the end read count like the looks inside the window.
  new_sandbox nr-stale-end-re-read
  set_windows 2 4242 140.0 200.0 120.0 80.0
  set_windows 3 4242 140.0 200.0 120.0 80.0
  set_windows 4 4242 140.0 200.0 48.0 48.0
  printf '%s\n' "printf '%s' 888 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.3"
  printf '%s\n' "printf '%s' 777 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.4"
  run_check
  expect "the real frontmost app is another app only while the end panel is re-read, the sampler is cached" "NOT RUN" 3 "" "sampler-stale"
  check "another app only during the end re-read: both end checks matched" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
}
scn_nr_system_front_unreadable_during_the_end_re_read() {
  # lsappinfo answers for the start, the looks inside the window and the end check, and fails for every look of the end read (the file
  # stops only the end-read-poll calls): two unreadable looks in a row are an unproven sampler.
  new_sandbox nr-lsappinfo-fails-end-re-read; : > "$STUB/lsappinfo.endread.fail"; run_check
  expect "lsappinfo gives no answer for the looks of the end read" "NOT RUN" 3 "" "sampler-freshness-unproven"
  check "unreadable during the end read: the two end checks were fine" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
}
scn_fail_agent_seen_only_while_the_end_panel_is_re_read() {
  # Codex c2 (Sprint 10 round 1). The end read of the stage window finds another size (a drop motion is playing) and reads it again for up
  # to 3 s. The sampler keeps printing 777 (cached). The real frontmost app is 777 at every look of the window and at the check at the
  # end, and is the agent (4242) only from the start of the 3rd window list (the first re-read) until the start of the 4th: a change
  # A -> agent -> A that both the in-window looks and the end check miss when the looks stop at the end of the window. The old code
  # polled no look after collect_end began: PASS.
  new_sandbox fail-agent-end-re-read
  set_windows 2 4242 140.0 200.0 120.0 80.0
  set_windows 3 4242 140.0 200.0 120.0 80.0
  set_windows 4 4242 140.0 200.0 48.0 48.0
  printf '%s\n' "printf '%s' 4242 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.3"
  printf '%s\n' "printf '%s' 777 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.4"
  run_check
  expect "the real frontmost app is the agent only while the end panel is re-read, the sampler is cached" FAIL 1 "agent-frontmost" "sampler-stale"
  check "agent only during the end re-read: the two end checks both matched (the finding's condition)" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
  check "agent only during the end re-read: the sampler showed nothing, so only the looks of the end read saw it" bash -c "[ \"$(jget samples.agent_frontmost)\" = 0 ] && [ \"$(jget samples.frontmost_changes)\" = 0 ]"
  check "agent only during the end re-read: the stage window was re-read (4 window lists) and came back at its old size" bash -c "[ \"\$(cat '$STUB/windows.count')\" = 4 ] && [ \"$(jget panel.size_equal)\" = true ]"
  check "agent only during the end re-read: the reason says the sighting was in the end read" bash -c "case \"\$(/usr/bin/plutil -extract fail_reasons json -o - '$JSON')\" in *'the first one at: end-read'*) exit 0 ;; *) exit 1 ;; esac"
}
scn_nr_look_gap_a_slow_end_read_hides_a_switch_to_the_agent() {
  # Codex c2 (Sprint 10 round 2). The first read of the stage window at the end (window list 2) takes 3 s on a loaded machine, and the
  # real frontmost app is the agent (4242) only inside that read. The sampler keeps printing 777 (cached), and the looks just before and
  # just after the read both see 777. Round 2's code then said PASS. A stretch longer than LOOK_GAP_MAX_MS in which nothing independent
  # looked at the frontmost app is NOT RUN, look-gap.
  new_sandbox nr-look-gap-slow-end-read
  printf '%s\n' "printf '%s' 4242 > $(printf '%q' "$STUB/front.now"); sleep 3; printf '%s' 777 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.2"
  run_check
  expect "the agent is frontmost only inside a 3 s read of the stage window at the end, the sampler is cached" "NOT RUN" 3 "" "look-gap"
  check "look gap: no independent look named the agent (the finding's condition)" equals "$(jget sampler_freshness.independent_looks_naming_the_agent)" 0
  check "look gap: the longest gap between two looks is recorded and above the limit" bash -c "[ \"$(jget sampler_freshness.longest_gap_between_looks_ms)\" -gt 2000 ]"
}
scn_nr_look_gap_a_slow_start_read_hides_a_switch_to_the_agent() {
  # Codex (Sprint 10 fix a4c786a), start side. The read of the stage window at the start of the window (window list 1, after WIN_T0)
  # takes 3 s, and the real frontmost app is the agent only inside it; the start proof and every later look see 777. a4c786a started its
  # clock at the first look inside the window: PASS. The clock now starts when the window opens.
  new_sandbox nr-look-gap-slow-start-read
  printf '%s\n' "printf '%s' 4242 > $(printf '%q' "$STUB/front.now"); sleep 3; printf '%s' 777 > $(printf '%q' "$STUB/front.now")" > "$STUB/windows.hook.1"
  run_check
  expect "the agent is frontmost only inside a 3 s read of the stage window at the start, the sampler is cached" "NOT RUN" 3 "" "look-gap"
  check "look gap at the start: no independent look named the agent" equals "$(jget sampler_freshness.independent_looks_naming_the_agent)" 0
}
scn_nr_look_gap_a_slow_end_proof_hides_a_switch_to_the_agent() {
  # Codex (Sprint 10 fix a4c786a), end side. The look of the end proof (proof call 3, its `lsappinfo front`) takes 3 s, and the agent is
  # frontmost only inside it; the pid it then reads is 777. a4c786a stamped looks when they began and never timed the end proof: PASS.
  # A look is now stamped when it has returned, from the window's start to the end.
  new_sandbox nr-look-gap-slow-end-proof
  printf '%s\n' "printf '%s' 4242 > $(printf '%q' "$STUB/front.now"); sleep 3; printf '%s' 777 > $(printf '%q' "$STUB/front.now")" > "$STUB/lsappinfo.hook.3"
  run_check
  expect "the agent is frontmost only inside a 3 s look of the end proof, the sampler is cached" "NOT RUN" 3 "" "look-gap"
  check "look gap at the end: the end proof matched (the finding's condition)" bash -c "[ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ]"
}
scn_nr_look_gap_a_slow_unreadable_end_proof() {
  # Codex (on cfb70ce, MINOR): the end proof's look takes 3 s and then reads nothing, so no look is stamped after the end read; only the
  # closing measurement at the end of collect_end bounds that stretch.
  new_sandbox nr-look-gap-unreadable-end-proof
  printf '%s\n' "sleep 3; : > $(printf '%q' "$STUB/lsappinfo.fail")" > "$STUB/lsappinfo.hook.3"
  run_check
  expect "the end proof's look takes 3 s and reads nothing" "NOT RUN" 3 "" "look-gap,sampler-freshness-unproven"
}
scn_nr_look_gap_nothing_read_after_the_window_start() {
  # lsappinfo reads nothing at all (the start proof, which is taken inside the timed window, the looks, the end read's looks and the end
  # proof), so no look is ever stamped after the window start and only the closing measurement times the window: without it the longest
  # gap stays exactly 0, at any load (mutation row attended-closing-stretch-not-timed; Codex on a2c9368 and f18467b: a row that names a
  # gap threshold is defeated by a slow look inside the window).
  # Not expect(): its exact not-run codes would also fail on a load-made extra code (sampler-stalled; Codex on 4bd1114); this scenario's
  # claim is the two codes below and the gap.
  local label="no look after the window start reads anything"
  new_sandbox nr-look-gap-nothing-read-after-start; : > "$STUB/lsappinfo.fail"
  run_check
  check "$label: verdict NOT RUN" equals "$(jget verdict)" "NOT RUN"
  check "$label: exit 3" equals "$RC" 3
  check "$label: fail codes []" equals "$(codes fail_codes)" ""
  check "$label: the not-run codes include look-gap and sampler-freshness-unproven" bash -c "c=',$(codes notrun_codes),'; case \$c in *,look-gap,*) ;; *) exit 1 ;; esac; case \$c in *,sampler-freshness-unproven,*) exit 0 ;; esac; exit 1"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "attended-check: NOT RUN"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: launchctl was only ever asked to list" bash -c "[ ! -s '$STUB/launchctl.violations' ] && ! grep -v '^launchctl list ' '$STUB/launchctl.calls'"
  check "nothing read after the start: the longest gap is the timed window, which only the closing measurement measures" bash -c "[ \"$(jget sampler_freshness.longest_gap_between_looks_ms)\" -gt 0 ]"
}
scn_nr_system_front_unreadable_inside_the_window() {
  # lsappinfo answers at the two ends and fails for every look inside the window: 'the sampler is live' is then unproven for the window.
  new_sandbox nr-lsappinfo-fails-inside; : > "$STUB/lsappinfo.poll.fail"; run_check
  # Every look of the window read nothing, so from the start proof to the end proof nothing independent saw the frontmost app: look-gap
  # applies too (a look that read nothing is no observation).
  expect "lsappinfo gives no answer for the looks inside the window" "NOT RUN" 3 "" "look-gap,sampler-freshness-unproven"
  check "unreadable inside the window: the two end checks were fine" bash -c "[ \"$(jget sampler_freshness.start)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.end)\" = 'sampler=777 system=777' ] && [ \"$(jget sampler_freshness.window_longest_unreadable_looks)\" -ge 2 ]"
}

# ---- interrupts: the script stops its own sampler and writes a NOT RUN receipt ----
scn_interrupt() { # signal
  local sig="$1" pid out header spid
  new_sandbox "interrupt-$sig"
  out="$SB/out"
  if [ "$sig" = INT ]; then
    # a background job of a non-interactive shell ignores SIGINT; perl puts the default back before the exec so the script's trap can fire
    env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
      CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" ${SC_EXTRA_ENV:-} \
      /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$CHECK_BASH" "$SCRIPT" --seconds 30 > "$out" 2>&1 &
  else
    env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
      CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" ${SC_EXTRA_ENV:-} \
      "$CHECK_BASH" "$SCRIPT" --seconds 30 > "$out" 2>&1 &
  fi
  pid=$!
  wait_until 400 bash -c "grep -q 'click and drag Clawd' '$out'"
  header="$(cat "$SB"/evidence/attended-check-work/*/samples.txt 2>/dev/null | head -n 1)"
  spid="${header#SAMPLING pid=}"
  check "$sig: the script is inside its window and the stub sampler runs" bash -c "kill -0 '$pid' 2>/dev/null && kill -0 '$spid' 2>/dev/null"
  kill "-$sig" "$pid"
  wait "$pid"; RC=$?
  JSON="$(ls "$SB"/evidence/attended-check-*.json 2>/dev/null | head -n 1)"
  check "$sig: exit 3" equals "$RC" 3
  check "$sig: the receipt says NOT RUN with the reason interrupted" bash -c "[ \"$(jget verdict)\" = 'NOT RUN' ] && [ \"$(codes notrun_codes)\" = interrupted ]"
  check "$sig: the sampler the script started is gone" wait_until 100 bash -c "! kill -0 '$spid' 2>/dev/null"
  check "$sig: the verdict line is the last line" contains "$(tail -n 1 "$out")" "attended-check: NOT RUN (interrupted"
}

# SIGKILL cannot be trapped: the script leaves no receipt, and no PASS can come out of a killed run. The sampler it started is bounded by
# its own duration (the real one by SECONDS + 60; the stub by STUB_MAX_SAMPLES), so it does not outlive the run for ever.
scn_kill() {
  local pid out header spid
  new_sandbox kill; out="$SB/out"
  env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
    CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" STUB_MAX_SAMPLES=300 \
    "$CHECK_BASH" "$SCRIPT" --seconds 30 > "$out" 2>&1 &
  pid=$!
  wait_until 400 bash -c "grep -q 'click and drag Clawd' '$out'"
  header="$(cat "$SB"/evidence/attended-check-work/*/samples.txt 2>/dev/null | head -n 1)"
  spid="${header#SAMPLING pid=}"
  check "KILL: the script is inside its window and the stub sampler runs" bash -c "kill -0 '$pid' 2>/dev/null && kill -0 '$spid' 2>/dev/null"
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  check "KILL: no receipt of any verdict was written (nothing can claim PASS)" bash -c "! ls '$SB'/evidence/attended-check-*.json 2>/dev/null | grep -q ."
  check "KILL: no half-written receipt is left either" bash -c "! find '$SB/evidence' -name '.attended-check-*.partial.*' | grep -q ."
  check "KILL: the stub sampler stops on its own (it was bounded by its duration), it does not run for ever" wait_until 400 bash -c "! kill -0 '$spid' 2>/dev/null"
  kill "$spid" 2>/dev/null
}

# ---- the menu check (`--menu`): the scenarios of design sections 8.1 and 8.2 ------------------------------------------------------------
# Every event of a menu scenario is on the stub sampler's synthetic clock: 20 ms per sample, 100000 ms at sample 0, the agent's log lines, the
# sampler's CLICK lines, the frontmost application and the keys the user would type all keyed to it, so the order of events never depends on how
# fast the machine runs. T is the time of the first right-click; "T+x" is x seconds after it. A click's ET is the synthetic time of the
# physical click, so et order is event order; a CLICK written `late` keeps its ET and gets the clock then as its t.
# Baseline B (design 8.2): Clawd stands at B0, the menu M is 8 pt to its right. At T a right CLICK inside B0 (e1), the GEOM line that shows
# the menu, MENU open (gen 1); two hovers; at T+2.5 a left CLICK on the menu (e2), MENU pick, MENU close pick, GEOM without a menu; at T+2.8
# MENU write exit 0; at T+4.0 the second opening (e3, gen 2); at T+5.0 a left CLICK 40 pt left of B0 (e4) closes it (outside) and at T+5.1
# another application comes to the front. The check's X1 sees the menu window, prints word 1, and the keys stub types it 0.5 s later.
TI=70        # the sample index of T: 1.4 s after the first sample, so T-1.0 is still inside the window
BX=300       # the x of the body rectangle B0 (BX, 400, 40 x 30); the menu starts at BX + 48
CLICK_DY=0   # added to every CLICK y (scenario 29 puts the frame elsewhere)
tix() { /usr/bin/awk -v t="$1" -v b="$TI" 'BEGIN { printf "%d", int(b + t * 50 + 0.5) }'; }
tms() { echo $((100000 + $(tix "$1") * 20)); }
tet() { local m; m="$(tms "$1")"; printf '%d.%03d000' "$((m / 1000))" "$((m % 1000))"; }
tet_us() { local m; m="$(tms "$1")"; printf '%d.%06d' "$((m / 1000))" "$(( (m % 1000) * 1000 + $2 ))"; }   # T, MICROSECONDS: the et of T plus a few microseconds
body_r() { echo "$1.0,400.0,40.0,30.0"; }
menu_r() { echo "$(($1 + 48)).0,380.0,236.0,257.0"; }
g_closed() { echo "none 296.0,396.0,48.0,48.0 $(body_r "$BX") $(body_r "$BX") none none"; }
g_open() { echo "none 296.0,380.0,288.0,257.0 $BX.0,380.0,284.0,257.0 $(body_r "$BX") $(menu_r "$BX") $1"; }
cy() { echo $(($1 + CLICK_DY)); }

sm_do() { printf '%s %s\n' "$(tix "$1")" "$2" >> "$STUB/scenario"; }      # at T+t run ACTION ARGS
sm_menu() { sm_do "$1" "menu $2"; }
sm_geom() { sm_do "$1" "geom $2"; }
sm_late() { sm_do "$1" "late $2 $3"; }                                         # t, MS, ACTION ARGS
sm_front() { sm_do "$1" "front $2"; }
sm_click() { sm_do "$1" "click $2 $3 $(cy "$4") ${5:-0} $(tet "${6:-$1}")"; } # t BUTTON X Y [CTRL [ET-time]]
sm_open() { # GEN T [HOW [BUTTON CTRL [LINE_T]]]: the right CLICK on the body, the GEOM line that shows the menu, MENU open
  local g="$1" t="$2" how="${3:-right}" btn ctrl lt="${6:-$2}"
  case "$how" in control) btn=left; ctrl=1 ;; *) btn=right; ctrl=0 ;; esac
  btn="${4:-$btn}"; ctrl="${5:-$ctrl}"
  sm_click "$t" "$btn" $((BX + 20)) 415 "$ctrl" "$t"
  sm_geom "$lt" "$(g_open "$g")"
  sm_menu "$lt" "open et=$(tet "$t") how=$how gen=$g"
}
sm_hover() { sm_menu "$2" "hover key=$3 value=$4 gen=$1"; }                    # GEN T KEY VALUE
sm_pick() { # GEN ID T KEY VALUE [LINE_T]: a left CLICK on the menu, MENU pick, MENU close pick, the GEOM line without a menu
  local lt="${6:-$3}"
  sm_click "$3" left $((BX + 168)) 500 0 "$3"
  sm_menu "$lt" "pick id=$2 et=$(tet "$3") key=$4 value=$5 gen=$1"
  sm_menu "$lt" "close reason=pick gen=$1"
  sm_geom "$lt" "$(g_closed)"
}
sm_write() { # ID GEN KEY VERB EXIT T [LATE_MS]
  local text="write id=$1 key=$3 verb=$4 exit=$5 gen=$2"
  if [ -n "${7:-}" ]; then sm_late "$6" "$7" "menu $text"; else sm_menu "$6" "$text"; fi
}
sm_outside() { # GEN T [FRONT_T [PID [LATE_MS]]]: a left CLICK 40 pt left of the body closes the menu (outside), another application comes to the front
  local g="$1" t="$2" ft="${3:-}" pid="${4:-5555}" late="${5:-}"
  sm_click "$t" left $((BX - 40)) 415 0 "$t"
  if [ -n "$late" ]; then
    sm_late "$t" "$late" "menu close reason=outside et=$(tet "$t") gen=$g"
    sm_late "$t" "$late" "geom $(g_closed)"
  else
    sm_menu "$t" "close reason=outside et=$(tet "$t") gen=$g"
    sm_geom "$t" "$(g_closed)"
  fi
  [ -z "$ft" ] || sm_front "$ft" "$pid"
}
mb_first() { # GEN: the first opening of B: hovers, the pick, its write
  sm_open "$1" 0
  sm_hover "$1" 0.6 walk on; sm_hover "$1" 0.9 motion normal
  sm_pick "$1" 1 2.5 walk on
  sm_write 1 "$1" walk walk+on 0 2.8
}
mb_keys() { printf 'prompt:1 500 WORD:1\n' > "$STUB/keys.react"; }
mb_base() { mb_first "${1:-1}"; sm_open "${2:-2}" 4.0; sm_outside "${2:-2}" 5.0 5.1 5555; mb_keys; }
set_menu_windows() { # BODY_X: windows 1 and 2 (the later lists answer like the last file): the decoy app, an off-screen window, the stage, the body
  local f
  for f in 1 2; do
    { echo "$W_TOM"; echo "$W_OFF"; echo "WINDOW 4242 3 1 296.0 380.0 400.0 300.0 51"; printf 'WINDOW 4242 3 1 %s.0 400.0 40.0 30.0 54\n' "${1:-300}"; } > "$STUB/windows.$f"
  done
}
new_menu_sandbox() { # NAME: a fake HOME with an installed, loaded pet; the seed GEOM line before the window; no drag
  new_sandbox "$1"
  BX=300; CLICK_DY=0
  set_menu_windows 300
  : > "$STUB/scenario"
  printf '%s\n' "$TS.000090 GEOM t=100.000 bubble=none stage=296.0,396.0,48.0,48.0 hit=$(body_r 300) body=$(body_r 300) menu=none menugen=none" >> "$LOG"
  SECONDS_ARG=30
}
menu_json_count() { /usr/bin/plutil -extract "$1" raw -o - "$JSON" 2>/dev/null; }   # a number inside the menu object of the evidence
mget() { jget "menu.$1"; }

scn_m_pass_baseline() {
  new_menu_sandbox m-pass-baseline; SECONDS_ARG=120
  mb_base
  run_check --menu
  expect "m_pass_baseline" PASS 0 "" ""
  check "m_pass_baseline: the five kinds are counted (2 right-clicks, 1 hover interval, 1 item click, 1 outside click, 1 typed word)" bash -c "[ \"$(mget counts.right_click)\" = 2 ] && [ \"$(mget counts.hover)\" = 1 ] && [ \"$(mget counts.item_click)\" = 1 ] && [ \"$(mget counts.outside_click)\" = 1 ] && [ \"$(mget counts.typing)\" = 1 ]"
  check "m_pass_baseline: calibration has 1 success and 0 misses" bash -c "[ \"$(mget calibration.successes)\" = 1 ] && [ \"$(mget calibration.misses)\" = 0 ]"
  check "m_pass_baseline: X1's cross-check matched" bash -c "[ \"$(mget x1_cross_check.mismatched)\" = 0 ] && [ \"$(mget x1_cross_check.prompts.0.result)\" = matched ]"
  check "m_pass_baseline: both intervals are frozen and keyed by gens 1 and 2" bash -c "[ \"$(mget intervals.0.gen)\" = 1 ] && [ \"$(mget intervals.0.frozen)\" = 1 ] && [ \"$(mget intervals.1.gen)\" = 2 ] && [ \"$(mget intervals.1.frozen)\" = 1 ]"
  check "m_pass_baseline: pick 1's completion is its write (exit 0)" bash -c "[ \"$(mget picks.0.completions)\" = 1 ] && [ \"$(mget picks.0.write_exit)\" = 0 ]"
  check "m_pass_baseline: one prompt, and keys.log holds word 1 only" bash -c "[ \"\$(grep -c '^PROMPT ' '$(jget files.prompts)')\" = 1 ] && [ \"\$(grep -c '^KEY ' '$(jget files.keys)')\" = 1 ] && [ \"\$(awk '\$1==\"KEY\"{print \$2}' '$(jget files.keys)')\" = \"\$(awk '\$1==\"PROMPT\"{print \$3}' '$(jget files.prompts)')\" ]"
  check "m_pass_baseline: the countdown ended early" equals "$(mget window.countdown_ended_early)" 1
  check "m_pass_baseline: the window froze at least 4 s of synthetic time after e4" bash -c "[ \$(( $(jget window.sampled_ms_end) - $(tms 5.0) )) -ge 4000 ]"
  check "m_pass_baseline: the sampler got the clicks argument" contains "$(cat "$STUB/sampler.args")" "sample"
  check "m_pass_baseline: ... as its last argument" bash -c "case \"\$(cat '$STUB/sampler.args')\" in *' clicks') exit 0 ;; *) exit 1 ;; esac"
  check "m_pass_baseline: every CLICK is accounted by a line (e1 and e3 by MENU open, e2 by the pick, e4 by its close)" bash -c "[ \"$(mget clicks.0.accounted_by)\" = line ] && [ \"$(mget clicks.1.accounted_by)\" = line ] && [ \"$(mget clicks.2.accounted_by)\" = line ] && [ \"$(mget clicks.3.accounted_by)\" = line ]"
  printf '%s\n' "$OUT" > "$SB/out.txt"
  check "m_pass_baseline: stdout prints the user's instruction list" contains "$OUT" "Right-click Clawd"
  check "m_pass_baseline: ... and the scope sentence of the menu mode" contains "$OUT" "listen-only mouse-down monitor"
  check "m_pass_baseline: the typing prompt was printed once, with the word" bash -c "[ \"\$(grep -c 'attended-check: type [a-z][a-z][a-z][a-z] and press Return' '$SB/out.txt')\" = 1 ]"
  check "m_pass_baseline: evidence 'placed': the pick and the outside close name their gens (1, 2), the two openings are not placed" bash -c "[ \"$(mget clicks.1.placed)\" = 1 ] && [ \"$(mget clicks.3.placed)\" = 2 ] && [ \"$(mget clicks.0.placed)\" = not-placed ] && [ \"$(mget clicks.2.placed)\" = not-placed ]"
  check "m_pass_baseline: evidence 'geoms_inside': no GEOM line lies inside either interval (a total of 0 each)" bash -c "[ \"$(mget intervals.0.geoms_inside_total)\" = 0 ] && [ \"$(mget intervals.1.geoms_inside_total)\" = 0 ] && [ \"\$(/usr/bin/plutil -extract menu.intervals.0.geoms_inside json -o - '$JSON')\" = '[]' ]"
  check "m_pass_baseline: evidence 'unaccounted': no click is unaccounted, so no click carries the nearest boundaries and candidates; e4 owns the T+5.1 transition as well as its close" bash -c "[ \"\$(/usr/bin/plutil -extract menu.unaccounted_clicks json -o - '$JSON')\" = '[]' ] && [ \"$(mget clicks.3.accounted_by_transition)\" = 'transition at $(tms 5.1)' ] && [ -z \"$(mget clicks.3.n13)\" ]"
  check "m_pass_baseline: evidence 'settle': deadline A is the anchor plus 4000 ms, it ended the settle, and the last test's stamp had passed it" bash -c "[ \"$(mget window.settle_ended_by)\" = deadline-A ] && [ \"$(mget window.settle.deadline_a_ms)\" = \"\$(( $(mget window.settle.anchor_ms) + 4000 ))\" ] && [ \"$(mget window.settle.stamp_at_the_last_test_ms)\" -ge \"$(mget window.settle.deadline_a_ms)\" ] && case \"\$(/usr/bin/plutil -extract menu.window.settle json -o - '$JSON')\" in *'\"pick_wait_deadline_ms\":null'*) exit 0 ;; *) exit 1 ;; esac"
}

scn_m_boundary_landing_at_500ms() {
  new_menu_sandbox m-landing-500; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_outside 2 5.0 5.5 5555; mb_keys
  run_check --menu
  expect "m_boundary_landing_at_500ms" PASS 0 "" ""
}

scn_m_boundary_menu_click_on_edge_band() {
  new_menu_sandbox m-edge-band; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_click 4.5 left "$((BX + 47)).5" 500 0 4.5      # 0.5 pt left of M's left edge (BX+48): in the gap, 7.5 pt from B0
  sm_do 4.5 "agent MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=0 why=menu-gap et=$(tet 4.5) gen=2"
  sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_boundary_menu_click_on_edge_band" PASS 0 "" ""
}

sm_windows_body() { # T X: from T+t on, the window lists show the body window at x
  local body="WINDOW 4242 3 1 $2.0 400.0 40.0 30.0 54"
  sm_do "$1" "shell { echo '$W_TOM'; echo '$W_OFF'; echo 'WINDOW 4242 3 1 296.0 380.0 400.0 300.0 51'; echo '$body'; } > '$STUB/windows.1'; cp '$STUB/windows.1' '$STUB/windows.2'"
}
sm_term() { sm_click "$1" left 700 600 0 "$1"; }     # a click on the terminal (or any application), far from Clawd and the menu

scn_m_walk_around_opens() {
  new_menu_sandbox m-walk-around; SECONDS_ARG=60
  sm_geom -1.0 "none 296.0,396.0,48.0,48.0 $(body_r 306) $(body_r 306) none none"      # Clawd walks before the first opening ...
  sm_geom -0.5 "$(g_closed)"                                                              # ... and stands at B0 when it opens
  mb_first 1
  BX=294; sm_geom 3.0 "$(g_closed)"; BX=288; sm_geom 3.5 "$(g_closed)"                     # ... and walks again after its close, before the next one
  sm_windows_body 3.5 288
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_walk_around_opens" PASS 0 "" ""
}

scn_m_late_close_line() {
  new_menu_sandbox m-late-close; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_outside 2 5.0 5.1 5555 1500; mb_keys
  run_check --menu
  expect "m_late_close_line" PASS 0 "" ""
}

scn_m_close_race_dictation() {
  new_menu_sandbox m-close-race; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_term 6.5
  sm_menu 6.8 "close reason=dictation gen=2"; sm_geom 6.8 "$(g_closed)"
  sm_menu 6.9 "stale kind=outside et=$(tet 6.5) gen=2 live=none"
  sm_open 3 9.0; sm_outside 3 10.0 10.1 5555; mb_keys
  run_check --menu
  expect "m_close_race_dictation" PASS 0 "" ""
}

scn_d_default_mode_ignores_menu_lines() {
  new_sandbox d-default-menu-lines
  sm_geom 0 "$(g_open 1) nowindow"; sm_menu 0 "open et=$(tet 0) how=right gen=1"
  sm_menu 0.4 "close reason=away gen=1"; sm_geom 0.4 "$(g_closed)"
  run_check
  expect "d_default_mode_ignores_menu_lines" PASS 0 "" ""
  check "d_default_mode_ignores_menu_lines: the sampler got no clicks argument" bash -c "case \"\$(cat '$STUB/sampler.args')\" in *clicks*) exit 1 ;; *) exit 0 ;; esac"
  check "d_default_mode_ignores_menu_lines: no reader was started, no prompt was made" bash -c "! ls '$SB'/evidence/attended-check-work/*/prompts.txt '$SB'/evidence/attended-check-work/*/keys.log 2>/dev/null | grep -q ."
  check "d_default_mode_ignores_menu_lines: the evidence has no menu object" equals "$(jget menu)" ""
}

scn_m_fail_click_taken_in_gap() {
  new_menu_sandbox m-fail-gap; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_click 4.5 left $((BX + 44)) 415 0 4.5      # the middle of the 8 pt gap between B0 (ends at BX+40) and M (starts at BX+48), inside their union
  sm_do 4.5 "agent MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=0 why=menu-gap et=$(tet 4.5) gen=2"
  sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_fail_click_taken_in_gap" FAIL 1 "click-taken-outside-hit-region" ""
}

scn_m_fail_late_lines_after_early_end() {
  new_menu_sandbox m-fail-late; SECONDS_ARG=120
  mb_base
  sm_click 5.5 right $((BX + 20)) 415 0 5.5                                        # e5
  sm_click 5.8 left $((BX + 48 + 236 + 20)) 500 0 5.8                              # e6: 20 pt right of M
  sm_term 6.0; sm_front 6.1 6666                                                   # e7
  sm_geom 9.0 "$(g_open 3)"; sm_menu 9.0 "open et=$(tet 5.5) how=right gen=3"      # the agent handles the three late, in order
  sm_do 9.2 "agent MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=0 why=menu-gap et=$(tet 5.8) gen=3"
  sm_menu 9.3 "close reason=outside et=$(tet 6.0) gen=3"; sm_geom 9.3 "$(g_closed)"
  run_check --menu
  expect "m_fail_late_lines_after_early_end" FAIL 1 "click-taken-outside-hit-region" ""
  check "m_fail_late_lines_after_early_end: the countdown had ended early (only deadline A held the window open)" equals "$(mget window.countdown_ended_early)" 1
}

scn_m_fail_menu_stayed_open() {
  new_menu_sandbox m-fail-stayed; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_term 6.5
  sm_outside 2 11.0 11.1 5555; mb_keys
  run_check --menu
  expect "m_fail_menu_stayed_open" FAIL 1 "menu-stayed-open" "click-unaccounted"
}

scn_m_fail_queued_pick_write_failed() {
  new_menu_sandbox m-fail-queued; SECONDS_ARG=60
  mb_first 1
  sm_open 2 4.0; sm_pick 2 2 4.3 bubble off
  sm_open 3 4.8; sm_pick 3 3 5.1 bubble on
  sm_open 4 5.6; sm_pick 4 4 5.9 bubble off; sm_menu 5.9 "drop id=3 by=4 gen=3"
  sm_write 2 2 bubble bubble+off 0 6.2
  sm_open 5 6.5; sm_outside 5 7.0 7.1 5555
  sm_write 4 4 bubble bubble+off 2 7.0 7000
  mb_keys
  run_check --menu
  expect "m_fail_queued_pick_write_failed" FAIL 1 "menu-write-failed" ""
}

scn_m_fail_menu_declared_after_close() {
  new_menu_sandbox m-fail-declared; SECONDS_ARG=60
  mb_base
  sm_geom 6.0 "$(g_open 3) nowindow"
  run_check --menu
  expect "m_fail_menu_declared_after_close" FAIL 1 "menu-left-after-close" "menu-state-unproven"
}

scn_m_fail_menu_window_left_after_close_then_write() {
  new_menu_sandbox m-fail-left; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on; sm_write 1 1 walk walk+on 0 2.8 2700
  sm_open 2 4.0
  sm_click 5.0 left $((BX - 40)) 415 0 5.0
  sm_menu 5.0 "close reason=outside et=$(tet 5.0) gen=2"; sm_geom 5.0 "$(g_closed) keepwindow"; sm_front 5.1 5555
  mb_keys
  run_check --menu
  expect "m_fail_menu_window_left_after_close_then_write" FAIL 1 "menu-left-after-close" ""
}

scn_m_nr_menu_not_used() {
  new_menu_sandbox m-nr-not-used; SECONDS_ARG=20
  sm_click 0 right $((BX + 20)) 415 0 0
  sm_do 0 "agent MOUSE-IGNORED kind=rightMouseDown tag=0000000000000000 src=0 why=unused et=$(tet 0)"
  run_check --menu
  expect "m_nr_menu_not_used" "NOT RUN" 3 "" "menu-not-used"
}

scn_m_nr_open_not_from_right_or_control() {
  new_menu_sandbox m-nr-not-right; SECONDS_ARG=60
  sm_open 1 0 control left 0
  sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on; sm_write 1 1 walk walk+on 0 2.8
  sm_open 2 4.0 control left 0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_open_not_from_right_or_control" "NOT RUN" 3 "" "right-click-unobserved"
}

scn_m_nr_one_hover_item() {
  new_menu_sandbox m-nr-one-hover; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 walk on
  sm_pick 1 1 2.5 walk on; sm_write 1 1 walk walk+on 0 2.8
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_one_hover_item" "NOT RUN" 3 "" "hover-unobserved"
}

scn_m_nr_write_saved_not_confirmed() {
  new_menu_sandbox m-nr-write-3; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on; sm_write 1 1 walk walk+on 3 2.8
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_write_saved_not_confirmed" "NOT RUN" 3 "" "item-click-unobserved"
}

scn_m_nr_pick_completion_missing() {
  new_menu_sandbox m-nr-completion; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on; sm_menu 2.8 "drop id=1 by=2 gen=1"
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_pick_completion_missing" "NOT RUN" 3 "" "item-click-unobserved,menu-write-missing"
  check "m_nr_pick_completion_missing: evidence 'settle': the pick wait ended the settle, at its numerical deadline (17 s after its anchor), later than deadline A" bash -c "[ \"$(mget window.settle_ended_by)\" = pick-wait ] && [ \"$(mget window.settle.pick_wait_deadline_ms)\" -gt \"$(mget window.settle.deadline_a_ms)\" ] && [ \"$(mget window.settle.stamp_at_the_last_test_ms)\" -ge \"$(mget window.settle.pick_wait_deadline_ms)\" ]"
}

scn_m_nr_outside_click_without_landing() {
  new_menu_sandbox m-nr-no-landing; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_outside 2 5.0; mb_keys
  run_check --menu
  expect "m_nr_outside_click_without_landing" "NOT RUN" 3 "" "outside-click-unobserved"
}

scn_m_nr_landing_520ms() {
  new_menu_sandbox m-nr-landing-520; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_outside 2 5.0 5.52 5555; mb_keys
  run_check --menu
  expect "m_nr_landing_520ms" "NOT RUN" 3 "" "frontmost-changed,outside-click-unobserved"
}

scn_m_nr_line_typed_before_open() {
  new_menu_sandbox m-nr-typed-before; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_outside 2 5.0 5.1 5555
  sm_do -0.5 "key 1500 hello"
  run_check --menu
  expect "m_nr_line_typed_before_open" "NOT RUN" 3 "" "typing-unobserved"
}

scn_m_nr_word_typed_after_close() {
  new_menu_sandbox m-nr-after-close; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.3 walk on; sm_hover 1 0.6 motion normal
  sm_menu 1.0 "close reason=away gen=1"; sm_geom 1.0 "$(g_closed)"
  sm_do 1.0 "key 1000 WORD:1"
  sm_open 2 5.0; sm_pick 2 1 5.5 walk on; sm_write 1 2 walk walk+on 0 5.8
  sm_open 3 7.0; sm_outside 3 8.0 8.1 5555
  run_check --menu
  expect "m_nr_word_typed_after_close" "NOT RUN" 3 "" "typing-unobserved"
}

scn_m_nr_word_typed_across_reopen() {
  new_menu_sandbox m-nr-across-reopen; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.3 walk on; sm_hover 1 0.6 motion normal
  sm_menu 1.0 "close reason=away gen=1"; sm_geom 1.0 "$(g_closed)"
  sm_open 2 1.5
  sm_do 1.0 "key 1500 WORD:1"
  sm_pick 2 1 3.0 walk on; sm_write 1 2 walk walk+on 0 3.3
  sm_open 3 4.5; sm_outside 3 5.5 5.6 5555
  run_check --menu
  expect "m_nr_word_typed_across_reopen" "NOT RUN" 3 "" "typing-unobserved"
}

scn_m_nr_menu_window_shown_late_and_briefly() {
  new_menu_sandbox m-nr-late-window; SECONDS_ARG=60
  sm_click 0 right $((BX + 20)) 415 0 0
  sm_geom 0 "$(g_open 1) windowlater 1500"; sm_menu 0 "open et=$(tet 0) how=right gen=1"
  sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_menu 2.5 "close reason=away gen=1"; sm_geom 2.5 "$(g_closed)"
  printf 'prompt:1 1700 WORD:1\n' > "$STUB/keys.react"
  sm_open 2 4.0; sm_pick 2 1 5.0 walk on; sm_write 1 2 walk walk+on 0 5.3
  sm_open 3 6.5; sm_outside 3 7.5 7.6 5555
  run_check --menu
  expect "m_nr_menu_window_shown_late_and_briefly" "NOT RUN" 3 "" "typing-unobserved"
}

scn_m_nr_reopen_click_missed_by_monitor() {
  new_menu_sandbox m-nr-missed; SECONDS_ARG=60
  mb_first 1
  sm_geom 4.0 "$(g_open 2)"; sm_menu 4.0 "open et=$(tet 4.0) how=right gen=2"        # no CLICK for e3
  sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_reopen_click_missed_by_monitor" "NOT RUN" 3 "" "click-monitor-missed"
}

scn_m_nr_menu_moved_while_open() {
  new_menu_sandbox m-nr-moved; SECONDS_ARG=60
  mb_base
  sm_open 3 6.0
  sm_click 6.3 left $((BX + 48 + 236 + 10)) 500 0 6.3
  sm_do 6.3 "agent MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=0 why=menu-gap et=$(tet 6.3) gen=3"
  sm_geom 6.5 "none 296.0,380.0,308.0,257.0 $BX.0,380.0,304.0,257.0 $(body_r "$BX") $((BX + 48)).0,380.0,256.0,257.0 3"      # the menu rect widened 20 pt
  sm_click 7.0 right $((BX + 20)) 415 0 7.0
  sm_menu 7.0 "close reason=toggle et=$(tet 7.0) gen=3"; sm_geom 7.0 "$(g_closed)"
  run_check --menu
  expect "m_nr_menu_moved_while_open" "NOT RUN" 3 "" "menu-geometry-unfrozen"
  check "m_nr_menu_moved_while_open: evidence 'geoms_inside': gen 3's interval holds the one GEOM line that differs, with its text" bash -c "[ \"$(mget intervals.2.geoms_inside_total)\" = 1 ] && [ \"$(mget intervals.2.geoms_inside.0.differs)\" = 1 ] && case \"$(mget intervals.2.geoms_inside.0.text)\" in *'menu=348.0,380.0,256.0,257.0 menugen=3') exit 0 ;; *) exit 1 ;; esac"
  check "m_nr_menu_moved_while_open: evidence 'placed': the menu-gap delivery names gen 3, the toggle close and the opening are not placed" bash -c "[ \"$(mget clicks.5.placed)\" = 3 ] && [ \"$(mget clicks.6.placed)\" = not-placed ]"
}

scn_m_nr_menu_open_at_window_start() {
  new_menu_sandbox m-nr-at-start; SECONDS_ARG=60
  printf '%s\n' "$TS.000091 GEOM t=100.200 bubble=none stage=296.0,380.0,288.0,257.0 hit=$BX.0,380.0,284.0,257.0 body=$(body_r "$BX") menu=$(menu_r "$BX") menugen=1" \
    "$TS.000092 MENU open et=99.000000 how=right gen=1" >> "$LOG"
  sm_menu -1.0 "close reason=away gen=1"; sm_geom -1.0 "$(g_closed)"
  mb_first 2; sm_open 3 4.0; sm_outside 3 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_menu_open_at_window_start" "NOT RUN" 3 "" "menu-geometry-unfrozen"
}

scn_m_nr_calibration_all_outside() {
  new_menu_sandbox m-nr-calib; SECONDS_ARG=60; CLICK_DY=-400
  mb_base
  run_check --menu
  expect "m_nr_calibration_all_outside" "NOT RUN" 3 "" "geometry-unproven,item-click-unobserved,outside-click-unobserved"
}

scn_m_nr_inside_pick_beside_a_calibration_miss() {   # round 3, item 1: kind 3 is gated by calibration as kind 4 is (design 5.5, 8.3 row 25)
  new_menu_sandbox m-nr-inside-pick-miss; SECONDS_ARG=60
  mb_first 1                                                                     # pick 1 is clearly inside menu=: a calibration success
  sm_open 2 4.0
  sm_click 4.5 left $((BX + 168)) 100 0 4.5                                     # pick 2: clearly outside body= and menu= (y 100): a calibration miss
  sm_menu 4.5 "pick id=2 et=$(tet 4.5) key=motion value=normal gen=2"; sm_menu 4.5 "close reason=pick gen=2"; sm_geom 4.5 "$(g_closed)"
  sm_write 2 2 motion motion+normal 0 4.8
  sm_open 3 6.0; sm_outside 3 7.0 7.1 5555; mb_keys
  run_check --menu
  expect "m_nr_inside_pick_beside_a_calibration_miss" "NOT RUN" 3 "" "geometry-unproven,item-click-unobserved,outside-click-unobserved"
  check "m_nr_inside_pick_beside_a_calibration_miss: calibration has 1 success and 1 miss" bash -c "[ \"$(mget calibration.successes)\" = 1 ] && [ \"$(mget calibration.misses)\" = 1 ] && [ \"$(mget calibration.proven)\" = 0 ]"
  check "m_nr_inside_pick_beside_a_calibration_miss: no item click is counted, the inside pick included" equals "$(mget counts.item_click)" 0
  check "m_nr_inside_pick_beside_a_calibration_miss: pick 1 says why" contains "$(mget picks.0.why)" "calibration is not proven"
}

scn_m_nr_x1_body_window_differs_from_geom() {
  new_menu_sandbox m-nr-x1; SECONDS_ARG=60
  set_menu_windows 304
  mb_base
  run_check --menu
  expect "m_nr_x1_body_window_differs_from_geom" "NOT RUN" 3 "" "geometry-unproven"
}

scn_m_nr_open_at_end_after_hover() {
  new_menu_sandbox m-nr-open-end; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0; sm_hover 2 4.5 walk on; mb_keys
  run_check --menu
  expect "m_nr_open_at_end_after_hover" "NOT RUN" 3 "" "menu-open-at-end,outside-click-unobserved"
}

scn_m_nr_undeclared_open() {
  new_menu_sandbox m-nr-undeclared; SECONDS_ARG=60
  mb_base
  sm_click 6.0 right $((BX + 20)) 415 0 6.0; sm_menu 6.0 "open et=$(tet 6.0) how=right gen=3"
  sm_click 6.5 right $((BX + 20)) 415 0 6.5; sm_menu 6.5 "close reason=toggle et=$(tet 6.5) gen=3"
  run_check --menu
  expect "m_nr_undeclared_open" "NOT RUN" 3 "" "menu-state-unproven"
}

scn_m_nr_unexplained_frontmost_change() {
  new_menu_sandbox m-nr-front; SECONDS_ARG=60
  mb_base; sm_front 3.2 6666
  run_check --menu
  expect "m_nr_unexplained_frontmost_change" "NOT RUN" 3 "" "frontmost-changed"
}

scn_m_menu_closed_by_itself_before_outside_click() {
  new_menu_sandbox m-closed-itself; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_menu 4.5 "close reason=away gen=2"; sm_geom 4.5 "$(g_closed)"
  sm_click 5.0 left $((BX - 40)) 415 0 5.0; sm_front 5.1 5555; mb_keys
  run_check --menu
  expect "m_menu_closed_by_itself_before_outside_click" "NOT RUN" 3 "" "outside-click-unobserved"
}

scn_m_rotation_during_menu_window() {
  # One rotation in the middle of the first opening: the open and the hovers are in the rotated file (agent.log.1), the pick and everything
  # after it in the new agent.log. Every menu action is recorded, so the rows are evaluated from the window's lines in both generations.
  new_menu_sandbox m-rotation; SECONDS_ARG=60
  mb_base
  printf 'STATE scene=idle new generation after the rotation, longer than nothing........\n' > "$SB/new-log"
  sm_do 1.5 "shell $(rotate_cmd "$SB/new-log")"
  run_check --menu
  expect "m_rotation_during_menu_window: one rotation mid-window, every menu action logged" PASS 0 "" ""
  check "m_rotation_during_menu_window: the rotation was seen, and the rotated file identified by its inode" bash -c "[ \"$(jget window.rotated)\" = true ] && [ \"$(jget window.rotated_file)\" = \"$LOG1\" ]"
  check "m_rotation_during_menu_window: the rows were evaluated (2 right-clicks, 1 item click, 1 outside click, 1 typed word), not only the writes" bash -c "[ \"$(mget counts.right_click)\" = 2 ] && [ \"$(mget counts.item_click)\" = 1 ] && [ \"$(mget counts.outside_click)\" = 1 ] && [ \"$(mget counts.typing)\" = 1 ]"
  check "m_rotation_during_menu_window: both generations' lines are in the analysed window (the open from agent.log.1, the pick from agent.log)" bash -c "f=\$(ls '$SB'/evidence/attended-check-work/*/menu-window-lines.txt | head -n 1); grep -q ' MENU open ' \"\$f\" && grep -q ' MENU pick ' \"\$f\" && grep -q 'new generation' \"\$f\""
}
scn_m_fail_menu_stayed_open_after_rotation() {
  # The same scenario as m_fail_menu_stayed_open with one rotation between the first opening and the second: the second opening's lines are
  # in the new agent.log, and the judgement of the stray click needs the first-seen bounds of those lines (the polls' sizes run on across
  # the rotation), so the verdict is the one without a rotation.
  new_menu_sandbox m-fail-stayed-rot; SECONDS_ARG=60
  mb_first 1
  printf 'STATE scene=idle new generation after the rotation, longer than nothing........\n' > "$SB/new-log"
  sm_do 3.2 "shell $(rotate_cmd "$SB/new-log")"
  sm_open 2 4.0
  sm_term 6.5
  sm_outside 2 11.0 11.1 5555; mb_keys
  run_check --menu
  expect "m_fail_menu_stayed_open_after_rotation" FAIL 1 "menu-stayed-open" "click-unaccounted"
  check "m_fail_menu_stayed_open_after_rotation: the rotation was seen" equals "$(jget window.rotated)" true
}
scn_m_nr_menu_lines_rotated_away() {
  # Two rotations in the window: the file agent.log was at the start is gone before it is read (agent.log.1 is the file of the first rotation's
  # successor), so the lines of the first part of the window are genuinely missing: NOT RUN, and the reason names the gap.
  new_menu_sandbox m-rotated-away; SECONDS_ARG=60
  mb_base
  printf 'STATE scene=idle new generation after the first rotation.......................\n' > "$SB/new-log"
  printf 'STATE scene=idle new generation after the second rotation......................\n' > "$SB/new-log2"
  sm_do 1.5 "shell $(rotate_cmd "$SB/new-log")"
  sm_do 1.7 "shell $(rotate_cmd "$SB/new-log2")"
  run_check --menu
  expect "m_nr_menu_lines_rotated_away: the start file's lines are gone before they were read" "NOT RUN" 3 "" "menu-log-gap"
  check "m_nr_menu_lines_rotated_away: the reason names the gap (the file agent.log was at the start is gone)" contains "$(jget notrun_reasons.0)" "was rotated away before it was read"
}

# ---- identity (one number per opening) ----
mb_36() { # STALE_LINE(1|0) E8_FRONT_T: scenario 36's sequence
  local stale="$1" e8front="$2"
  mb_first 1; sm_open 2 4.0
  sm_term 4.8; sm_front "$e8front" 5555                                       # e8: another application
  sm_click 5.0 right $((BX + 20)) 415 0 5.0                                   # e5
  sm_click 5.3 left $((BX + 48 + 236 + 10)) 508 0 5.3                         # e6 on P, 10 pt right of M, taken by the old, larger panel
  sm_menu 6.5 "close reason=outside et=$(tet 4.8) gen=2"; sm_geom 6.5 "$(g_closed)"
  BX=320
  sm_geom 6.8 "$(g_closed)"; sm_windows_body 6.8 320                          # the walk home resumes: a pure move outside both intervals
  sm_geom 6.9 "$(g_open 3)"; sm_menu 6.9 "open et=$(tet 5.0) how=right gen=3"
  [ "$stale" != 1 ] || sm_do 7.0 "agent MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=0 why=menu-stale et=$(tet 5.3) gen=2"
  sm_outside 3 8.5 8.6 6666
  mb_keys
}
scn_m_fail_old_menu_delivery_in_next_interval() {
  new_menu_sandbox m-fail-old-delivery; SECONDS_ARG=60
  mb_36 1 4.9
  run_check --menu
  expect "m_fail_old_menu_delivery_in_next_interval" FAIL 1 "click-taken-outside-hit-region" ""
}

mb_s() { # E4_CLICK_LATE_MS: B up to open#2 and the stale-callback episode S (e4 closes nothing: the menu closed by away first)
  local late="${1:-}"
  mb_first 1; sm_open 2 4.0
  if [ -n "$late" ]; then sm_do 5.0 "late $late click left $((BX - 40)) $(cy 415) 0 $(tet 5.0)"; sm_front 6.6 5555
  else sm_click 5.0 left $((BX - 40)) 415 0 5.0; sm_front 5.1 5555; fi
  sm_menu 5.2 "close reason=away gen=2"; sm_geom 5.2 "$(g_closed)"
  sm_open 3 5.5
  mb_keys
}
scn_m_stale_outside_callback_ignored() {
  new_menu_sandbox m-stale-ignored; SECONDS_ARG=60
  mb_s
  sm_menu 6.0 "stale kind=outside et=$(tet 5.0) gen=2 live=3"
  sm_click 8.0 left $((BX - 40)) 415 0 8.0
  sm_menu 8.0 "close reason=outside et=$(tet 8.0) gen=3"; sm_geom 8.0 "$(g_closed)"; sm_front 8.1 6666
  run_check --menu
  expect "m_stale_outside_callback_ignored" PASS 0 "" ""
  check "m_stale_outside_callback_ignored: the outside click is counted once (e7 for gen 3)" equals "$(mget counts.outside_click)" 1
  check "m_stale_outside_callback_ignored: e4 (the 4th click) is accounted by its stale line" equals "$(mget clicks.3.accounted_by)" line
  check "m_stale_outside_callback_ignored: e4 is unclassified (no interval of the window holds it, 5.3), and the evidence says why for each interval" bash -c "[ \"$(mget clicks.3.placed)\" = unclassified ] && [ \"$(mget clicks.3.placed_why.0)\" != '' ] && [ \"$(mget clicks.3.placed_why.2)\" != '' ]"
  check "m_stale_outside_callback_ignored: e4 is also accounted by the T+5.1 transition, which it owns as the only candidate of its cause window" equals "$(mget clicks.3.accounted_by_transition)" "transition at $(tms 5.1)"
  check "m_stale_outside_callback_ignored: ... the transition is in the evidence (pid 5555) and e4 landed on it" bash -c "[ \"$(mget clicks.3.landing_pid)\" = 5555 ] && [ \"$(mget clicks.3.landed)\" = 1 ] && [ \"$(mget transitions.0.t_ms)\" = \"$(tms 5.1)\" ]"
  check "m_stale_outside_callback_ignored: the stale line is read by nothing else: E holds 3 opens and 3 closes, no click is unaccounted, and its line is listed" bash -c "[ \"\$(/usr/bin/plutil -extract menu.e_sequence json -o - '$JSON' | grep -o '\"t\"' | wc -l | tr -d ' ')\" = 6 ] && [ \"\$(/usr/bin/plutil -extract menu.unaccounted_clicks json -o - '$JSON')\" = '[]' ] && case \"$(mget stale_lines.0)\" in *'MENU stale kind=outside'*) exit 0 ;; *) exit 1 ;; esac"
}
scn_m_nr_stale_outside_close_credits_newer_menu() {
  new_menu_sandbox m-stale-credit; SECONDS_ARG=60
  mb_s
  sm_menu 6.0 "close reason=outside et=$(tet 5.0) gen=3"; sm_geom 6.0 "$(g_closed)"
  run_check --menu
  expect "m_nr_stale_outside_close_credits_newer_menu" "NOT RUN" 3 "" "outside-click-unobserved"
}
scn_m_nr_menu_open_and_geom_gens_differ() {
  new_menu_sandbox m-nr-gens-differ; SECONDS_ARG=60
  mb_base
  sm_click 6.0 right $((BX + 20)) 415 0 6.0; sm_geom 6.0 "$(g_open 4)"; sm_menu 6.0 "open et=$(tet 6.0) how=right gen=3"
  sm_click 6.5 right $((BX + 20)) 415 0 6.5; sm_menu 6.5 "close reason=toggle et=$(tet 6.5) gen=3"; sm_geom 6.5 "$(g_closed)"
  run_check --menu
  expect "m_nr_menu_open_and_geom_gens_differ" "NOT RUN" 3 "" "menu-state-unproven"
}
scn_m_nr_outside_close_names_another_gen() {
  new_menu_sandbox m-nr-close-gen; SECONDS_ARG=60
  mb_base; sm_open 3 6.0
  sm_click 7.0 left $((BX - 40)) 415 0 7.0
  sm_menu 7.0 "close reason=outside et=$(tet 7.0) gen=2"; sm_geom 7.0 "$(g_closed)"; sm_front 7.1 6666
  run_check --menu
  expect "m_nr_outside_close_names_another_gen" "NOT RUN" 3 "" "menu-state-unproven"
}

# ---- accounting and click order (v3.2) ----
scn_m_nr_dropped_click_of_an_old_panel() {
  new_menu_sandbox m-nr-dropped; SECONDS_ARG=60
  mb_36 0 4.9
  run_check --menu
  expect "m_nr_dropped_click_of_an_old_panel" "NOT RUN" 3 "" "click-unaccounted"
}
scn_m_nr_dropped_click_shares_a_landing() {
  new_menu_sandbox m-nr-shares; SECONDS_ARG=60
  mb_36 0 5.25
  run_check --menu
  expect "m_nr_dropped_click_shares_a_landing" "NOT RUN" 3 "" "click-unaccounted"
  check "m_nr_dropped_click_shares_a_landing: evidence for the unaccounted click e6 (the 6th): its transition is shared with e8 (the 4th), and the nearest open and close are gen 2's" bash -c "[ \"$(mget unaccounted_clicks.0)\" = 6 ] && [ \"$(mget clicks.5.n13.transitions_in_landing_band.0.pid)\" = 5555 ] && [ \"\$(/usr/bin/plutil -extract menu.clicks.5.n13.transitions_in_landing_band.0.candidates_in_cause_window json -o - '$JSON')\" = '[4,6]' ] && [ \"$(mget clicks.5.n13.nearest_open.gen)\" = 2 ] && [ \"$(mget clicks.5.n13.nearest_close.gen)\" = 2 ]"
  check "m_nr_dropped_click_shares_a_landing: e6 is unclassified, with the reasons per interval, and the outside close of e8 is placed in gen 2" bash -c "[ \"$(mget clicks.5.placed)\" = unclassified ] && [ \"$(mget clicks.5.placed_why.1)\" != '' ] && [ \"$(mget clicks.3.placed)\" = 2 ]"
  check "m_nr_dropped_click_shares_a_landing: the reason says which clicks share the transition" contains "$(/usr/bin/plutil -extract notrun_reasons json -o - "$JSON")" "shared with clicks [4,6]"
}
scn_m_nr_outside_click_ordered_by_handling_time() {
  new_menu_sandbox m-nr-handling-order; SECONDS_ARG=60
  mb_s 1500
  sm_menu 6.7 "close reason=outside et=$(tet 5.0) gen=3"; sm_geom 6.7 "$(g_closed)"
  run_check --menu
  expect "m_nr_outside_click_ordered_by_handling_time" "NOT RUN" 3 "" "outside-click-unobserved"
}
scn_m_nr_late_activation_lands_in_a_dropped_clicks_band() {
  new_menu_sandbox m-nr-late-activation; SECONDS_ARG=60
  mb_36 0 5.6
  run_check --menu
  expect "m_nr_late_activation_lands_in_a_dropped_clicks_band" "NOT RUN" 3 "" "click-unaccounted"
}

scn_m_nr_outside_click_within_the_pairing_tolerance_of_the_opening_click() {   # round 3, item 4: kind 4 (a) compares the opening CLICK's et, not the MENU line's
  new_menu_sandbox m-nr-pair-tolerance; SECONDS_ARG=60
  mb_first 1
  local e3 e4
  e3="$(tet_us 4.0 400)"; e4="$(tet_us 4.0 700)"
  sm_do 4.0 "click right $((BX + 20)) 415 0 $e3"                                  # the sampler's copy of the opening click: 0.4 ms after the agent's stamp (paired)
  sm_geom 4.0 "$(g_open 2)"; sm_menu 4.0 "open et=$(tet 4.0) how=right gen=2"
  sm_do 5.0 "click left $((BX - 40)) $(cy 415) 0 $e4"                             # 0.7 ms after the MENU open's et, but only 0.3 ms after the opening CLICK's
  sm_menu 5.0 "close reason=outside et=$e4 gen=2"; sm_geom 5.0 "$(g_closed)"; sm_front 5.1 5555
  mb_keys
  run_check --menu
  expect "m_nr_outside_click_within_the_pairing_tolerance_of_the_opening_click" "NOT RUN" 3 "" "outside-click-unobserved"
  check "m_nr_outside_click_within_the_pairing_tolerance_of_the_opening_click: the reason says the et is not later than the opening click's" contains "$(/usr/bin/plutil -extract notrun_reasons json -o - "$JSON")" "not later than both the MENU open's et and the et of the click that opened gen 2"
}

scn_m_nr_outside_click_within_the_tolerance_of_the_menu_line() {   # Codex round 3: the opening CLICK 0.4 ms BEFORE the MENU open's et; the outside click must also clear the MENU line's et
  new_menu_sandbox m-nr-menu-line-tolerance; SECONDS_ARG=60
  mb_first 1
  local e4
  e4="$(tet_us 4.0 700)"
  sm_do 4.0 "click right $((BX + 20)) 415 0 $(tet 4.0)"                          # the opening click (paired: 0.4 ms before the MENU open's et)
  sm_geom 4.0 "$(g_open 2)"; sm_menu 4.0 "open et=$(tet_us 4.0 400) how=right gen=2"
  sm_do 5.0 "click left $((BX - 40)) $(cy 415) 0 $e4"                             # 0.7 ms after the opening CLICK's et, but only 0.3 ms after the MENU open's
  sm_menu 5.0 "close reason=outside et=$e4 gen=2"; sm_geom 5.0 "$(g_closed)"; sm_front 5.1 5555
  mb_keys
  run_check --menu
  expect "m_nr_outside_click_within_the_tolerance_of_the_menu_line" "NOT RUN" 3 "" "outside-click-unobserved"
  check "m_nr_outside_click_within_the_tolerance_of_the_menu_line: the reason says the et is not later than the opening's" contains "$(/usr/bin/plutil -extract notrun_reasons json -o - "$JSON")" "not later than both the MENU open's et and the et of the click that opened gen 2"
}

# ---- amendment R-TYPE (the typing proof also excludes every reopen executed after O, ordered by gen; scenarios 45-48 of the amendment) ----
# The word is printed after X1 sees O's window and typed while no menu is on screen; a second opening, executed by the agent after O, shows the window
# again at X2. Every other kind is counted from the baseline's shapes (a pick in gen 2 after X2, a third opening closed by an outside click), so the
# typing kind alone decides the verdict.
scn_m_nr_typed_word_across_queued_reopen() {   # 45: the finding (Codex 20261021-014357-6f32fa, part A): a right-click sampled before X1, handled 1.9 s later
  new_menu_sandbox m-nr-queued-reopen; SECONDS_ARG=60
  sm_click 0 right $((BX + 20)) 415 0 0
  sm_geom 0 "$(g_open 1) windowlater 400"; sm_menu 0 "open et=$(tet 0) how=right gen=1"       # O = gen 1; its window is on screen from T+0.4, so X1 comes after the second click
  sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_click 0.1 right $((BX + 20)) 415 0 0.1                                                    # the second right-click, stamped by the sampler before X1
  sm_menu 1.8 "close reason=away gen=1"; sm_geom 1.8 "$(g_closed)"
  sm_geom 2.0 "$(g_open 2)"; sm_menu 2.0 "open et=$(tet 0.1) how=right gen=2"                  # the agent handles that click 1.9 s late and opens gen 2
  printf 'prompt:1 2000 WORD:1\n' > "$STUB/keys.react"                                          # typed after the close, read after gen 2's window is up
  sm_pick 2 1 5.0 walk on; sm_write 1 2 walk walk+on 0 5.3
  sm_open 3 6.5; sm_outside 3 7.5 7.6 5555
  run_check --menu
  expect "m_nr_typed_word_across_queued_reopen" "NOT RUN" 3 "" "typing-unobserved"
  check "m_nr_typed_word_across_queued_reopen: every other kind is counted (3 right-clicks, hover, item click, outside click), typing is not" bash -c "[ \"$(mget counts.right_click)\" = 3 ] && [ \"$(mget counts.hover)\" = 1 ] && [ \"$(mget counts.item_click)\" = 1 ] && [ \"$(mget counts.outside_click)\" = 1 ] && [ \"$(mget counts.typing)\" = 0 ]"
  check "m_nr_typed_word_across_queued_reopen: the word was read with gen 2's window on screen, and clause (c) rejected it, naming gen 2" bash -c "[ \"$(mget keys.0.rejected_by_clause)\" = c ] && case \"$(mget keys.0.why)\" in 'clause (c):'*'gen 2 '*) exit 0 ;; *) exit 1 ;; esac"
}
scn_m_nr_late_stamped_earlier_open_still_excluded() {   # 46: Codex round 1's sequence: both CLICKs stamped late, in order; clause (a) still excludes gen 1's
  new_menu_sandbox m-nr-late-stamped; SECONDS_ARG=60
  sm_do 0 "late 1000 click right $((BX + 20)) $(cy 415) 0 $(tet 0)"                            # gen 1's CLICK is stamped at T+1.0
  sm_do 0 "late 1020 click right $((BX + 20)) $(cy 415) 0 $(tet 0.2)"                          # O's CLICK is stamped at T+1.02
  sm_geom 0 "$(g_open 1) nowindow"; sm_menu 0 "open et=$(tet 0) how=right gen=1"               # gen 1 never has a window on screen, so no word is printed for it
  sm_menu 0.1 "close reason=away gen=1"; sm_geom 0.1 "$(g_closed)"
  sm_geom 0.2 "$(g_open 2)"; sm_menu 0.2 "open et=$(tet 0.2) how=right gen=2"                  # O = gen 2
  sm_hover 2 0.6 walk on; sm_hover 2 0.9 motion normal
  printf 'prompt:1 1500 WORD:1\n' > "$STUB/keys.react"
  sm_pick 2 1 4.0 walk on; sm_write 1 2 walk walk+on 0 4.3
  sm_open 3 5.5; sm_outside 3 6.5 6.6 5555
  run_check --menu
  expect "m_nr_late_stamped_earlier_open_still_excluded" "NOT RUN" 3 "" "typing-unobserved"
  check "m_nr_late_stamped_earlier_open_still_excluded: clause (a) rejected the word (gen 1's CLICK lies between the prompt and the end of the margin), and the prompt was for gen 2" bash -c "[ \"$(mget keys.0.rejected_by_clause)\" = a ] && [ \"$(mget prompts.0.gen)\" = 2 ]"
}
scn_m_boundary_reopen_ordered_just_before_o() {   # 47: an earlier opening whose click's et is 1 ms before O's click's et, all stamped before X1: the word counts
  new_menu_sandbox m-boundary-reopen; SECONDS_ARG=60
  local e1; e1="$(tet_us 0.4 -1000)"
  sm_do 0 "click right $((BX + 20)) $(cy 415) 0 $e1"
  sm_geom 0 "$(g_open 1) nowindow"; sm_menu 0 "open et=$e1 how=right gen=1"
  sm_menu 0.2 "close reason=away gen=1"; sm_geom 0.2 "$(g_closed)"
  sm_open 2 0.4                                                                                # O = gen 2
  sm_hover 2 0.6 walk on; sm_hover 2 0.9 motion normal
  printf 'prompt:1 1000 WORD:1\n' > "$STUB/keys.react"
  sm_pick 2 1 3.5 walk on; sm_write 1 2 walk walk+on 0 3.8
  sm_open 3 5.0; sm_outside 3 6.0 6.1 5555
  run_check --menu
  expect "m_boundary_reopen_ordered_just_before_o" PASS 0 "" ""
  check "m_boundary_reopen_ordered_just_before_o: the word counted, for gen 2, and gen 1's click is 1 ms before O's in et" bash -c "[ \"$(mget counts.typing)\" = 1 ] && [ \"$(mget prompts.0.gen)\" = 2 ] && [ \"$(mget keys.0.rejected_by_clause)\" = '' ]"
}
scn_m_nr_typed_word_across_deferred_open() {   # 48: Codex round 2's sequence: a right-click whose opening is deferred, a control-click opens O first
  new_menu_sandbox m-nr-deferred-open; SECONDS_ARG=60
  sm_click 0 right $((BX + 20)) 415 0 0                                                        # e_a: nothing opens at first
  sm_open 1 0.2 control                                                                        # e_b: a control-click opens O, gen 1
  sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_menu 1.5 "close reason=away gen=1"; sm_geom 1.5 "$(g_closed)"
  sm_geom 1.9 "$(g_open 2)"; sm_menu 1.9 "open et=$(tet 0) how=right gen=2"                    # the deferred opening runs 1.9 s after its click and is gen 2, paired with the older click
  printf 'prompt:1 2000 WORD:1\n' > "$STUB/keys.react"
  sm_pick 2 1 5.0 walk on; sm_write 1 2 walk walk+on 0 5.3
  sm_open 3 6.5; sm_outside 3 7.5 7.6 5555
  run_check --menu
  expect "m_nr_typed_word_across_deferred_open" "NOT RUN" 3 "" "typing-unobserved"
  check "m_nr_typed_word_across_deferred_open: clause (c) rejected the word, naming gen 2 (its click's et is before O's, which an order by et would miss)" bash -c "[ \"$(mget keys.0.rejected_by_clause)\" = c ] && case \"$(mget keys.0.why)\" in 'clause (c):'*'gen 2 '*) exit 0 ;; *) exit 1 ;; esac"
}

scn_m_nr_typed_word_when_o_has_no_opening_click() {   # clause (b): the opening the word was printed for has no CLICK (the monitor missed it)
  new_menu_sandbox m-nr-o-no-click; SECONDS_ARG=60
  sm_geom 0 "$(g_open 1)"; sm_menu 0 "open et=$(tet 0) how=right gen=1"                         # O = gen 1, and no CLICK line follows its click
  sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on; sm_write 1 1 walk walk+on 0 2.8
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_nr_typed_word_when_o_has_no_opening_click" "NOT RUN" 3 "" "click-monitor-missed,typing-unobserved"
  check "m_nr_typed_word_when_o_has_no_opening_click: clause (b) rejected the word" bash -c "[ \"$(mget keys.0.rejected_by_clause)\" = b ] && case \"$(mget keys.0.why)\" in 'clause (b):'*) exit 0 ;; *) exit 1 ;; esac"
}

# ---- the amendments ----
scn_m_body_click_toggle_close() {      # R-BODY: a left click on Clawd's body closes the open menu it began under
  new_menu_sandbox m-body-toggle; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_click 4.5 left $((BX + 20)) 415 0 4.5
  sm_do 4.5 "agent INPUT kind=mouseDown tag=0000000000000000 src=0 et=$(tet 4.5)"
  sm_menu 4.8 "close reason=toggle et=$(tet 4.5) gen=2"; sm_geom 4.8 "$(g_closed)"
  sm_open 3 6.0; sm_outside 3 7.0 7.1 5555; mb_keys
  run_check --menu
  expect "m_body_click_toggle_close" PASS 0 "" ""
}
scn_m_geometry_close_without_a_click() {   # R-GEOM (a): the open menu closes because Clawd moved under it
  new_menu_sandbox m-geometry-close; SECONDS_ARG=60
  mb_first 1; sm_open 2 4.0
  sm_menu 4.5 "close reason=geometry gen=2"
  BX=330; sm_geom 4.5 "$(g_closed)"; sm_windows_body 4.5 330
  sm_open 3 6.0; sm_outside 3 7.0 7.1 5555; mb_keys
  run_check --menu
  expect "m_geometry_close_without_a_click" PASS 0 "" ""
}
scn_m_geometry_close_inside_a_pick_flash() {   # R-GEOM (b): a pick, then the geometry close inside its flash, then the pick's write
  new_menu_sandbox m-geometry-flash; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_click 2.5 left $((BX + 168)) 500 0 2.5
  sm_menu 2.5 "pick id=1 et=$(tet 2.5) key=walk value=on gen=1"
  sm_menu 2.6 "close reason=geometry gen=1"
  BX=330; sm_geom 2.6 "$(g_closed)"; sm_windows_body 2.6 330
  sm_write 1 1 walk walk+on 0 2.9
  sm_open 2 4.0; sm_outside 2 5.0 5.1 5555; mb_keys
  run_check --menu
  expect "m_geometry_close_inside_a_pick_flash" PASS 0 "" ""
}
scn_m_fail_write_output_text_is_not_a_field() {   # a write-output line whose text says exit=0 gen=9 changes nothing
  new_menu_sandbox m-write-output; SECONDS_ARG=60
  sm_open 1 0; sm_hover 1 0.6 walk on; sm_hover 1 0.9 motion normal
  sm_pick 1 1 2.5 walk on
  sm_write 1 1 walk walk+on 2 2.8
  sm_menu 2.81 "write-output id=1 gen=1 text=exit=0 gen=9"
  sm_open 2 4.0; sm_pick 2 2 4.5 motion normal; sm_write 2 2 motion motion+normal 0 4.8
  sm_open 3 6.0; sm_outside 3 7.0 7.1 5555; mb_keys
  run_check --menu
  expect "m_fail_write_output_text_is_not_a_field" FAIL 1 "menu-write-failed" ""
}

scn_m_cause_window_table() {     # N13's cause window: one candidate just inside and one just outside each edge
  local out
  out="$("$CHECK_BASH" -c "source '$SCRIPT'; menu_perl mode=cause cases=100000:97400,100000:97399,100000:102000,100000:102001,100000:100000" 2>&1)"
  check "cause window: W + 500 ms + 100 ms before the transition is inside" contains "$out" "100000:97400=1"
  check "cause window: one ms earlier is outside" contains "$out" "100000:97399=0"
  check "cause window: W after the transition is inside" contains "$out" "100000:102000=1"
  check "cause window: one ms later is outside" contains "$out" "100000:102001=0"
  check "cause window: the transition's own stamp is inside" contains "$out" "100000:100000=1"
}

# An interrupt inside a menu run's window: besides the sampler, the menu mode runs the reader of the typed words as a job. finish must stop
# both so that its analysis reads their complete output, the receipt says NOT RUN with `interrupted` alone (no menu NOT RUN row joins it),
# and neither job is left when it exits. The two jobs are named, not guessed: the sampler by its samples header, the reader by the keys
# stub, which writes its parent's pid (keys.hold). keys.hold also keeps the stub from ending when the samples stop, as the real reader on the
# terminal never does on its own, so an unstopped reader stays running.
# The sampler's output is read first (analyze_samples, right after the stops): sampler.term-delay makes the stub sampler wait 5 s after its
# TERM and then write one last sample, as a sampler that flushes on the way out, so the receipt's sample count equals the lines in the file
# only when the analysis read the sampler's complete output. A finish that does not wait is caught unless the analysis itself stalls for
# those 5 s (Codex, 2026-10-21: the count proves completeness, not the order of exit and read). The reader's output (keys.log) is read first by analyze_menu; before that, the head
# shim runs head.hook once, at the analysis's first `head -c N` of standard input (analyze_log, which a GEOM line in the window makes run),
# and that look records whether each job is still in the process table. The reader job ends at once on TERM (its default), so dropping only
# its `wait` cannot be seen: bash reaps an ended job itself.
scn_m_interrupt() { # signal
  local sig="$1" pid out header spid rpid kpid kids rec size0
  new_menu_sandbox "m-interrupt-$sig"; SECONDS_ARG=30
  : > "$STUB/keys.hold"; echo 5 > "$STUB/sampler.term-delay"
  # one GEOM line (Clawd as it stands, no menu) inside the window, so the log grows and the analysis reads the window's bytes through head
  sm_geom 0 "$(g_closed)"; size0="$(wc -c < "$LOG" | tr -d ' ')"
  # The look uses kill -0 (a builtin: /bin/ps may not run where the suite runs, and an empty answer must never read as "gone"); its first
  # line is a positive control, kill -0 on the hook's own shell, so a probe that cannot see processes says so instead of passing.
  printf '%s\n' '{ kill -0 $$ 2>/dev/null && echo "probe ok" || echo "probe blind"; for p in $(cat "$STUB_DIR/jobs.pids"); do if kill -0 "$p" 2>/dev/null; then echo "$p in-table"; else echo "$p gone"; fi; done; } > "$STUB_DIR/jobs.at-analysis.tmp"; mv "$STUB_DIR/jobs.at-analysis.tmp" "$STUB_DIR/jobs.at-analysis"' > "$STUB/head.hook"
  out="$SB/out"
  if [ "$sig" = INT ]; then
    # a background job of a non-interactive shell ignores SIGINT; perl puts the default back before the exec so the script's trap can fire
    env -i HOME="$SB/home" PATH="$STUBS/shim:/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
      CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" \
      /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$CHECK_BASH" "$SCRIPT" --seconds 30 --menu > "$out" 2>&1 &
  else
    env -i HOME="$SB/home" PATH="$STUBS/shim:/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
      CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" \
      "$CHECK_BASH" "$SCRIPT" --seconds 30 --menu > "$out" 2>&1 &
  fi
  pid=$!
  wait_until 400 bash -c "grep -q 'attended-check: [0-9]* s left' '$out' && [ -s '$STUB/keys.parent' ] && [ -s '$STUB/keys.pid' ] && [ \"\$(wc -c < '$LOG' | tr -d ' ')\" -gt $size0 ]"
  header="$(cat "$SB"/evidence/attended-check-work/*/samples.txt 2>/dev/null | head -n 1)"
  spid="${header#SAMPLING pid=}"; rpid="$(cat "$STUB/keys.parent" 2>/dev/null)"; kpid="$(cat "$STUB/keys.pid" 2>/dev/null)"
  wait_until 100 bash -c "[ \"\$(/usr/bin/pgrep -P '$rpid' | wc -l | tr -d ' ')\" -ge 2 ]"   # the pipeline's two children: the keys stub and the reading loop
  kids="$(/usr/bin/pgrep -P "$rpid" 2>/dev/null | paste -sd' ' -)"
  printf '%s\n%s\n' "$spid" "$rpid" > "$STUB/jobs.pids"
  check "m $sig: the script is inside its window, its countdown runs" bash -c "kill -0 '$pid' 2>/dev/null && grep -q 'attended-check: [0-9]* s left' '$out'"
  check "m $sig: the sampler ($spid) and the reader ($rpid) are running children of the script; the keys stub ($kpid) is the reader's child" bash -c "
    ch=\" \$(/usr/bin/pgrep -P '$pid' | paste -sd' ' -) \"; case \"\$ch\" in *' $spid '*) ;; *) exit 1 ;; esac; case \"\$ch\" in *' $rpid '*) ;; *) exit 1 ;; esac
    [ '$spid' != '$rpid' ] && case ' $kids ' in *' $kpid '*) exit 0 ;; *) exit 1 ;; esac"
  kill "-$sig" "$pid"
  wait "$pid"; RC=$?
  JSON="$(ls "$SB"/evidence/attended-check-*.json 2>/dev/null | head -n 1)"
  rec="$(cat "$STUB/jobs.at-analysis" 2>/dev/null | paste -sd';' -)"
  jsr="$(cat "$SB"/evidence/attended-check-work/*/jobs-at-sample-read 2>/dev/null | paste -sd';' -)"
  check "m $sig: the analysis read every sample, the one written after the sampler's 5 s tail included" bash -c "f=\$(ls '$SB'/evidence/attended-check-work/*/samples.txt | head -n 1); [ \"\$(tail -n 1 \"\$f\" | cut -d' ' -f1)\" = SAMPLES-WRITTEN ] && [ \"$(jget samples.count)\" = \"\$(grep -cE '^[0-9]+ -?[0-9]+\$' \"\$f\")\" ]"
  # The script records, at the first read of the samples (analyze_samples), whether each job it started is still running; the look
  # below runs later (at the first head -c of the analysis) and cannot see what was true at that read, but it alone sees the reaping.
  check "m $sig: at the first sample read neither job is running: [$jsr]" equals "$jsr" "sampler $spid stopped;reader $rpid stopped"
  check "m $sig: at the analysis both jobs are stopped and reaped: [$rec]" bash -c "[ \"\$(sed -n 1p '$STUB/jobs.at-analysis')\" = 'probe ok' ] && [ \"\$(sed 1d '$STUB/jobs.at-analysis' | grep -c ' gone\$')\" = 2 ] && [ \"\$(wc -l < '$STUB/jobs.at-analysis' | tr -d ' ')\" = 3 ]"
  # The reader's own children end when their parent goes (the keys stub looks every 50 ms; the reading loop sees end of input), not by a
  # stop of their own, so they get a short bound after the exit; an unstopped reader keeps them alive however long one waits.
  check "m $sig: the probe of the next check sees a live process (kill -0 on this test's shell)" bash -c "kill -0 $$"
  check "m $sig: one look after the script has exited finds neither job (sampler $spid, reader $rpid; no retry)" bash -c "! kill -0 $spid 2>/dev/null && ! kill -0 $rpid 2>/dev/null"
  # The reader's two pipeline children are not stopped by the script: they end when their parent (the reader job) goes, the keys stub at
  # its next 50 ms look and the reading loop at end of input. In real mode the reader reads the terminal in the job's own process.
  check "m $sig: the reader's pipeline children are gone within 1 s of the start of this look ($kids)" wait_until 20 bash -c "for j in $kids; do ! kill -0 \"\$j\" 2>/dev/null || exit 1; done"
  check "m $sig: exit 3" equals "$RC" 3
  check "m $sig: the receipt says NOT RUN with the reason interrupted alone and no fail code" bash -c "[ \"$(jget verdict)\" = 'NOT RUN' ] && [ \"$(codes notrun_codes)\" = interrupted ] && [ -z \"$(codes fail_codes)\" ]"
  check "m $sig: the verdict line is the last line" contains "$(tail -n 1 "$out")" "attended-check: NOT RUN (interrupted"
  # The jobs this scenario named are ended here, after every check: under a mutation row that drops a stop they would live on (the
  # keys stub with keys.hold ends only when its parent does), and outside test-jail nothing else reaps them (Friday, 2026-10-21: nine
  # such processes ran 2.5 h after an unjailed rows run).
  kill $spid $rpid $kids 2>/dev/null
}

# A signal that lands while the live view's `while IFS='=' read` waits for Perl (most of a poll under load) runs on_signal with that read's
# temporary IFS. The handler must split with the default IFS again, or finish's analysis reads "0 0 -" as one word and dies on `set -u`
# with exit 1 and no receipt (seen in scn_m_interrupt TERM, 2026-10-21). Here finish and notrun are stand-ins, the signal comes 0.5 s into
# a read that waits 3 s, so the handler runs inside the read every time.
scn_m_signal_inside_an_ifs_read() {
  local out
  out="$("$CHECK_BASH" -c "source '$SCRIPT'; set -u; finish() { set -- \$(printf '0 0 -'); echo \"words=\$#\"; exit 0; }; notrun() { :; }; trap on_signal TERM; ( sleep 0.5; kill -TERM \$\$ ) & while IFS='=' read -r k v; do :; done < <(sleep 3; echo a=b); echo 'the read ended before the signal'" 2>&1)"
  check "m_signal_inside_an_ifs_read: the handler splits words with the default IFS (got: $out)" equals "$out" "words=3"
}

# A signal that lands while a function runs with its output redirected to a work file (menu_window_lines appends menu_cut's output with >>)
# runs on_signal with that redirection in force: the verdict lines went into menu-window-lines.txt and the run's output showed none (seen
# in scn_m_interrupt, 2026-10-23). The handler writes through the script's own stdout and stderr, saved as fd 4 and 5 before the trap is
# set. Here finish and notrun are stand-ins, and the signal comes 0.5 s into a 3 s step of the redirected function.
scn_m_signal_inside_a_redirected_function() {
  local out f="$STAGE/redirected-function.txt"
  : > "$f"
  out="$("$CHECK_BASH" -c "source '$SCRIPT'; set -u; finish() { echo verdict; exit 0; }; notrun() { :; }; exec 4>&1 5>&2; trap on_signal TERM; slow() { sleep 3; }; ( sleep 0.5; kill -TERM \$\$ ) & slow >> '$f'; echo 'the step ended before the signal'" 2>&1)"
  check "m_signal_inside_a_redirected_function: the verdict reaches the script's own output (got: $out)" equals "$out" "verdict"
  check "m_signal_inside_a_redirected_function: nothing went into the step's file" bash -c "[ ! -s '$f' ]"
}

# ---- run the scenarios ----------------------------------------------------------------------------------------------------------------
# ---- the focus-violation ledger (attended-history amendment, D5): the window verdict and the separate history line ---------------------------
# The ledger of the sandbox holds the header and one BOOT line for the sandbox's agent (pid 4242). VIOLATION_LINE is what the agent appends.
VIOLATION_LINE="1792000005.000300 VIOLATION n=1 pid=4242 trigger=click notification=NSWindowDidBecomeKeyNotification"
hist_text() { jget history.since_ledger_birth.text; }
hist_complete() { jget history.since_ledger_birth.complete; }
hist_reasons() { /usr/bin/plutil -extract history.since_ledger_birth.reasons json -o - "$JSON" 2>/dev/null; }

# -- PASS: the window verdict, with the history line apart from it --
scn_pass_ledger_rotated_three_times_since_install() {
  # agent.log rotated three times since install (no install-time proof is left), the ledger is intact at both reads, a clean window.
  new_sandbox pass-ledger-rot3
  printf '%s\n' "$TS.000001 STATE scene=idle" > "$LOG1"
  printf 'STATE scene=idle after the third rotation\n' > "$LOG"
  run_check
  expect "rotated 3 times since install, ledger intact at both reads, clean window" PASS 0 "" ""
  check "rotated 3 times: the install-time proof is gone and gates nothing" equals "$(jget history.proved)" false
  check "rotated 3 times: the history line says complete" equals "$(hist_complete)" true
  check "rotated 3 times: the history line is printed apart from the verdict, with the date and how=install" bash -c "printf '%s' \"\$1\" | grep -q 'attended-check: history: since ledger birth .* (how=install): complete; 1 BOOT lines; 0 VIOLATION lines'" _ "$OUT"
  check "rotated 3 times: the PASS line states the window and claims no 'since install'" bash -c "l=\"\$(printf '%s\n' \"\$1\" | grep '^attended-check: PASS')\"; printf '%s' \"\$l\" | grep -q 'no focus violation in window .*\\.\\..*: frontmost-pid sampling clean, ledger intact at both ends, counter 0, agent.log clean' && ! printf '%s' \"\$l\" | grep -qi 'since install'" _ "$OUT"
  check "rotated 3 times: the history line names the four limits in words" contains "$OUT" "never changes the verdict"
}
scn_pass_ledger_log1_absent() {
  new_sandbox pass-ledger-no-log1; rm -f -- "$LOG1"; run_check
  expect "agent.log.1 absent" PASS 0 "" ""
}
scn_pass_ledger_recreated() {
  new_sandbox pass-ledger-recreated
  write_ledger 'LEDGER 1 born=1792500000 how=recreate' "$BOOT_4242"
  run_check
  expect "a recreated ledger (how=recreate, later birth), clean window" PASS 0 "" ""
  check "recreated: the history line is incomplete and says recreated" bash -c "[ \"$(hist_complete)\" = false ] && printf '%s' \"$(hist_text)\" | grep -q 'incomplete (recreated)' && printf '%s' \"$(hist_text)\" | grep -q 'how=recreate'"
}
scn_pass_ledger_adopted() {
  new_sandbox pass-ledger-adopted
  write_ledger 'LEDGER 1 born=1792500000 how=adopt-update' "$BOOT_4242"
  run_check
  expect "an adopted ledger (how=adopt-update), clean window" PASS 0 "" ""
  check "adopted: the history never says 'since install'" bash -c "! printf '%s' \"$(hist_text)\" | grep -qi 'since install' && printf '%s' \"$(hist_text)\" | grep -q 'how=adopt-update'"
}
scn_pass_ledger_torn_boot_tail() {
  new_sandbox pass-ledger-torn-boot
  printf 'BOOT 1792000002.0000' >> "$LEDGER_F"
  run_check
  expect "a valid header, a BOOT for the agent, then an unterminated tail that is a prefix of a BOOT line" PASS 0 "" ""
  check "torn BOOT tail: the history line notes torn BOOT tail" bash -c "printf '%s' \"$(hist_text)\" | grep -q 'torn BOOT tail' && [ \"$(hist_complete)\" = false ]"
}
scn_pass_ledger_sealed_torn_boot() {
  # A short BOOT write, a restart whose newline guard sealed it, a valid BOOT, a clean window.
  new_sandbox pass-ledger-sealed-boot
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000001.00000' "$BOOT_4242"
  run_check
  expect "a sealed torn BOOT followed by a valid BOOT" PASS 0 "" ""
  check "sealed torn BOOT: the history notes sealed torn BOOT" contains "$(hist_text)" "sealed torn BOOT"
}
scn_pass_ledger_truncated_to_a_line_boundary() {
  # Pins a residual, not a defect: a ledger truncated back to a complete-line boundary before the window reads the same at both ends.
  new_sandbox pass-ledger-truncated
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000050 pid=99 counter=0 violations=0' "$BOOT_4242"
  run_check
  expect "a ledger truncated to a line boundary before the window" PASS 0 "" ""
  check "truncated before the window: the history line claims nothing beyond the BOOT lines present" bash -c "printf '%s' \"$(hist_text)\" | grep -q '; 2 BOOT lines; 0 VIOLATION lines'"
}
scn_pass_ledger_boot_sync_failed() {
  new_sandbox pass-ledger-bootsync
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.000002 LEDGER_BOOT_SYNC_FAILED errno=5" > "$LOG"
  run_check
  expect "BOOT written, fsync failed" PASS 0 "" ""
  check "boot sync failed: the history notes boot sync failed" contains "$(hist_text)" "boot sync failed"
}
scn_pass_ledger_agent_log_between_rename_and_creation() {
  # An endpoint snapshot taken between agent.log's rename and the new file's creation, with a clean ledger, counter and sampling: PASS.
  new_sandbox pass-ledger-rename-gap
  sc_hook 3 "mv $(printf '%q' "$LOG") $(printf '%q' "$LOG1")"
  run_check
  expect "agent.log renamed to agent.log.1 and not yet created again (no new file ever appears)" PASS 0 "" ""
  new_sandbox pass-ledger-rename-gap-2
  printf 'STATE scene=idle new generation\n' > "$SB/new-log"
  sc_hook 3 "mv $(printf '%q' "$LOG") $(printf '%q' "$LOG1"); (sleep 0.25; cp $(printf '%q' "$SB/new-log") $(printf '%q' "$LOG")) >/dev/null 2>&1 &"
  run_check
  expect "agent.log renamed to agent.log.1 and created again 250 ms later" PASS 0 "" ""
}
scn_nr_ledger_agent_log_missing_without_a_rotation() {
  new_sandbox nr-ledger-log-gone
  sc_hook 3 "rm -f $(printf '%q' "$LOG")"
  run_check
  expect "agent.log removed with no rotation (the clicks it held are gone with it)" "NOT RUN" 3 "" "log-unreadable:agent.log,no-drag-sequence,too-few-mousedowns"
}
scn_pass_ledger_rollback_then_return() {
  # Variant of the rollback fixture with counter 0 throughout: a clean window after the new build returns is a PASS. The read-only check
  # cannot know about the rollback, so the history line says what it can see.
  new_sandbox pass-ledger-rollback-back
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000050 pid=100 counter=0 violations=0' "$BOOT_4242"
  run_check
  expect "rollback to a build without the ledger and back, counter 0 throughout, clean window" PASS 0 "" ""
}

# -- NOT RUN: gaps in the window's required evidence, each named --
scn_nr_ledger_not_adopted() {
  new_sandbox nr-ledger-not-adopted; MANIFEST_LEDGER=0; set_manifest absent absent; rm -f -- "$LEDGER_F"; run_check
  expect "the manifest has no ledger line" "NOT RUN" 3 "" "ledger-not-adopted"
}
scn_nr_ledger_missing() {
  new_sandbox nr-ledger-missing; rm -f -- "$LEDGER_F"; run_check
  expect "a listed ledger that was removed" "NOT RUN" 3 "" "ledger-missing"
  check "ledger missing: the history line says ledger missing" contains "$(hist_text)" "ledger missing"
}
scn_nr_ledger_changed_in_window() {
  new_sandbox nr-ledger-changed
  sc_shell 20 "printf '%s\n' $(printf '%q' "$LEDGER_HEADER") > $(printf '%q' "$LEDGER_F")"
  run_check
  expect "the ledger is truncated during the window" "NOT RUN" 3 "" "ledger-changed-in-window"
  check "truncated in the window: the history line says truncated or rewritten" contains "$(hist_text)" "truncated or rewritten"
}
scn_nr_ledger_header_changed_in_window() {
  new_sandbox nr-ledger-header-changed
  sc_shell 20 "printf '%s\n%s\n' 'LEDGER 1 born=1792000001 how=install' $(printf '%q' "$BOOT_4242") > $(printf '%q' "$LEDGER_F")"
  run_check
  expect "the ledger's header is replaced during the window" "NOT RUN" 3 "" "ledger-changed-in-window"
}
scn_nr_ledger_final_read_fails() {
  new_sandbox nr-ledger-final-read
  sc_hook 3 "chmod 000 $(printf '%q' "$LEDGER_F")"
  run_check
  chmod 600 "$LEDGER_F"
  expect "the final ledger read fails" "NOT RUN" 3 "" "ledger-final-read-failed"
}
scn_nr_ledger_stale_agent() {
  new_sandbox nr-ledger-stale-agent
  write_ledger "$LEDGER_HEADER"
  run_check
  expect "the running pid has no BOOT because the BOOT write failed (no BOOT bytes)" "NOT RUN" 3 "" "ledger-stale-agent"
}
scn_nr_ledger_stale_agent_other_pid() {
  new_sandbox nr-ledger-stale-other
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000050 pid=100 counter=0 violations=0'
  run_check
  expect "a rolled-back agent: the ledger holds only another pid's BOOT" "NOT RUN" 3 "" "ledger-stale-agent"
}
scn_nr_ledger_boot_in_window() {
  new_sandbox nr-ledger-boot-in-window
  sc_ledger 25 'BOOT 1792000006.000400 pid=5555 counter=0 violations=0'
  run_check
  expect "a BOOT is appended during the window" "NOT RUN" 3 "" "agent-restarted-in-window"
}
scn_nr_ledger_log1_unreadable() {
  new_sandbox nr-ledger-log1-000
  printf '%s\n' "older generation" > "$LOG1"; set_manifest absent "$(rec_of "$LOG1")"
  chmod 000 "$LOG1"
  run_check
  chmod 600 "$LOG1"
  expect "agent.log.1 present but mode 000" "NOT RUN" 3 "" "log-unreadable:agent.log.1"
}
scn_nr_ledger_malformed_header() {
  new_sandbox nr-ledger-bad-header
  write_ledger 'LEDGR 1 born=1792000000 how=install' "$BOOT_4242"
  run_check
  expect "a malformed header, no violation line" "NOT RUN" 3 "" "ledger-malformed"
}
scn_nr_ledger_partial_header() {
  new_sandbox nr-ledger-partial-header
  printf 'LEDGER 1 born=17920' > "$LEDGER_F"
  run_check
  expect "a partial header (a truncated prefix of the header line), no violation anywhere" "NOT RUN" 3 "" "ledger-malformed"
}
scn_nr_ledger_partial_header_with_newline() {
  new_sandbox nr-ledger-partial-header-nl
  printf 'LEDGER 1 born=17920\n%s\n' "$BOOT_4242" > "$LEDGER_F"
  run_check
  expect "a truncated header line that was sealed by a newline" "NOT RUN" 3 "" "ledger-malformed"
}
scn_nr_ledger_unknown_line() {
  new_sandbox nr-ledger-unknown-line
  write_ledger "$LEDGER_HEADER" "$BOOT_4242" 'HELLO from nowhere'
  run_check
  expect "a valid header then a complete unknown line kind, no violation" "NOT RUN" 3 "" "ledger-malformed"
}
scn_nr_ledger_empty_file() {
  new_sandbox nr-ledger-empty; : > "$LEDGER_F"; run_check
  expect "an empty ledger" "NOT RUN" 3 "" "ledger-malformed"
}

# -- FAIL: a violation in any source, whatever else is missing --
scn_fail_ledger_unterminated_non_boot_tail() {
  new_sandbox fail-ledger-torn-tail
  printf '1792000007.000500 VIOLATION n=1 pid=42' >> "$LEDGER_F"
  run_check
  expect "a valid header then an unterminated tail that is not a BOOT prefix (a cut violation line)" FAIL 1 "ledger-torn-line" ""
}
scn_fail_ledger_torn_violation_sealed() {
  new_sandbox fail-ledger-torn-sealed
  printf '1792000007.000500 VIOLATION n=1 pid=42\n' >> "$LEDGER_F"
  run_check
  expect "a cut violation line that the newline guard sealed" FAIL 1 "ledger-torn-line" ""
}
scn_fail_ledger_partial_header_plus_violation() {
  new_sandbox fail-ledger-partial-header-violation
  printf 'LEDGER 1 born=179\n%s\n' "$VIOLATION_LINE" > "$LEDGER_F"
  run_check
  expect "a partial header plus a complete VIOLATION line" FAIL 1 "ledger-violation" "ledger-malformed"
}
scn_fail_ledger_malformed_header_plus_violation() {
  new_sandbox fail-ledger-bad-header-violation
  printf 'garbage header\n%s\n' "$VIOLATION_LINE" > "$LEDGER_F"
  run_check
  expect "a malformed header plus a complete VIOLATION line" FAIL 1 "ledger-violation" "ledger-malformed"
}
scn_fail_ledger_violation_stale_counter() {
  new_sandbox fail-ledger-violation
  printf '%s\n' "$VIOLATION_LINE" >> "$LEDGER_F"
  run_check
  expect "the ledger holds one VIOLATION, the counter is a stale 0, the logs hold nothing" FAIL 1 "ledger-violation" ""
}
scn_fail_ledger_violation_in_window_only() {
  new_sandbox fail-ledger-in-window
  sc_ledger 25 "$VIOLATION_LINE"
  run_check
  expect "a violation reaches the ledger only, during the window (status and log writes failed): found at the final read" FAIL 1 "ledger-violation" ""
}
scn_fail_ledger_write_failed() {
  new_sandbox fail-ledger-write-failed; set_status 0 0 1; run_check
  expect "status.json ledgerFailures is 1" FAIL 1 "ledger-write-failed" ""
}
scn_fail_ledger_write_failed_log_line() {
  new_sandbox fail-ledger-write-failed-line
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.000002 FOCUS_VIOLATION_LEDGER_FAILED errno=28" > "$LOG"
  run_check
  expect "agent.log holds a FOCUS_VIOLATION_LEDGER_FAILED line" FAIL 1 "ledger-write-failed" ""
}
scn_fail_ledger_behind_counter() {
  new_sandbox fail-ledger-behind
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000100 pid=4242 counter=1 violations=0'
  run_check
  expect "a BOOT counter above the ledger's VIOLATION lines" FAIL 1 "ledger-behind-counter" ""
}
scn_fail_ledger_violation_then_crash_then_restart() {
  new_sandbox fail-ledger-crash
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000050 pid=100 counter=0 violations=0' '1792000001.000100 VIOLATION n=1 pid=100 trigger=launch notification=NSApplicationDidBecomeActiveNotification' 'BOOT 1792000002.000100 pid=4242 counter=1 violations=1'
  run_check
  expect "a violation, a crash, a restart (two BOOTs): the first violation is still counted" FAIL 1 "ledger-violation" ""
}
scn_fail_rollback_then_return() {
  # The ledger-unaware agent advanced status.json to 1 with no VIOLATION line and no BOOT for its pid; the new build's BOOT says counter=1.
  new_sandbox fail-ledger-rollback; set_status 1 0
  write_ledger "$LEDGER_HEADER" 'BOOT 1792000000.000050 pid=100 counter=0 violations=0' 'BOOT 1792000003.000100 pid=4242 counter=1 violations=0'
  run_check
  expect "rollback to a build without the ledger, status advanced to 1, then the new build returns" FAIL 1 "focusViolations-nonzero,ledger-behind-counter" ""
  check "rollback: the history line is incomplete and says rollback period" bash -c "[ \"$(hist_complete)\" = false ] && printf '%s' \"$(hist_text)\" | grep -q 'rollback period'"
}

# -- FAIL wins over NOT RUN, and the NOT RUN gaps are printed as well --
scn_fail_wins_ledger_missing_status_counter() {
  new_sandbox fail-wins-missing; rm -f -- "$LEDGER_F"; set_status 1 0; run_check
  expect "the ledger is missing and status.json says focusViolations 1" FAIL 1 "focusViolations-nonzero" "ledger-missing"
}
scn_fail_wins_log1_unreadable_ledger_violation() {
  new_sandbox fail-wins-log1; printf '%s\n' "$VIOLATION_LINE" >> "$LEDGER_F"
  printf 'older\n' > "$LOG1"; chmod 000 "$LOG1"
  run_check
  chmod 600 "$LOG1"
  expect "agent.log.1 is unreadable and the ledger holds a VIOLATION" FAIL 1 "ledger-violation" "log-unreadable:agent.log.1"
}
scn_fail_wins_final_read_fails_log_line() {
  new_sandbox fail-wins-final
  sc_append 12 "$LOG" "$TS.900001 FOCUS_VIOLATION trigger=drag notification=NSWindowDidBecomeMainNotification"
  sc_hook 3 "chmod 000 $(printf '%q' "$LEDGER_F")"
  run_check
  chmod 600 "$LEDGER_F"
  expect "the final ledger read fails and agent.log holds a FOCUS_VIOLATION line" FAIL 1 "focus-violation-line" "ledger-final-read-failed"
}

# -- evidence before exit: every retained source is read before an outcome is chosen, so a violation any of them records is a FAIL even when
#    the run never opened its window (preflight could not read status.json, the agent was not loaded) --
scn_fail_evidence_before_exit_status_truncated() {
  new_sandbox fail-evidence-status-truncated
  printf '%s\n' "$VIOLATION_LINE" >> "$LEDGER_F"
  printf '{"focusViolations":' > "$STATUS"
  run_check
  expect "a ledger VIOLATION, then status.json truncated by a careless edit (preflight cannot read it)" FAIL 1 "ledger-violation" "status-unreadable"
  check "evidence before exit: the window did not run" equals "$(jget window_ran)" false
  check "evidence before exit: the ledger's violation is in the evidence" equals "$(jget ledger.violation_lines_end)" 1
  check "evidence before exit: the history line is still reported" contains "$(hist_text)" "since ledger birth"
}
scn_fail_evidence_before_exit_counter_only() {
  new_sandbox fail-evidence-counter-only
  printf '{"focusViolations":1}\n' > "$STATUS"
  run_check
  expect "status.json holds focusViolations 1 but lacks displayChangeCount (preflight cannot use it)" FAIL 1 "focusViolations-nonzero" "status-unreadable"
}
scn_fail_evidence_before_exit_log_line_not_loaded() {
  new_sandbox fail-evidence-not-loaded
  echo unloaded > "$STUB/launchctl.1"
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  run_check
  expect "agent.log holds a FOCUS_VIOLATION line and the agent is not loaded" FAIL 1 "focus-violation-line" "not-loaded"
}
scn_fail_evidence_before_exit_ledger_write_failed() {
  new_sandbox fail-evidence-ledger-failed
  set_status 0 0 1
  echo unloaded > "$STUB/launchctl.1"
  run_check
  expect "status.json says the ledger could not be written and the agent is not loaded" FAIL 1 "ledger-write-failed" "not-loaded"
}
scn_nr_status_truncated_no_violation_anywhere() {
  new_sandbox nr-status-truncated-clean
  printf '{"focusViolations":' > "$STATUS"
  run_check
  expect "status.json truncated and no source records a violation: NOT RUN, reported only then" "NOT RUN" 3 "" "status-unreadable"
}

# -- history: a broken event line makes the history say incomplete, naming the count --
scn_history_torn_event_is_incomplete() {
  new_sandbox hist-torn-event
  printf '1792000007.000500 VIOLATION n=1 pid=42' >> "$LEDGER_F"
  run_check
  expect "a cut violation line (history check)" FAIL 1 "ledger-torn-line" ""
  check "a torn event: the history line says incomplete and names the count" bash -c "[ \"$(hist_complete)\" = false ] && printf '%s' \"$(hist_text)\" | grep -q '1 torn or unknown ledger line(s)'"
}
scn_history_unknown_line_is_incomplete() {
  new_sandbox hist-unknown-line
  write_ledger "$LEDGER_HEADER" "$BOOT_4242" 'HELLO from nowhere' 'HELLO again'
  run_check
  expect "two complete unknown lines (history check)" "NOT RUN" 3 "" "ledger-malformed"
  check "unknown lines: the history line says incomplete and names the count" bash -c "[ \"$(hist_complete)\" = false ] && printf '%s' \"$(hist_text)\" | grep -q '2 torn or unknown ledger line(s)'"
}

# -- agent.log renamed between the check that it exists and its open (an ordinary rotation) --
# The seam CLAWD_ATTENDED_SCAN_HOOK runs between the check and the open, with the file and the attempt number. once: the first call renames
# agent.log to agent.log.1, the next call (the retry) creates the new agent.log. every: each pass's first attempt at agent.log renames it, its
# next attempt creates the new one, and the scan of agent.log.1 that starts the next pass creates it when it is missing (so without the retry
# every pass ends on a failed open).
write_scan_hook() { # MODE
  cat > "$SB/scan-hook" <<HOOK
#!/bin/bash
f="\$1"; case "\$f" in */agent.log|*/agent.log.1) ;; *) exit 0 ;; esac
[ "$1" = every ] || case "\$f" in */agent.log.1) exit 0 ;; esac
st="\$(dirname "\$0")"
if [ "$1" = every ]; then
  case "\$1" in */agent.log.1) [ -e "\${1%.1}" ] || printf 'STATE scene=idle new generation\n' > "\${1%.1}"; exit 0 ;; esac
  if [ "\$2" = 0 ]; then [ -e "\$f" ] && /bin/mv "\$f" "\$f.1"; exit 0; fi
  [ -e "\$f" ] || printf 'STATE scene=idle new generation\n' > "\$f"
  exit 0
fi
if [ ! -e "\$st/rotated" ]; then : > "\$st/rotated"; /bin/mv "\$f" "\$f.1"; exit 0; fi
if [ ! -e "\$f" ] && [ ! -e "\$st/created" ]; then : > "\$st/created"; printf 'STATE scene=idle new generation\n' > "\$f"; fi
HOOK
  chmod 755 "$SB/scan-hook"
}
scan_unit() { # runs scan_logs of the sourced script on the sandbox's files; prints "gaps=[..] fv=N"
  "$CHECK_BASH" -c "source '$SCRIPT'; LOG='$LOG'; LOG1='$LOG1'; WORK='$SB/work'; SCAN_HOOK='$SB/scan-hook'; mkdir -p \"\$WORK\"; scan_logs; echo \"gaps=[\$LOG_GAPS] fv=\$FV_RETAINED\"" 2>&1
}
scn_scan_rotation_between_check_and_open() {
  # agent.log holds a FOCUS_VIOLATION line; it is renamed to agent.log.1 after the check and before the open, and a new agent.log appears on the
  # retry. The open is retried and read from its new name, and the content that moved is read again from agent.log.1: no gap, the violation counted.
  new_sandbox scan-rename-race
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  write_scan_hook once
  out="$(scan_unit)"
  check "scan: a rename between the check and the open is not an unreadable file" equals "$out" "gaps=[] fv=1"
}
scn_scan_evidence_survives_a_rotation_between_passes() {
  # agent.log.1 holds a FOCUS_VIOLATION line and is read in the first pass; then agent.log rotates onto agent.log.1, so that file and its
  # violation are gone before the second pass. The violation the first pass read still counts.
  new_sandbox scan-evidence-kept
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG1"
  printf '%s\n' "$TS.400001 STATE scene=idle" > "$LOG"
  write_scan_hook once
  out="$(scan_unit)"
  check "scan: a violation read in one pass survives a rotation that removes its file before the next pass" equals "$out" "gaps=[] fv=1"
}
scn_scan_rotation_in_every_pass() {
  # The log rotates at every pass: the passes run out (LOG_READ_TRIES) and the last one stands. Its open of agent.log hits the rename and is
  # retried from its new name, so even then the result is no gap.
  new_sandbox scan-rename-every-pass
  printf '%s\n' "$TS.000001 STATE scene=idle" > "$LOG"
  write_scan_hook every
  out="$(scan_unit)"
  check "scan: the log rotating at every pass still leaves no log-unreadable gap" equals "$out" "gaps=[] fv=0"
}
scn_scan_file_that_stays_unreadable_is_a_gap() {
  # The control: a file that exists and cannot be read is a gap, rotation or not.
  new_sandbox scan-unreadable
  printf '%s\n' "$TS.000001 STATE scene=idle" > "$LOG"; chmod 000 "$LOG"
  out="$("$CHECK_BASH" -c "source '$SCRIPT'; LOG='$LOG'; LOG1='$LOG1'; WORK='$SB/work'; SCAN_HOOK=''; mkdir -p \"\$WORK\"; scan_logs; echo \"gaps=[\$LOG_GAPS]\"" 2>&1)"
  chmod 600 "$LOG"
  check "scan: agent.log present but mode 000 is still log-unreadable" equals "$out" "gaps=[agent.log]"
}
scn_fail_scan_rotation_race_end_to_end() {
  new_sandbox fail-scan-rename-race
  printf '%s\n' "$TS.000001 STATE scene=idle" "$TS.300001 FOCUS_VIOLATION trigger=click notification=NSApplicationDidBecomeActiveNotification" > "$LOG"
  write_scan_hook once
  EXTRA_ENV="CLAWD_ATTENDED_SCAN_HOOK=$SB/scan-hook"
  run_check
  expect "an ordinary rotation during the log scan, with a violation in the rotated content: FAIL, never NOT RUN log-unreadable" FAIL 1 "focus-violation-line" ""
}
scn_pass_scan_rotation_race_end_to_end() {
  new_sandbox pass-scan-rename-race
  write_scan_hook once
  EXTRA_ENV="CLAWD_ATTENDED_SCAN_HOOK=$SB/scan-hook"
  run_check
  expect "an ordinary rotation during the log scan, nothing wrong: PASS" PASS 0 "" ""
  check "the scan rotation: noted as a rotation, not a gap" equals "$(jget window.rotated)" true
}

for s in $(declare -F | awk '{ print $3 }' | grep '^scn_' | grep -v -e '^scn_interrupt$' -e '^scn_kill$' -e '^scn_m_interrupt$'); do wanted "$s" && spawn "$s"; done
wanted scn_interrupt && spawn scn_interrupt TERM
wanted scn_interrupt && spawn scn_interrupt INT
wanted scn_interrupt && spawn scn_interrupt HUP
wanted scn_m_interrupt && spawn scn_m_interrupt TERM
wanted scn_m_interrupt && spawn scn_m_interrupt INT
wanted scn_m_interrupt && spawn scn_m_interrupt HUP
wanted scn_kill && spawn scn_kill
drain

# ---- refusals and mode gates (fast, no stub run) -----------------------------------------------------------------------------------
RES="$RESDIR/zz-refusals"; : > "$RES"
# Runs outside a sandbox use an EMPTY fake HOME: were a gate to fail, the script would find no install there and stop at not-installed
# before it asked launchctl anything.
EH="$STAGE/empty-home"; mkdir -p "$EH"
noflag() { env -i HOME="$EH" PATH="/usr/bin:/bin" "$@" "$CHECK_BASH" "$SCRIPT" 2>&1; }
before_tree="$(cd "$EH" && find . | sort)"
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "no --real outside a sandbox: exit 64" equals "$RC" 64
check "no --real: says --real is needed" contains "$OUT" "--real"
check "no --real: nothing was written (the fake HOME is unchanged)" test "$(cd "$EH" && find . | sort)" = "$before_tree"
check "no --real: no evidence file in the repo's .evidence was created by this run" bash -c "! find '$REPO/.evidence' -maxdepth 1 -name 'attended-check-*' -newer '$STAGE' 2>/dev/null | grep -q ."
for seam in CLAWD_LAUNCHCTL=/bin/echo CLAWD_ATTENDED_SAMPLER=/bin/echo CLAWD_ATTENDED_LSAPPINFO=/bin/echo CLAWD_ATTENDED_COUNTDOWN_STEP_S=0 CLAWD_ATTENDED_KEYS=/bin/echo; do
  OUT="$(noflag "$seam")"; RC=$?
  check "a seam outside a sandbox and no --real ($seam): exit 64" equals "$RC" 64
  check "... refused at the flag gate, nothing read (the fake HOME is unchanged)" test "$(cd "$EH" && find . | sort)" = "$before_tree"
done
new_sandbox refusals
# the seam refusal behind the flag gate is tested as a function call: the flag is never passed to a script run outside a sandbox
for seam in CLAWD_LAUNCHCTL CLAWD_ATTENDED_SAMPLER CLAWD_ATTENDED_LSAPPINFO CLAWD_ATTENDED_COUNTDOWN_STEP_S CLAWD_ATTENDED_KEYS; do
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$seam=1" "$CHECK_BASH" -c "source '$SCRIPT'; resolve_mode" 2>&1)"; RC=$?
  check "resolve_mode refuses $seam outside a sandbox with 64" equals "$RC" 64
  check "resolve_mode names $seam" contains "$OUT" "$seam"
done
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" CLAWD_ATTENDED_SCAN_HOOK=/bin/echo "$CHECK_BASH" -c "source '$SCRIPT'; resolve_mode" 2>&1)"; RC=$?
check "resolve_mode refuses the scan-hook seam outside a sandbox with 64" equals "$RC" 64
check "resolve_mode names CLAWD_ATTENDED_SCAN_HOOK" contains "$OUT" "CLAWD_ATTENDED_SCAN_HOOK"
sandbox_env() { env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 STUB_DIR="$STUB" "$@"; }
OUT="$(sandbox_env "$CHECK_BASH" "$SCRIPT" --real 2>&1)"; RC=$?
check "the real-mode flag inside a sandbox run: exit 64, the sandbox refuses it" equals "$RC" 64
check "... and nothing ran (no evidence file)" bash -c "! ls '$SB'/evidence/attended-check-*.json"
OUT="$(sandbox_env "$CHECK_BASH" "$SCRIPT" --attended 2>&1)"; RC=$?
check "an unknown argument: exit 64" equals "$RC" 64
for bad in 0 601 abc -3 "" 1.5; do
  OUT="$(sandbox_env "$CHECK_BASH" "$SCRIPT" --seconds "$bad" 2>&1)"; RC=$?
  check "--seconds '$bad': exit 64" equals "$RC" 64
done
OUT="$(sandbox_env "$CHECK_BASH" "$SCRIPT" --seconds 2>&1)"; RC=$?
check "--seconds with no value: exit 64" equals "$RC" 64
check "bad arguments ran nothing (no evidence file, no window list asked for)" bash -c "! ls '$SB'/evidence/attended-check-*.json && [ ! -e '$STUB/windows.count' ]"
# the sandbox gates, each broken in turn (a gate check is a call of the function, never of real mode)
OUT="$(sandbox_env CLAWD_ATTENDED_SAMPLER= "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "a sandbox without the sampler seam: exit 64" equals "$RC" 64
OUT="$(sandbox_env CLAWD_ATTENDED_LSAPPINFO= "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "a sandbox without the lsappinfo seam: exit 64" equals "$RC" 64
OUT="$(sandbox_env CLAWD_LAUNCHCTL=/nonexistent/launchctl "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "a seam that is not an executable file: exit 64" equals "$RC" 64
rm -- "$SB/.attended-sandbox"
OUT="$(sandbox_env "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "a sandbox without its marker file: exit 64" equals "$RC" 64
: > "$SB/.attended-sandbox"
mkdir -p "$SB/elsewhere"
OUT="$(env -i HOME="$SB/elsewhere" PATH="/usr/bin:/bin" CLAWD_ATTENDED_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "HOME outside the sandbox: exit 64" equals "$RC" 64
outside="$(mktemp -d "${TMPDIR:-/tmp}/attended-outside.XXXXXX")"
mkdir -p "$outside/home"; : > "$outside/.attended-sandbox"
OUT="$(env -i HOME="$outside/home" PATH="/usr/bin:/bin" CLAWD_ATTENDED_SANDBOX="$outside" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_ATTENDED_SAMPLER="$STUBS/sampler" CLAWD_ATTENDED_LSAPPINFO="$STUBS/lsappinfo-front" CLAWD_ATTENDED_KEYS="$STUBS/keys" CLAWD_ATTENDED_COUNTDOWN_STEP_S=0.2 "$CHECK_BASH" "$SCRIPT" 2>&1)"; RC=$?
check "a sandbox outside .build: exit 64" equals "$RC" 64
rmdir "$outside/home" 2>/dev/null; rm -- "$outside/.attended-sandbox" 2>/dev/null; rmdir "$outside" 2>/dev/null

# ---- the --real lint: no test file passes --real to a check script ------------------------------------------------------------------
for f in "$REPO"/Tests/*.test.sh; do
  [ "$(basename "$f")" = "$(basename "$0")" ] && continue
  check "no test invokes a check script with --real ($(basename "$f"))" lint_no_real_flag "$f"
done
printf '%s\n' 'bash "$SCRIPT" --re''al' > "$STAGE/lint-bad-1.sh"
printf '%s\n' 'out="$(env -i HOME=x /bin/bash scripts/attended-check.sh --re''al 2>&1)"' > "$STAGE/lint-bad-2.sh"
printf '%s\n' 'bash scripts/post-install-check.sh --seconds 3 --re''al' > "$STAGE/lint-bad-3.sh"
printf '%s\n' 'scripts/pre-install-snapshot.sh --re''al' > "$STAGE/lint-bad-4.sh"
printf '%s\n' '# bash "$SCRIPT" --re''al   (a comment)' 'bash "$SCRIPT" --seconds 3' > "$STAGE/lint-ok.sh"
for n in 1 2 3 4; do check "the --real lint catches a planted invocation ($n)" bash -c "$(declare -f lint_no_real_flag); ! lint_no_real_flag '$STAGE/lint-bad-$n.sh'"; done
check "the --real lint leaves comments and other arguments alone" bash -c "$(declare -f lint_no_real_flag); lint_no_real_flag '$STAGE/lint-ok.sh'"
check "this file passes its own lint" lint_no_real_flag "$0"

# ---- the default window and the sampler-liveness check, as function calls ----------------------------------------------------------------
check "the default observation window is 15 s" equals "$("$CHECK_BASH" -c "source '$SCRIPT'; echo \$DEFAULT_SECONDS")" 15
live_fixture() { # a samples file with three samples in it
  LIVE_DIR="$STAGE/liveness-$1"; mkdir -p "$LIVE_DIR"; SAMPLES_FILE="$LIVE_DIR/samples.txt"
  printf 'SAMPLING pid=1\n100000 5\n100020 5\n100040 5\n' > "$SAMPLES_FILE"
}
# two helper programs the liveness cases start themselves: one that keeps the sampler clock moving, one that does nothing
cat > "$STAGE/clock-mover" <<'MOVER'
#!/bin/bash
ms=100060
while :; do echo "$ms 5" >> "$1"; ms=$((ms + 20)); sleep 0.02; done
MOVER
cat > "$STAGE/idler" <<'IDLER'
#!/bin/bash
exec sleep 30
IDLER
chmod 755 "$STAGE/clock-mover" "$STAGE/idler"
liveness_case() { # kind -> exit status of sampler_still_producing in a shell that sourced the script
  "$CHECK_BASH" -c "
    source '$SCRIPT'; SAMPLES='$SAMPLES_FILE'; SAMPLER_PID=''
    case '$1' in
      moving) '$STAGE/clock-mover' '$SAMPLES_FILE' & SAMPLER_PID=\$! ;;
      frozen) '$STAGE/idler' & SAMPLER_PID=\$! ;;
    esac
    sampler_still_producing; r=\$?
    [ -z \"\$SAMPLER_PID\" ] || kill \"\$SAMPLER_PID\" 2>/dev/null
    exit \$r"
}
live_fixture dead;   check "sampler_still_producing: no sampler job at all is not producing" bash -c "$(declare -f liveness_case); CHECK_BASH='$CHECK_BASH'; SCRIPT='$SCRIPT'; STAGE='$STAGE'; SAMPLES_FILE='$SAMPLES_FILE'; ! liveness_case dead"
live_fixture frozen; check "sampler_still_producing: a running job whose clock does not move is not producing" bash -c "$(declare -f liveness_case); CHECK_BASH='$CHECK_BASH'; SCRIPT='$SCRIPT'; STAGE='$STAGE'; SAMPLES_FILE='$SAMPLES_FILE'; ! liveness_case frozen"
# A producing sampler is proved by one success; a starved one (a loaded machine) gets ten tries, since a failed try is the check being cautious.
# The dead and frozen cases above must fail on every try, and do.
producing_within_ten_tries() { local n=0; while [ "$n" -lt 10 ]; do liveness_case moving && return 0; n=$((n + 1)); done; return 1; }
live_fixture moving; check "sampler_still_producing: a running job whose clock moves is producing" bash -c "$(declare -f liveness_case producing_within_ten_tries); CHECK_BASH='$CHECK_BASH'; SCRIPT='$SCRIPT'; STAGE='$STAGE'; SAMPLES_FILE='$SAMPLES_FILE'; producing_within_ten_tries"

# ---- the script is a read-only observer ---------------------------------------------------------------------------------------------
grep -vE '^[[:space:]]*#' "$SCRIPT" > "$STAGE/script.code"
check "launchctl is only ever called with list" bash -c "[ \"\$(grep -c 'LAUNCHCTL\" ' '$STAGE/script.code')\" = 1 ] && grep -q '\"\$LAUNCHCTL\" list ' '$STAGE/script.code' && ! grep -E '(\\\$LAUNCHCTL|/bin/launchctl)\"? +(bootstrap|bootout|kickstart|load|unload|start|stop|remove|enable|disable|kill|submit)' '$STAGE/script.code'"
check "the script runs no other repo script and not the CLI (it sources check-common.sh and nothing else)" bash -c "! grep -E '\\\$REPO/(bin|scripts)/' '$STAGE/script.code' | grep -v 'check-common.sh' | grep -q ."
check "the script never opens a window or an app" bash -c "! grep -E '(^|[;&|( ])open +|/usr/bin/open|osascript|cliclick|screencapture|CGEvent|AXIsProcessTrusted|\.app/' '$STAGE/script.code'"
check "the script never looks processes up by name (no pgrep, pkill, killall)" bash -c "! grep -E '(^|[^a-z_])(pgrep|pkill|killall)( |\$)' '$STAGE/script.code'"
check "the script signals two things: the sampler it started and, in menu mode, the reader of the typed word, both through ck_kill_job (which signals only a running job of the shell)" bash -c "! grep -E '(^|[^a-z_])kill +' '$STAGE/script.code' && [ \"\$(grep -c 'ck_kill_job' '$STAGE/script.code')\" = 2 ] && grep -qF 'ck_kill_job \"\$SAMPLER_PID\"' '$STAGE/script.code' && grep -qF 'ck_kill_job \"\$READER_PID\"' '$STAGE/script.code'"
check "ck_kill_job is the one place kill appears in the shared library, and it checks the job table first" bash -c "grep -vE '^[[:space:]]*#' '$REPO/scripts/check-common.sh' > '$STAGE/common.code'; [ \"\$(grep -cE '(^|[^a-z_])kill +' '$STAGE/common.code')\" = 1 ] && grep -qF 'jobs -rp' '$STAGE/common.code'"
check "the script never writes to the agent's files (no redirection into the install root)" bash -c "! grep -E '(^|[[:space:]0-9])>>? *\"?\\\$(ROOT|LOG|LOG1|STATUS|MANIFEST)[^_A-Za-z0-9]' '$STAGE/script.code'"
check "the script never removes a tree" bash -c "! grep -E 'rm +-[a-zA-Z]*[rR]|rm +--recursive' '$STAGE/script.code'"

SAMPLER_SRC="$REPO/Sources/ClawdAttendedSampler/main.swift"
grep -vE '^[[:space:]]*//' "$SAMPLER_SRC" > "$STAGE/sampler.code"
check "the sampler runs with the .prohibited activation policy" grep -qF 'setActivationPolicy(.prohibited)' "$STAGE/sampler.code"
check "the sampler polls NSWorkspace's frontmost application from a Timer on the main run loop, every tick" bash -c "grep -qF 'NSWorkspace.shared.frontmostApplication' '$STAGE/sampler.code' && grep -qF 'Timer(timeInterval' '$STAGE/sampler.code' && grep -qF 'RunLoop.main.add(timer' '$STAGE/sampler.code'"
check "the sampler opts out of App Nap and timer coalescing, so its 20 ms heartbeat is not stretched" bash -c "grep -qF 'beginActivity' '$STAGE/sampler.code' && grep -qF 'latencyCritical' '$STAGE/sampler.code'"
check "the sampler prints a heartbeat line on every tick" grep -qF 'print("\(uptimeMilliseconds()) \(front)")' "$STAGE/sampler.code"
check "the sampler reads the window list without titles (owner pid, layer, bounds only)" bash -c "grep -qF 'CGWindowListCopyWindowInfo' '$STAGE/sampler.code' && ! grep -qE 'kCGWindowName' '$STAGE/sampler.code'"
check "the sampler has no window, no panel, no permission request, no event, no activation" bash -c "! grep -E 'NSWindow\\(|NSPanel\\(|NSAlert|requestAuthorization|AXIsProcessTrusted|CGRequest|CGEventPost|CGEventCreate|\\.activate\\(|activateIgnoringOtherApps|makeKey|orderFront|NSWorkspace\\.shared\\.open|launchApplication' '$STAGE/sampler.code'"
check "the sampler is a SwiftPM target under Sources/, so the production lint scans it" bash -c "grep -qF 'ClawdAttendedSampler' '$REPO/Package.swift' && bash '$REPO/scripts/lint-banned.sh' >/dev/null"

# ---- nothing left behind ----------------------------------------------------------------------------------------------------------------
RES="$RESDIR/zz-final"; : > "$RES"
check "no stub sampler is left running from this test's stage" bash -c "! ps -axo command= | grep -F '$STAGE' | grep -v grep | grep -qE 'sampler|attended-check'"
check "the stage's sandboxes hold no .partial evidence file" bash -c "! find '$STAGE' -name '.attended-check-*.partial.*' | grep -q ."

# ---- tally ------------------------------------------------------------------------------------------------------------------------------
tally attended-check.test
