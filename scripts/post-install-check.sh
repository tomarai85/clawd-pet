#!/bin/bash
# post-install-check.sh: the post-install check for clawd-pet on the real machine (spec section 6, done-bar item 6 (a); round 4 carry-over,
# findings 3 and 4). The user has installed and started the pet. This script is STRICTLY READ-ONLY: it reads launchctl's list, the window
# list, lsappinfo and a few files, and writes one evidence file under .evidence/. It runs nothing from the install, signals nothing and
# changes no setting. (Check (b), the direct exec of the agent, lives in scripts/direct-exec-check.sh, a separate step with its own gate
# that runs a COPY of the agent outside the install; the settings step lives in scripts/post-install-settings-step.sh, also gated.)
#
#   (a) launchd start: the agent is alive 5 s after the check began observing it (launchctl lists the same pid at the start and 5 s
#       later), and its panel (the stage window: the agent's largest on-screen window; the body window beside it is smaller) is in the
#       window server's window list with the agent's pid as owner (CGWindowList through the read-only sampler's `windows` command). Without Aqua Voice running the pet is hidden by design: then (a) is NOT RUN, never PASS.
#   (a2) the launcher is intact: the plist's program is the installed launcher (ProgramArguments[0] = $ROOT/bin/clawd-pet-launch) and the
#       installed launcher is byte-identical to the one the repo records (launcher/clawd-pet-launch.sha256). A different launcher is a
#       different background item for macOS (the notice comes back).
#   (a3) the installed art is whole: every file the installed atlas (art/clawd-atlas.json) names - pose frames, motion frames, look
#       layers - exists as a regular file under the installed art directory. The agent draws each motion and look from that tree; a
#       catalog that names a file the install lacks loses the picture mid-dictation (RENDER failed, the window goes). A missing file,
#       or an atlas that cannot be read, is a FAIL naming the first few paths.
#   (c) the uninstall comparison is scripts/pre-install-snapshot.sh (taken immediately before the real install; compared at a real
#       uninstall only when the user asks for one). The fake-HOME tests carry (c) until then.
#
# Verdicts (exit 0 PASS, 1 FAIL, 3 NOT RUN; one JSON file under .evidence/ holds every figure, the verdict and the reasons):
#   FAIL     agent-not-alive-after-5s (no pid after the wait), agent-restarted (the pid changed within the wait), panel-missing (Aqua
#            Voice runs and the agent has no on-screen window), launcher-missing, launcher-changed, plist-not-launcher, art-missing
#            (a file the installed atlas names is not under the installed art directory, or the atlas is unreadable).
#   NOT RUN  not-installed, not-loaded, window-lister-failed, panel-not-visible (Aqua Voice not running), launcher-record-unreadable.
#   PASS     none of the above.
#
# Real mode needs the flag `--real`; without it (and outside a sandbox run) the script refuses with 64 before reading anything. Tests run
# it in a sandbox with every external effect stubbed (see check-common.sh). Seams: CLAWD_POSTINSTALL_SANDBOX, CLAWD_LAUNCHCTL,
# CLAWD_POSTINSTALL_SAMPLER (a stub of the helper's `windows` command), CLAWD_POSTINSTALL_LSAPPINFO, CLAWD_POSTINSTALL_SETTLE_S.
#
# Usage: scripts/post-install-check.sh --real
# `source` this file to get the functions without running anything.

set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK_REPO="$REPO"
. "$REPO/scripts/check-common.sh"

LABEL="com.tomtim.clawd-pet"
AQUA_BUNDLE="com.electron.aqua-voice"
SCOPE="Check (a) of spec section 6 item 6 on this machine, read-only: the launchd-started agent stays alive for 5 s and has its panel in the window list; the plist names the installed launcher, which is the recorded one. It runs nothing from the install. Check (b) is scripts/direct-exec-check.sh (gated, runs a copy outside the install); check (c), the uninstall comparison, is scripts/pre-install-snapshot.sh."
SEAM_VARS="CLAWD_LAUNCHCTL CLAWD_POSTINSTALL_SAMPLER CLAWD_POSTINSTALL_LSAPPINFO CLAWD_POSTINSTALL_SETTLE_S"

P0=""; P1=""; PANEL=""; AQUA_RUNNING=""
PLIST_PROGRAM=""; LAUNCHER_SHA=""; LAUNCHER_RECORDED=""; LAUNCHER_OK=""
ART_NAMED=""; ART_MISSING_COUNT=""; ART_MISSING_FIRST=""
EVIDENCE_FILE=""; WORK=""; START_EPOCH=0; VERDICT=""; EXIT_CODE=""

