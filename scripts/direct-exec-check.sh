#!/bin/bash
# direct-exec-check.sh: the gated step that used to be check (b) of scripts/post-install-check.sh (spec section 6, done-bar item 6 (b);
# round 4 carry-over, finding 3 and 4).
#
# RUN THIS STEP ONLY WHILE THE USER WATCHES THE SCREEN. If the agent's launch guard has regressed, the copy is a second pet: it opens a
# window (a window on the user's desktop is the very thing the step exists to find), and nothing in this script can stop that before it
# happens. The data part is contained (below); the window part is the purpose of the check.
#
# scripts/post-install-check.sh only observes. This step RUNS A PROGRAM, so it is a separate script with its own name and an explicit
# gate, and it never runs the installed agent: it copies the installed Mach-O to a scratch directory OUTSIDE the install (under
# .evidence/direct-exec-check-work/), proves the copy byte-identical, and runs the copy once. A copy is the same bytes as the installed
# agent, and the launch guard (not started by launchd, so refused) is a property of those bytes, not of where they sit. The installed
# files, the plist, the launchd job and the running agent are never touched.
#
# The copy runs with its own, new HOME (.evidence/direct-exec-check-work/<run>/home): the agent derives every path it writes (its data
# directory, agent.log, status.json, state.json) from $HOME (PetHome), so with a guard that regressed the copy writes into that scratch
# directory and never into the real install. The script REFUSES to run the copy unless the isolation holds (make_home: a new, empty,
# physical directory that is not the real HOME, is not inside the real install and does not contain it; the observer checks the same
# again before it forks), and the evidence names the directory and what the copy left in it.
#
#   The claim: the agent run outside launchd is refused by its launch guard: it exits 0 within 1 s and creates no window.
#   "No window" needs OBSERVATION, not a lucky read. scripts/direct-exec-observe.pl reads the window list back to back from before the
#   exec until the program has exited, and this script accepts the claim only when the reads cover the program's life:
#     - at least one read began and ended while the program was alive (otherwise nothing was seen: NOT RUN);
#     - every read succeeded (a failed or truncated read at any time is NOT RUN, never skipped);
#     - no stretch of the program's life that no read can have seen is longer than the allowed gap (30 ms; a longer one could hide a
#       window that opened and closed in it: NOT RUN). A read shows the windows as they were at ONE instant somewhere between its start and
#       its end, and nothing says which, so the time inside a read is unobserved: the stretch from one read's start to the next read's end
#       counts (from the exec to the first read's end, for the first), and a read that alone takes longer than the allowed gap is NOT RUN.
#       The gap between the end of one read and the start of the next is only part of it: a lister that takes 500 ms leaves a window that
#       was there from 100 to 200 ms in neither list, with a gap of 1 ms.
#   The real agent lives about 6 ms outside launchd (Sprint 4a's figure), shorter than one window-list read, so on a real machine this
#   step reports NOT RUN with the reason direct-exec-not-observed. That is the honest answer: the instrument cannot see a process that
#   short. Measured on the development Mac 2026-10-19 with this observer (20 reads, load average 17): one read of the window list takes 33 to 41 ms
#   (the first read of a binary at a path the system has not seen before, 490 ms), so the allowed gap of 30 ms is shorter than one read
#   and can never be met either. The limits are left as they are: no limit derived from a read keeps its meaning for a program that
#   lives a few ms (progress-clawd-pet-v2-s10-r2.md has the figures and the options).
#
# Verdicts (exit 0 PASS, 1 FAIL, 3 NOT RUN; one JSON file under .evidence/ holds every figure, the verdict and the reasons):
#   FAIL     direct-exec-exit-nonzero, direct-exec-too-slow (still running at the limit; the script stops the process it started),
#            direct-exec-window (a window owned by the program's pid in any read), direct-exec-copy-differs.
#   NOT RUN  not-installed, direct-exec-failed-to-start (no executable installed agent, or the copy could not be made or started),
#            window-lister-failed (the lister is missing or failed, also on a read during the run), direct-exec-not-observed,
#            direct-exec-observation-gap, interrupted.
#   PASS     none of the above.
#
# Gate: real mode needs BOTH --real and --run-a-copy; either missing refuses with 64 before anything is read or run. Tests run it in a
# sandbox (CLAWD_DIRECTEXEC_SANDBOX) with the window lister and the limits from stubs, and pass --run-a-copy only.
# Seams: CLAWD_DIRECTEXEC_SANDBOX, CLAWD_DIRECTEXEC_SAMPLER, CLAWD_DIRECTEXEC_LIMIT_MS, CLAWD_DIRECTEXEC_MAX_GAP_MS.
#
# Usage: scripts/direct-exec-check.sh --real --run-a-copy
# `source` this file to get the functions without running anything.

