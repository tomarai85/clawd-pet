#!/bin/bash
# post-install-settings-step.sh: the settings step of the post-install check (spec 7b "Settings, applied (installed agent)"; done-bar item 8).
#
# scripts/post-install-check.sh is strictly read-only (round 4 carry-over, finding 3), and this step CHANGES A SETTING on the running
# installed agent, so it is a separate script with its own gate: it runs the installed CLI twice, `clawd-pet walk off` and then
# `clawd-pet walk on` (if walking is already off: `walk on`, then `walk off`), so the setting ends where it started.
#
#   Each run must exit 0, which the CLI does only after the running agent's status.json shows the matching `appliedGeneration` within 2 s.
#   Then, from the agent's own log, read from the byte offset taken just before the run: a line `SETTINGS applied generation=<n>` with n
#   equal to the generation the run wrote, followed by `WALK disabled` (after `walk off`) or `WALK enabled` (after `walk on`).
#   The agent's pid is the same before the first run, after each run and at the end (the settings apply live, no restart).
#
# Verdicts (exit 0 PASS, 1 FAIL, 3 NOT RUN; one JSON file under .evidence/ holds every figure, the verdict and the reasons):
#   FAIL     cli-exit-nonzero (exit 3 is "saved, not confirmed within 2 s"), generation-not-applied, settings-line-missing,
#            walk-line-missing, walk-line-out-of-order, agent-pid-changed, setting-not-restored.
#   NOT RUN  not-installed, not-loaded, cli-missing, control-unreadable, interrupted.
#   PASS     none of the above.
# An interrupt after the first change runs the restoring change before the script ends (the setting is put back; the receipt says so).
#
# Gate: real mode needs BOTH --real and --change-a-setting. Tests run it in a sandbox (CLAWD_SETTINGS_SANDBOX) with the CLI, launchctl
# and the agent's files stubbed, and pass --change-a-setting only.
# Seams: CLAWD_SETTINGS_SANDBOX, CLAWD_LAUNCHCTL, CLAWD_SETTINGS_CLI.
#
# Usage: scripts/post-install-settings-step.sh --real --change-a-setting
# `source` this file to get the functions without running anything.

set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK_REPO="$REPO"
. "$REPO/scripts/check-common.sh"

LABEL="com.tomtim.clawd-pet"
LOG_WAIT_MS=2000
SCOPE="The installed CLI changes walking off and on again on the running installed agent: each run exits 0 only after status.json shows the matching appliedGeneration within 2 s, agent.log then shows SETTINGS applied generation=<n> followed by WALK disabled / WALK enabled, and the agent's pid does not change. The setting ends where it started."
SEAM_VARS="CLAWD_LAUNCHCTL CLAWD_SETTINGS_CLI"

P0=""; P1=""; ORIGINAL=""; ORIGINAL_WORD=""; FIRST=""; SECOND=""; RESTORE_OWED=0
STEP_ROWS=""
EVIDENCE_FILE=""; START_EPOCH=0; VERDICT=""; EXIT_CODE=""

resolve_mode() {
  ck_resolve_mode post-install-settings-step CLAWD_SETTINGS_SANDBOX .settings-sandbox "$SEAM_VARS" "CLAWD_LAUNCHCTL CLAWD_SETTINGS_CLI" || return $?
  if [ "$CK_SANDBOX_MODE" = 1 ]; then
    LAUNCHCTL="$CLAWD_LAUNCHCTL"
    CLI="$CLAWD_SETTINGS_CLI"
    EVID="$CK_SANDBOX/evidence"
  else
    LAUNCHCTL="/bin/launchctl"
    CLI="$HOME/bin/clawd-pet"
    EVID="$REPO/.evidence"
  fi
  ROOT="$HOME/Library/Application Support/clawd-pet"
  MANIFEST="$ROOT/manifest"
  CONTROL="$ROOT/control.json"
  STATUS="$ROOT/status.json"
  LOG="$ROOT/agent.log"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  return 0
}

agent_pid() { # prints the pid launchctl lists for the job; fails when the label is not listed or has no process
  local out pid
  out="$("$LAUNCHCTL" list "$LABEL" 2>/dev/null)" || return 1
  pid="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/.*"PID" = \([0-9][0-9]*\);.*/\1/p' | head -n 1)"
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}
control_value() { /usr/bin/plutil -extract "$1" raw -o - "$CONTROL" 2>/dev/null; }
status_value() { /usr/bin/plutil -extract "$1" raw -o - "$STATUS" 2>/dev/null; }

# What agent.log shows of one run. Reads LINES (the log after the run's start offset), prints "<settings seen 0|1> <walk line seen 0|1>
# <walk line after the settings line 0|1>". A line is "<epoch> SETTINGS applied generation=<n>" / "<epoch> WALK disabled|enabled".
log_view() { # lines generation word
  printf '%s\n' "$1" | /usr/bin/awk -v gen="$2" -v word="$3" '
    $2 == "SETTINGS" && $3 == "applied" && $4 == "generation=" gen { settings = NR }
    $2 == "WALK" && $3 == word { walk = NR; if (settings && NR > settings) ordered = 1 }
    END { printf "%d %d %d\n", settings ? 1 : 0, walk ? 1 : 0, ordered ? 1 : 0 }'
}