resolve_mode() {
  ck_resolve_mode post-install-check CLAWD_POSTINSTALL_SANDBOX .postinstall-sandbox "$SEAM_VARS" \
    "CLAWD_LAUNCHCTL CLAWD_POSTINSTALL_SAMPLER CLAWD_POSTINSTALL_LSAPPINFO" || return $?
  if [ "$CK_SANDBOX_MODE" = 1 ]; then
    LAUNCHCTL="$CLAWD_LAUNCHCTL"
    SAMPLER="$CLAWD_POSTINSTALL_SAMPLER"
    LSAPPINFO="$CLAWD_POSTINSTALL_LSAPPINFO"
    SETTLE_S="$CLAWD_POSTINSTALL_SETTLE_S"
    ck_is_number "$SETTLE_S" || { ck_warn "post-install-check: refused: CLAWD_POSTINSTALL_SETTLE_S is not a number"; return 64; }
    EVID="$CK_SANDBOX/evidence"
  else
    LAUNCHCTL="/bin/launchctl"
    SAMPLER="$(ck_find_tool clawd-attended-sampler)"
    LSAPPINFO="/usr/bin/lsappinfo"
    SETTLE_S=5
    EVID="$REPO/.evidence"
  fi
  ROOT="$HOME/Library/Application Support/clawd-pet"
  MANIFEST="$ROOT/manifest"
  LAUNCHER="$ROOT/bin/clawd-pet-launch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  return 0
}

# One `launchctl list` call. Sets AGENT_PID (empty when the job has no process); returns 1 when the label is not listed.
read_agent() {
  local out
  AGENT_PID=""
  out="$("$LAUNCHCTL" list "$LABEL" 2>/dev/null)" || return 1
  AGENT_PID="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/.*"PID" = \([0-9][0-9]*\);.*/\1/p' | head -n 1)"
  return 0
}

aqua_running() { [ -n "$("$LSAPPINFO" find "bundleid=$AQUA_BUNDLE" 2>/dev/null)" ]; }

# check (a)
check_launchd_start() {
  local lines rc
  if ! read_agent; then notrun not-loaded "launchctl does not list $LABEL: the pet has not been started"; return 1; fi
  P0="$AGENT_PID"
  if [ -z "$P0" ]; then notrun not-loaded "$LABEL is loaded but has no running process"; return 1; fi
  sleep "$SETTLE_S"
  read_agent || true
  P1="$AGENT_PID"
  if [ -z "$P1" ]; then fail agent-not-alive-after-5s "the agent (pid $P0) had no process $SETTLE_S s later"; return 0; fi
  if [ "$P1" != "$P0" ]; then fail agent-restarted "the agent's pid changed from $P0 to $P1 within $SETTLE_S s"; return 0; fi
  lines="$(ck_windows "$SAMPLER")"; rc=$?
  if [ "$rc" -ne 0 ]; then notrun window-lister-failed "the window list could not be read"; return 0; fi
  PANEL="$(ck_panel_of_pid "$P1" "$lines")"
  if [ -z "$PANEL" ]; then
    if aqua_running; then AQUA_RUNNING=1; fail panel-missing "Aqua Voice is running and the agent (pid $P1) has no on-screen window in the window list"
    else AQUA_RUNNING=0; notrun panel-not-visible "Aqua Voice is not running, so the pet is hidden by design: start Aqua Voice and run this again"; fi
  fi
  return 0
}

# check (a2): the launcher macOS tracks is the one the repo records. Reads two files and the repo's record; changes nothing.
check_launcher() {
  local record="$REPO/launcher/clawd-pet-launch.sha256"
  PLIST_PROGRAM="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
  if [ "$PLIST_PROGRAM" != "$LAUNCHER" ]; then
    fail plist-not-launcher "the LaunchAgent plist's program is '${PLIST_PROGRAM:-unreadable}', not the installed launcher $LAUNCHER"
  fi
  if [ ! -f "$record" ] || [ "$(grep -c '' "$record")" -ne 1 ]; then
    notrun launcher-record-unreadable "launcher/clawd-pet-launch.sha256 is missing or is not one line"; return 0
  fi
  LAUNCHER_RECORDED="$(cut -d' ' -f1 < "$record")"
  case "$LAUNCHER_RECORDED" in *[!0-9a-f]*|'') notrun launcher-record-unreadable "launcher/clawd-pet-launch.sha256 does not start with a sha256"; return 0 ;; esac
  if [ ! -f "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then fail launcher-missing "$LAUNCHER is not a regular file"; return 0; fi
  LAUNCHER_SHA="$(/usr/bin/shasum -a 256 < "$LAUNCHER" 2>/dev/null | cut -d' ' -f1)"
  if [ "$LAUNCHER_SHA" = "$LAUNCHER_RECORDED" ]; then LAUNCHER_OK=1
  else LAUNCHER_OK=0; fail launcher-changed "the installed launcher has sha256 ${LAUNCHER_SHA:-unreadable}, the repo records $LAUNCHER_RECORDED"; fi
}