set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK_REPO="$REPO"
. "$REPO/scripts/check-common.sh"

SCOPE="The installed agent is copied to a scratch directory outside the install and the copy is run once, outside launchd, with a new scratch HOME of its own (so a guard that regressed writes into the scratch directory, not into the real install): it must exit 0 within 1 s and own no window in any of the window-list reads taken back to back from before the exec to its exit. The installed files, the plist and the launchd job are not touched; the installed agent is not run. Run it only while the user watches: with a regressed guard the copy opens a window."
SEAM_VARS="CLAWD_DIRECTEXEC_SAMPLER CLAWD_DIRECTEXEC_LIMIT_MS CLAWD_DIRECTEXEC_MAX_GAP_MS"
OBSERVER="$REPO/scripts/direct-exec-observe.pl"

COPY=""; COPY_HOME=""; COPY_HOME_FILES=""; COPY_SHA=""; INSTALLED_SHA0=""; INSTALLED_SHA1=""; D_RAN=0; D_PID=""; D_EXIT=""; D_MS=""; D_LIFE_MS=""
D_SNAPS=""; D_INLIFE=""; D_FAILED=""; D_GAP=""; D_WINDOWS=""; D_LIMIT_HIT=0; D_READ_MIN=""; D_READ_MAX=""
EVIDENCE_FILE=""; WORK=""; START_EPOCH=0; VERDICT=""; EXIT_CODE=""; OBSERVER_PID=""

usage() {
  ck_warn "usage: scripts/direct-exec-check.sh --real --run-a-copy"
  ck_warn "  Runs a copy of the installed agent once, outside launchd, with a scratch HOME of its own, and watches the window list."
  ck_warn "  If the agent's launch guard has regressed, the copy opens a window on the screen (that is what the step looks for): run it ONLY while the user watches."
}

resolve_mode() {
  ck_resolve_mode direct-exec-check CLAWD_DIRECTEXEC_SANDBOX .directexec-sandbox "$SEAM_VARS" "CLAWD_DIRECTEXEC_SAMPLER" || return $?
  if [ "$CK_SANDBOX_MODE" = 1 ]; then
    SAMPLER="$CLAWD_DIRECTEXEC_SAMPLER"
    LIMIT_MS="$CLAWD_DIRECTEXEC_LIMIT_MS"
    MAX_GAP_MS="$CLAWD_DIRECTEXEC_MAX_GAP_MS"
    ck_is_uint "$LIMIT_MS" || { ck_warn "direct-exec-check: refused: CLAWD_DIRECTEXEC_LIMIT_MS is not a whole number"; return 64; }
    ck_is_uint "$MAX_GAP_MS" || { ck_warn "direct-exec-check: refused: CLAWD_DIRECTEXEC_MAX_GAP_MS is not a whole number"; return 64; }
    EVID="$CK_SANDBOX/evidence"
  else
    SAMPLER="$(ck_find_tool clawd-attended-sampler)"
    LIMIT_MS=1000
    MAX_GAP_MS=30
    EVID="$REPO/.evidence"
  fi
  ROOT="$HOME/Library/Application Support/clawd-pet"
  MANIFEST="$ROOT/manifest"
  AGENT="$ROOT/bin/clawd-pet-agent"
  return 0
}

sha_of() { /usr/bin/shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1; }