# Runs one change (walk off | walk on) and checks it. $1 = the word (off|on), $2 = the step number (1 or 2).
run_step() {
  local word="$1" n="$2" offset before_pid after_pid rc out start gen applied lines waited want view walk_now
  offset="$(ck_file_size "$LOG")"
  before_pid="$(agent_pid)" || before_pid=""
  start="$(ck_now_ms)"
  out="$("$CLI" walk "$word" 2>&1)"; rc=$?
  local elapsed=$(( $(ck_now_ms) - start ))
  gen="$(control_value generation)"; applied="$(status_value appliedGeneration)"; walk_now="$(control_value walk)"
  after_pid="$(agent_pid)" || after_pid=""
  [ "$n" != 1 ] || FIRST="$walk_now"
  if [ "$rc" -ne 0 ]; then
    fail cli-exit-nonzero "step $n: 'clawd-pet walk $word' exited $rc (0 expected; 3 means saved but not confirmed within 2 s): $(printf '%s' "$out" | head -n 1)"
  fi
  if ! ck_is_uint "$gen"; then
    fail generation-not-applied "step $n: control.json has no readable generation after 'walk $word'"
  elif ! ck_is_uint "$applied" || [ "$applied" -lt "$gen" ]; then
    fail generation-not-applied "step $n: status.json appliedGeneration is '${applied:-missing}' after 'walk $word' wrote generation $gen"
  fi
  if [ "$word" = off ]; then want=disabled; else want=enabled; fi
  # The agent's log may trail its status by a moment: read it again for up to 2 s until both lines are there, in order.
  waited=0
  while :; do
    lines="$(tail -c +"$((offset + 1))" "$LOG" 2>/dev/null)"
    view="$(log_view "$lines" "$gen" "$want")"
    [ "$view" = "1 1 1" ] && break
    [ "$waited" -lt "$LOG_WAIT_MS" ] || break
    sleep 0.05; waited=$((waited + 50))
  done
  case "$view" in
    "0 "*) fail settings-line-missing "step $n: agent.log has no 'SETTINGS applied generation=$gen' line after 'walk $word'" ;;
    "1 0 "*) fail walk-line-missing "step $n: agent.log has no 'WALK $want' line after 'walk $word'" ;;
    "1 1 0") fail walk-line-out-of-order "step $n: 'WALK $want' does not follow 'SETTINGS applied generation=$gen' in agent.log" ;;
  esac
  if [ -z "$before_pid" ] || [ "$before_pid" != "$after_pid" ] || { [ -n "$P0" ] && [ "$after_pid" != "$P0" ]; }; then
    fail agent-pid-changed "step $n: the agent's pid was ${P0:-unknown} at the start, ${before_pid:-none} before and ${after_pid:-none} after 'walk $word'"
  fi
  STEP_ROWS="$STEP_ROWS${STEP_ROWS:+, }{\"step\": $n, \"command\": \"walk $word\", \"exit_code\": $rc, \"elapsed_ms\": $elapsed, \"generation\": $(jnum "$gen"), \"applied_generation\": $(jnum "$applied"), \"walk_after\": $(jstr "$walk_now"), \"log_lines_seen\": \"$view\", \"agent_pid_before\": $(jnum "$before_pid"), \"agent_pid_after\": $(jnum "$after_pid")}"
}

write_evidence() {
  local commit
  commit="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "check": "post-install-settings-step",\n'
    printf '  "verdict": "%s",\n' "$VERDICT"
    printf '  "exit_code": %s,\n' "$EXIT_CODE"
    printf '  "scope": %s,\n' "$(jstr "$SCOPE")"
    printf '  "started_at_epoch": %s,\n' "$START_EPOCH"
    printf '  "repo_commit": %s,\n' "$(jstr "$commit")"
    printf '  "sandbox": %s,\n' "$(jbool "$CK_SANDBOX_MODE")"
    printf '  "fail_codes": %s,\n' "$(jcodes "$FAILS")"
    printf '  "notrun_codes": %s,\n' "$(jcodes "$NOTRUNS")"
    printf '  "fail_reasons": %s,\n' "$(jlist "$FAILS")"
    printf '  "notrun_reasons": %s,\n' "$(jlist "$NOTRUNS")"
    printf '  "walk": {"original": %s, "after_first_change": %s, "at_the_end": %s},\n' "$(jstr "$ORIGINAL")" "$(jstr "$FIRST")" "$(jstr "$SECOND")"
    printf '  "agent_pid": {"start": %s, "end": %s},\n' "$(jnum "$P0")" "$(jnum "$P1")"
    printf '  "steps": [%s]\n' "$STEP_ROWS"
    printf '}\n'
  } | ck_publish "$EVIDENCE_FILE"
}