# check (a3): the installed art holds every file the installed atlas names. Reads the atlas and looks at the files; changes nothing.
check_art() {
  local atlas="$ROOT/art/clawd-atlas.json" names rel named=0 missing=0 first=""
  ART_NAMED=0; ART_MISSING_COUNT=0; ART_MISSING_FIRST=""
  if [ ! -f "$atlas" ] || [ -L "$atlas" ]; then
    fail art-missing "the installed atlas $atlas is not a regular file"; ART_MISSING_COUNT=1; return 0
  fi
  names="$(/usr/bin/grep -oE '"[^"]*\.png"' "$atlas" 2>/dev/null | /usr/bin/sed -e 's/^"//' -e 's/"$//' | /usr/bin/sort -u)" || true
  if [ -z "$names" ]; then
    fail art-missing "the installed atlas $atlas names no picture at all"; ART_MISSING_COUNT=1; return 0
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    named=$((named + 1))
    case "$rel" in
      /*|*..*) missing=$((missing + 1)); [ "$missing" -gt 3 ] || first="$first${first:+, }$rel"; continue ;;
    esac
    if [ ! -f "$ROOT/art/$rel" ] || [ -L "$ROOT/art/$rel" ]; then
      missing=$((missing + 1)); [ "$missing" -gt 3 ] || first="$first${first:+, }$rel"
    fi
  done < <(printf '%s\n' "$names")
  ART_NAMED="$named"; ART_MISSING_COUNT="$missing"; ART_MISSING_FIRST="$first"
  if [ "$missing" -gt 0 ]; then
    fail art-missing "$missing of the $named files the installed atlas names are not under $ROOT/art (first: $first)"
  fi
}

write_evidence() {
  local commit
  commit="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "check": "post-install-check",\n'
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
    printf '  "launchd_start": {"settle_s": %s, "agent_pid_start": %s, "agent_pid_after_settle": %s, "aqua_voice_running": %s, "panel": %s},\n' \
      "$(jnum "${SETTLE_S:-}")" "$(jnum "$P0")" "$(jnum "$P1")" "$(jbool "$AQUA_RUNNING")" "$(jpanel "$PANEL")"
    printf '  "launcher": {"plist_program": %s, "installed_sha256": %s, "recorded_sha256": %s, "intact": %s},\n' \
      "$(jstr "$PLIST_PROGRAM")" "$(jstr "$LAUNCHER_SHA")" "$(jstr "$LAUNCHER_RECORDED")" "$(jbool "$LAUNCHER_OK")"
    printf '  "art": {"atlas_files": %s, "missing": %s, "first_missing": %s}\n' \
      "$(jnum "$ART_NAMED")" "$(jnum "$ART_MISSING_COUNT")" "$(jstr "$ART_MISSING_FIRST")"
    printf '}\n'
  } | ck_publish "$EVIDENCE_FILE"
}

finish() {
  trap '' INT TERM HUP
  if [ -n "$FAILS" ]; then VERDICT="FAIL"; EXIT_CODE=1
  elif [ -n "$NOTRUNS" ]; then VERDICT="NOT RUN"; EXIT_CODE=3
  else VERDICT="PASS"; EXIT_CODE=0; fi
  if ! write_evidence; then ck_warn "post-install-check: could not write the evidence file $EVIDENCE_FILE"; fi
  ck_say "post-install-check: scope: $SCOPE"
  case "$VERDICT" in
    PASS) ck_say "post-install-check: PASS (agent pid $P1 alive for ${SETTLE_S} s with its panel in the window list; the plist names the recorded launcher; every file the installed atlas names is installed) -> $EVIDENCE_FILE" ;;
    FAIL) ck_say "post-install-check: FAIL ($(printf '%s\n' "$FAILS" | head -n 1)) -> $EVIDENCE_FILE" ;;
    *) ck_say "post-install-check: NOT RUN ($(printf '%s\n' "$NOTRUNS" | head -n 1)) -> $EVIDENCE_FILE" ;;
  esac
  exit "$EXIT_CODE"
}

on_signal() {
  notrun interrupted "the check was interrupted before it finished"
  finish
}

main() {
  local real=0 arg
  for arg in "$@"; do
    case "$arg" in
      --real) real=1 ;;
      *) ck_warn "usage: scripts/post-install-check.sh --real"; return 64 ;;
    esac
  done
  if [ -z "${CLAWD_POSTINSTALL_SANDBOX:-}" ]; then
    if [ "$real" != 1 ]; then
      ck_warn "post-install-check: refused (64): real mode needs the explicit flag --real. Nothing was read or touched."
      return 64
    fi
  elif [ "$real" = 1 ]; then
    ck_warn "post-install-check: refused (64): --real cannot be combined with a sandbox run. Nothing was touched."
    return 64
  fi
  resolve_mode || return $?
  START_EPOCH="$(date +%s)"
  mkdir -p "$EVID" || { ck_warn "post-install-check: cannot create $EVID"; return 64; }
  EVIDENCE_FILE="$EVID/post-install-check-$START_EPOCH-$$.json"
  WORK="$EVID/post-install-check-work/$START_EPOCH-$$"
  mkdir -p "$WORK" || { ck_warn "post-install-check: cannot create $WORK"; return 64; }
  trap on_signal INT TERM HUP
  if [ ! -f "$MANIFEST" ] || [ ! -f "$PLIST" ]; then
    notrun not-installed "no manifest or no LaunchAgent plist: the user installs and starts the pet first"
  elif [ ! -x "$SAMPLER" ]; then
    notrun window-lister-failed "$SAMPLER is not built: swift build -c release"
  else
    check_launchd_start || true
    # The launcher and art checks read files only, so they run whatever (a) found.
    check_launcher
    check_art
  fi
  finish
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