# Makes the copy outside the install and proves it identical. Returns 1 (with a NOT RUN or FAIL recorded) when the run cannot go on.
make_copy() {
  local dir="$WORK/copy"
  case "$dir" in
    "$ROOT"|"$ROOT"/*) notrun direct-exec-failed-to-start "the scratch directory $dir lies inside the install; nothing was run"; return 1 ;;
  esac
  mkdir -p "$dir" || { notrun direct-exec-failed-to-start "cannot create $dir"; return 1; }
  COPY="$dir/clawd-pet-agent"
  INSTALLED_SHA0="$(sha_of "$AGENT")"
  if ! cp "$AGENT" "$COPY" || ! chmod 755 "$COPY"; then notrun direct-exec-failed-to-start "cannot copy the installed agent to $COPY"; return 1; fi
  COPY_SHA="$(sha_of "$COPY")"
  if [ -z "$COPY_SHA" ] || [ "$COPY_SHA" != "$INSTALLED_SHA0" ]; then fail direct-exec-copy-differs "the copy is not byte-identical to the installed agent (sha256 $COPY_SHA against $INSTALLED_SHA0); nothing was run"; return 1; fi
  return 0
}

# Makes the copy's own HOME and proves it is isolated. Sets COPY_HOME (the physical path). Returns 1 (with a NOT RUN recorded) unless:
# the directory is new (it is made here, empty), a real directory (not a symbolic link), an absolute physical path that is not the real
# HOME, not inside the install and not containing it. The agent writes under $HOME/Library/Application Support/clawd-pet, so a directory
# like that cannot reach the real data directory. The real HOME is $HOME of this script, the real install is ROOT.
make_home() {
  local dir="$WORK/home" phys real_home real_root
  COPY_HOME=""
  if ! mkdir "$dir" 2>/dev/null; then notrun direct-exec-failed-to-start "cannot make the scratch HOME $dir (it must not exist yet); the copy was not run"; return 1; fi
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then notrun direct-exec-failed-to-start "the scratch HOME $dir is not a plain directory; the copy was not run"; return 1; fi
  if ! phys="$(cd -P "$dir" 2>/dev/null && pwd -P)"; then notrun direct-exec-failed-to-start "cannot resolve the scratch HOME $dir; the copy was not run"; return 1; fi
  real_home="$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || real_home=""
  real_root="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || real_root="$ROOT"
  case "$phys" in
    /*) ;;
    *) notrun direct-exec-failed-to-start "the scratch HOME $phys is not an absolute path; the copy was not run"; return 1 ;;
  esac
  if [ -n "$(/usr/bin/find "$phys" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    notrun direct-exec-failed-to-start "the scratch HOME $phys is not empty; the copy was not run"; return 1
  fi
  if [ -n "$real_home" ] && [ "$phys" = "$real_home" ]; then
    notrun direct-exec-failed-to-start "the scratch HOME $phys is the real HOME; the copy was not run"; return 1
  fi
  case "$phys/" in
    "$real_root"/*) notrun direct-exec-failed-to-start "the scratch HOME $phys lies inside the install $real_root; the copy was not run"; return 1 ;;
  esac
  case "$real_root/" in
    "$phys"/*) notrun direct-exec-failed-to-start "the install $real_root lies inside the scratch HOME $phys, so it is reachable through HOME; the copy was not run"; return 1 ;;
  esac
  COPY_HOME="$phys"
  return 0
}

# Runs the copy under the observer and reads its log.
run_and_observe() {
  local log="$WORK/observe.log" line
  : > "$log"
  /usr/bin/perl "$OBSERVER" "$SAMPLER" "$LIMIT_MS" "$COPY" "$log" "$COPY_HOME" &
  OBSERVER_PID=$!
  wait "$OBSERVER_PID"; local rc=$?
  OBSERVER_PID=""
  COPY_HOME_FILES="$(/usr/bin/find "$COPY_HOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$rc" -ne 0 ] || ! grep -q '^EXIT ' "$log"; then notrun direct-exec-failed-to-start "the observer did not run the copy to its end (exit $rc)"; return 1; fi
  line="$(/usr/bin/awk '
    $1 == "EXEC" { pid = $3 }
    $1 == "SNAP" {
      n++; start[n] = $2; end[n] = $3
      dur = $3 - $2; if (n == 1 || dur < minr) minr = dur; if (dur > maxr) maxr = dur
      if ($4 != 1) failed++
      windows += $5
      if ($4 == 1 && $6 == 1) inlife++
    }
    $1 == "LIMIT" { limit = 1 }
    $1 == "EXIT" { exit_ms = $2; status = $3 }
    END {
      # wait(2) gives 256 * exit code + terminating signal: report the exit code, or 128 + the signal when the program was killed.
      code = (status < 0) ? 255 : ((status % 256 == 0) ? int(status / 256) : 128 + (status % 256) % 128)
      # the latest the first read can have looked is its end (a read shows one instant between its start and its end); two looks are at most (next end - this start) apart
      maxgap = (n > 0) ? end[1] : 0
      for (i = 2; i <= n; i++) { g = end[i] - start[i - 1]; if (g > maxgap) maxgap = g }
      printf "%d %d %d %d %d %d %d %d %d %d %d %d\n", pid, code, exit_ms, n, inlife + 0, failed + 0, maxgap, windows + 0, limit + 0, (n > 0) ? end[n] : 0, minr + 0, maxr + 0
    }' "$log")"
  set -- $line
  D_PID="$1"; D_EXIT="$2"; D_MS="$3"; D_SNAPS="$4"; D_INLIFE="$5"; D_FAILED="$6"; D_GAP="$7"; D_WINDOWS="$8"; D_LIMIT_HIT="$9"; D_LIFE_MS="${10}"; D_READ_MIN="${11}"; D_READ_MAX="${12}"
  D_RAN=1
  return 0
}

decide() {
  [ "$D_RAN" = 1 ] || return 0
  if [ "$D_LIMIT_HIT" = 1 ]; then
    fail direct-exec-too-slow "the copy was still running at the limit ($LIMIT_MS ms); the script stopped it"
  elif [ "$D_EXIT" != 0 ]; then
    fail direct-exec-exit-nonzero "the copy exited with status $D_EXIT (0 expected)"
  elif [ "$D_MS" -gt "$LIMIT_MS" ]; then
    fail direct-exec-too-slow "the copy took $D_MS ms (limit $LIMIT_MS ms)"
  fi
  if [ "$D_WINDOWS" -gt 0 ]; then fail direct-exec-window "a window owned by the copy's pid was in the window list ($D_WINDOWS sighting(s))"; fi
  # "No window" is a claim about the whole life of the program. It stands only on reads that cover it.
  if [ "$D_FAILED" -gt 0 ]; then notrun window-lister-failed "$D_FAILED of $D_SNAPS window-list read(s) failed while the copy ran"; fi
  # The reasons say WHY a run could not observe: a read of the window list that takes longer than the copy lives (or longer than the
  # allowed gap) leaves the step NOT RUN whatever the copy does, and that is a fact about the instrument, not about the install.
  if [ "$D_INLIFE" -lt 1 ]; then
    notrun direct-exec-not-observed "no window-list read fitted inside the copy's life (it was reaped $D_MS ms after the fork; $D_SNAPS read(s), the shortest took $D_READ_MIN ms, none begun and finished while it was alive): 'no window' was never observed$([ "$D_FAILED" -eq 0 ] && [ "$D_SNAPS" -ge 1 ] && printf '; the copy had exited before its first read was finished, so a read takes longer than the copy lives, and this instrument cannot see a program that short')"
  fi
  if [ "$D_GAP" -gt "$MAX_GAP_MS" ]; then
    notrun direct-exec-observation-gap "the longest stretch no read can have seen, from the exec on and counting the time inside the reads, was $D_GAP ms (limit $MAX_GAP_MS ms): a window could have opened and closed unseen$([ "$D_READ_MIN" -gt "$MAX_GAP_MS" ] && printf '; the shortest read took %s ms, longer than the allowed gap, so this limit can never be met')"
  fi
}

write_evidence() {
  local commit
  commit="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "check": "direct-exec-check",\n'
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
    printf '  "copy": {"path": %s, "sha256": %s, "installed_sha256_before": %s, "installed_sha256_after": %s, "scratch_home": %s, "files_the_copy_left_in_the_scratch_home": %s},\n' \
      "$(jstr "$COPY")" "$(jstr "$COPY_SHA")" "$(jstr "$INSTALLED_SHA0")" "$(jstr "$INSTALLED_SHA1")" "$(jstr "$COPY_HOME")" "$(jnum "$COPY_HOME_FILES")"
    printf '  "direct_exec": {"ran": %s, "pid": %s, "exit_status": %s, "elapsed_ms": %s, "limit_ms": %s, "limit_hit": %s,\n' \
      "$(jbool "$D_RAN")" "$(jnum "$D_PID")" "$(jnum "$D_EXIT")" "$(jnum "$D_MS")" "$(jnum "${LIMIT_MS:-}")" "$(jbool "$D_LIMIT_HIT")"
    printf '                  "window_list_reads": %s, "reads_inside_the_life": %s, "reads_failed": %s, "longest_gap_ms": %s, "max_gap_allowed_ms": %s, "windows_seen": %s,\n' \
      "$(jnum "$D_SNAPS")" "$(jnum "$D_INLIFE")" "$(jnum "$D_FAILED")" "$(jnum "$D_GAP")" "$(jnum "${MAX_GAP_MS:-}")" "$(jnum "$D_WINDOWS")"
    printf '                  "shortest_read_ms": %s, "longest_read_ms": %s}\n' "$(jnum "$D_READ_MIN")" "$(jnum "$D_READ_MAX")"
    printf '}\n'
  } | ck_publish "$EVIDENCE_FILE"
}

finish() {
  trap '' INT TERM HUP
  if [ -n "$OBSERVER_PID" ]; then
    ck_kill_job "$OBSERVER_PID"
    wait "$OBSERVER_PID" 2>/dev/null
  fi
  [ -z "$COPY" ] || INSTALLED_SHA1="$(sha_of "$AGENT")"
  if [ -n "$INSTALLED_SHA0" ] && [ "$INSTALLED_SHA0" != "$INSTALLED_SHA1" ]; then fail installed-agent-changed "the installed agent changed while the check ran (sha256 $INSTALLED_SHA0 -> $INSTALLED_SHA1)"; fi
  decide
  if [ -n "$FAILS" ]; then VERDICT="FAIL"; EXIT_CODE=1
  elif [ -n "$NOTRUNS" ]; then VERDICT="NOT RUN"; EXIT_CODE=3
  else VERDICT="PASS"; EXIT_CODE=0; fi
  if ! write_evidence; then ck_warn "direct-exec-check: could not write the evidence file $EVIDENCE_FILE"; fi
  ck_say "direct-exec-check: scope: $SCOPE"
  case "$VERDICT" in
    PASS) ck_say "direct-exec-check: PASS (the copy exited ${D_EXIT} in ${D_MS} ms; $D_INLIFE of $D_SNAPS window-list reads lay inside its life, longest gap ${D_GAP} ms, no window) -> $EVIDENCE_FILE" ;;
    FAIL) ck_say "direct-exec-check: FAIL ($(printf '%s\n' "$FAILS" | head -n 1)) -> $EVIDENCE_FILE" ;;
    *) ck_say "direct-exec-check: NOT RUN ($(printf '%s\n' "$NOTRUNS" | head -n 1)) -> $EVIDENCE_FILE" ;;
  esac
  exit "$EXIT_CODE"
}

on_signal() {
  notrun interrupted "the check was interrupted before it finished"
  finish
}

main() {
  local real=0 gate=0 arg
  for arg in "$@"; do
    case "$arg" in
      --real) real=1 ;;
      --run-a-copy) gate=1 ;;
      *) usage; return 64 ;;
    esac
  done
  if [ "$gate" != 1 ]; then
    ck_warn "direct-exec-check: refused (64): this step runs a copy of the installed agent; it needs the explicit flag --run-a-copy. Nothing was read or run."
    ck_warn "direct-exec-check: with a regressed launch guard the copy shows a window: run it only while the user watches the screen."
    return 64
  fi
  if [ -z "${CLAWD_DIRECTEXEC_SANDBOX:-}" ]; then
    if [ "$real" != 1 ]; then
      ck_warn "direct-exec-check: refused (64): real mode needs the explicit flag --real. Nothing was read or run."
      return 64
    fi
  elif [ "$real" = 1 ]; then
    ck_warn "direct-exec-check: refused (64): --real cannot be combined with a sandbox run. Nothing was run."
    return 64
  fi
  resolve_mode || return $?
  START_EPOCH="$(date +%s)"
  mkdir -p "$EVID" || { ck_warn "direct-exec-check: cannot create $EVID"; return 64; }
  EVIDENCE_FILE="$EVID/direct-exec-check-$START_EPOCH-$$.json"
  WORK="$EVID/direct-exec-check-work/$START_EPOCH-$$"
  mkdir -p "$WORK" || { ck_warn "direct-exec-check: cannot create $WORK"; return 64; }
  trap on_signal INT TERM HUP
  if [ ! -f "$MANIFEST" ]; then
    notrun not-installed "no manifest: the user installs the pet first"
  elif [ ! -f "$AGENT" ] || [ -L "$AGENT" ] || [ ! -x "$AGENT" ]; then
    notrun direct-exec-failed-to-start "$AGENT is not an executable regular file"
  elif [ ! -x "$SAMPLER" ]; then
    notrun window-lister-failed "$SAMPLER is not built: swift build -c release"
  elif make_copy && make_home; then
    run_and_observe || true
  fi
  finish
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