finish() {
  trap '' INT TERM HUP
  # An interrupt between the two changes leaves the setting flipped: put it back, whatever else happened.
  if [ "$RESTORE_OWED" = 1 ]; then
    "$CLI" walk "$ORIGINAL_WORD" >/dev/null 2>&1 || fail setting-not-restored "the setting could not be put back to walk $ORIGINAL_WORD; run 'clawd-pet walk $ORIGINAL_WORD' yourself"
    RESTORE_OWED=0
  fi
  if [ -n "$ORIGINAL" ]; then SECOND="$(control_value walk)"; fi
  if [ -n "$ORIGINAL" ] && [ -n "$SECOND" ] && [ "$SECOND" != "$ORIGINAL" ] && ! has_reason "$FAILS" setting-not-restored; then
    fail setting-not-restored "walk was $ORIGINAL before the step and is $SECOND after it"
  fi
  if [ -n "$FAILS" ]; then VERDICT="FAIL"; EXIT_CODE=1
  elif [ -n "$NOTRUNS" ]; then VERDICT="NOT RUN"; EXIT_CODE=3
  else VERDICT="PASS"; EXIT_CODE=0; fi
  if ! write_evidence; then ck_warn "post-install-settings-step: could not write the evidence file $EVIDENCE_FILE"; fi
  ck_say "post-install-settings-step: scope: $SCOPE"
  case "$VERDICT" in
    PASS) ck_say "post-install-settings-step: PASS (walk $ORIGINAL -> $FIRST -> $SECOND, each applied by agent pid $P0 within 2 s, with its SETTINGS and WALK lines) -> $EVIDENCE_FILE" ;;
    FAIL) ck_say "post-install-settings-step: FAIL ($(printf '%s\n' "$FAILS" | head -n 1)) -> $EVIDENCE_FILE" ;;
    *) ck_say "post-install-settings-step: NOT RUN ($(printf '%s\n' "$NOTRUNS" | head -n 1)) -> $EVIDENCE_FILE" ;;
  esac
  exit "$EXIT_CODE"
}

on_signal() {
  notrun interrupted "the step was interrupted before it finished"
  finish
}

main() {
  local real=0 gate=0 arg word_first word_second
  for arg in "$@"; do
    case "$arg" in
      --real) real=1 ;;
      --change-a-setting) gate=1 ;;
      *) ck_warn "usage: scripts/post-install-settings-step.sh --real --change-a-setting"; return 64 ;;
    esac
  done
  if [ "$gate" != 1 ]; then
    ck_warn "post-install-settings-step: refused (64): this step changes a setting of the running agent (walk off and on again); it needs the explicit flag --change-a-setting. Nothing was read or changed."
    return 64
  fi
  if [ -z "${CLAWD_SETTINGS_SANDBOX:-}" ]; then
    if [ "$real" != 1 ]; then
      ck_warn "post-install-settings-step: refused (64): real mode needs the explicit flag --real. Nothing was read or changed."
      return 64
    fi
  elif [ "$real" = 1 ]; then
    ck_warn "post-install-settings-step: refused (64): --real cannot be combined with a sandbox run. Nothing was changed."
    return 64
  fi
  resolve_mode || return $?
  START_EPOCH="$(date +%s)"
  mkdir -p "$EVID" || { ck_warn "post-install-settings-step: cannot create $EVID"; return 64; }
  EVIDENCE_FILE="$EVID/post-install-settings-step-$START_EPOCH-$$.json"
  trap on_signal INT TERM HUP
  if [ ! -f "$MANIFEST" ] || [ ! -f "$PLIST" ]; then
    notrun not-installed "no manifest or no LaunchAgent plist: the user installs and starts the pet first"
  elif ! P0="$(agent_pid)"; then
    P0=""; notrun not-loaded "launchctl does not list $LABEL with a process: the pet has not been started"
  elif [ ! -x "$CLI" ]; then
    notrun cli-missing "$CLI is not an executable file"
  elif [ ! -f "$CONTROL" ] || ! /usr/bin/plutil -convert json -o /dev/null "$CONTROL" 2>/dev/null; then
    notrun control-unreadable "control.json is missing or unreadable"
  else
    # A missing walk key reads as the default (true).
    ORIGINAL="$(control_value walk)"
    [ -n "$ORIGINAL" ] || ORIGINAL=true
    if [ "$ORIGINAL" = true ]; then word_first=off; word_second=on; FIRST=false; else word_first=on; word_second=off; FIRST=true; fi
    ORIGINAL_WORD="$word_second"
    RESTORE_OWED=1
    run_step "$word_first" 1
    RESTORE_OWED=1
    run_step "$word_second" 2
    RESTORE_OWED=0
    P1="$(agent_pid)" || P1=""
    if [ -z "$P1" ] || [ "$P1" != "$P0" ]; then fail agent-pid-changed "the agent's pid was $P0 at the start and ${P1:-none} at the end"; fi
  fi
  finish
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
