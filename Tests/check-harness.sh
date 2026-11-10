# check-harness.sh: assertion and job-pool helpers shared by Tests/attended-check.test.sh and Tests/post-install-check.test.sh.
# Sourced, never run. The sourcing test sets RESDIR (a directory for result files) and JOBS first. Every scenario runs in a background
# job with its own result file RES; check appends "PASS: name" or "FAIL: name" to it, and tally counts them all at the end.

check() { # name, then a command whose success is the check
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $name" >> "$RES"; else echo "FAIL: $name" >> "$RES"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
equals() { [ "$1" = "$2" ]; }
num_eq() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }
wait_until() { # tries, then a command (a poll of a real condition with a generous bound; the test fails when the bound is hit)
  local tries="$1" n=0; shift
  while [ "$n" -lt "$tries" ]; do "$@" && return 0; sleep 0.05; n=$((n + 1)); done
  return 1
}

JOB_PIDS=()
spawn() { # scenario function name, then its arguments: runs in the background with its own result file
  local name="$1"; shift
  ( RES="$RESDIR/$name$*"; : > "$RES"; "$name" "$@" ) &
  JOB_PIDS+=("$!")
  if [ "${#JOB_PIDS[@]}" -ge "$JOBS" ]; then wait "${JOB_PIDS[0]}"; JOB_PIDS=("${JOB_PIDS[@]:1}"); fi
}
drain() { local p; for p in ${JOB_PIDS[@]+"${JOB_PIDS[@]}"}; do wait "$p"; done; JOB_PIDS=(); }

# CLAWD_TEST_ONLY=<regex> runs only the scenarios whose function name matches (development and mutation runs).
wanted() { [ -z "${CLAWD_TEST_ONLY:-}" ] || printf '%s' "$1" | grep -Eq -- "$CLAWD_TEST_ONLY"; }

# lint_no_real_flag FILE: fails when a non-comment line runs a check script with the real-mode flag and is not a stubbed sandbox run.
lint_no_real_flag() {
  ! grep -vE '^[[:space:]]*#' "$1" | grep -v -e '_SANDBOX=' -e 'sandbox_env' | grep -E '(attended-check|post-install-check|pre-install-snapshot|direct-exec-check|post-install-settings-step)(\.sh)?[^|;&]*[[:space:]]--[r]eal([[:space:]]|$)|(\$SCRIPT|\$\{SCRIPT\})[^|;&]*[[:space:]]--[r]eal([[:space:]]|$)' | grep -qv '^$'
}

tally() { # prints the failing assertions and the final line "<name>: pass=N fail=M"; the exit status is 0 only without failures
  local pass fail
  pass=$(cat "$RESDIR"/* | grep -c '^PASS: ')
  fail=$(cat "$RESDIR"/* | grep -c '^FAIL: ')
  cat "$RESDIR"/* | grep '^FAIL: ' | sort | uniq -c | sed 's/^ *//; s/^1 //'
  echo "$1: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}
