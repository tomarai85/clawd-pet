#!/bin/bash
# Install and uninstall interrupt tests (spec section 6 item 6; round brief r4 item A). Run by Tests/cli.test.sh, or alone.
# Everything happens in fake HOME directories under .build/interrupt-test with a stub launchctl; the CLI under test is a copy of
# bin/clawd-pet inside a small fake repo. The only things signalled are the CLI processes and the shim children this script starts,
# each by a pid this script recorded itself. Nothing is looked up by name, nothing touches the real HOME, nothing opens a window.
#
# Sections: structure of an install (op log), install cut before every operation and mid-copy, uninstall cut before every operation
# of every interrupted state, a delayed orphan writer, the deliberate states injected by hand, install refusals, signal traps, and
# `clawd-pet start` racing an uninstall at three chosen points.
# The last line is "RESULT pass=N fail=M".
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BASH="${CLAWD_TEST_BASH:-bash}"
STUBS="$REPO/Tests/stubs"
SHIM_SRC="$REPO/Tests/interrupt-shims/op-shim"
SHIM_DIR_SRC="$REPO/Tests/interrupt-shims"
JOBS="${CLAWD_TEST_JOBS:-6}"
unset CLAWD_OWN_PIDS_CHECKER STUB_OWN_LOG STUB_OPEN_LOG 2>/dev/null

REAL_AGENT="${CLAWD_TEST_REAL_AGENT:-}"
if [ -z "$REAL_AGENT" ]; then
  for candidate in "$REPO/.build/release/clawd-pet-agent" "$REPO/.build/debug/clawd-pet-agent"; do
    if [ -x "$candidate" ]; then REAL_AGENT="$candidate"; break; fi
  done
fi
[ -x "$REAL_AGENT" ] || { echo "FAIL: no built agent for --own-pids (swift build)"; echo "RESULT pass=0 fail=1"; exit 2; }

STAGE="$REPO/.build/interrupt-test/$(date +%s)-$$"
mkdir -p "$STAGE" || { echo "FAIL: cannot create $STAGE"; echo "RESULT pass=0 fail=1"; exit 2; }
# The stub launchctl records the interpreter of the CLI process that called it; the checks at the end read this record.
export STUB_SHELL_LOG="$STAGE/cli-shell.calls"; : > "$STUB_SHELL_LOG"
pass=0; fail=0
check() { # name, then a command whose success is the check
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
alive() { kill -0 "$1" 2>/dev/null; }

tracked=()
cleanup() { local p; for p in ${tracked[@]+"${tracked[@]}"}; do if alive "$p"; then kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; fi; done; }
trap cleanup EXIT

# ---- the fake repo and the shim directory --------------------------------------------------------------------------------------
MINI="$STAGE/repo"
mkdir -p "$MINI/bin" "$MINI/launchd" "$MINI/launcher" "$MINI/art/frames" "$MINI/art/motions/M1" "$MINI/art/looks/L1" "$MINI/build" "$MINI/.build/release" || exit 2
cp "$REPO/bin/clawd-pet" "$MINI/bin/clawd-pet" && chmod 755 "$MINI/bin/clawd-pet"
cp "$REPO/launchd/com.tomtim.clawd-pet.plist.in" "$MINI/launchd/"
cp "$REPO/launcher/clawd-pet-launch" "$REPO/launcher/clawd-pet-launch.sha256" "$MINI/launcher/"
: > "$MINI/Package.swift"
# A schema-2 shaped atlas: the install copies every file it names, nested ones included, so every cut below also crosses the
# creation of art/motions/M1 and art/looks/L1 and their copies.
printf '%s\n' '{"schema":2,"motions":[{"id":"M1","frames":["motions/M1/000.png","motions/M1/001.png"]}],"looks":[{"id":"L1","layers":[{"png":"looks/L1/layer.png"}]}]}' > "$MINI/art/clawd-atlas.json"
printf '{}\n' > "$MINI/art/claude-code-elements.json"
for n in 1 2 3; do printf 'frame %s\n' "$n" > "$MINI/art/frames/f$n.png"; done
for f in motions/M1/000.png motions/M1/001.png looks/L1/layer.png; do printf 'picture %s\n' "$f" > "$MINI/art/$f"; done
cp "$STUBS/enumerator-installed" "$MINI/build/clawd-pet-agent"
cp "$STUBS/enumerator-repo" "$MINI/.build/release/clawd-pet-agent"
SHIMS="$STAGE/shims"
mkdir -p "$SHIMS" || exit 2
# The PATH shims are symlinks to a compiled trampoline that runs op-shim through /bin/sh (Tests/interrupt-shims/op-shim-trampoline.c:
# a #! shim exec'd by the bash CLI leaks kernel memory on macOS 26). /usr/bin/cc by path: run from cli.test.sh, PATH starts with
# Tests/stubs, whose cc must never run (install never builds) and exits 99.
/usr/bin/cc -O1 -DOPSHIM_SCRIPT="\"$SHIM_SRC\"" -o "$SHIMS/op-shim-trampoline" "$REPO/Tests/interrupt-shims/op-shim-trampoline.c" || { echo "cannot compile the op-shim trampoline"; exit 2; }
for c in mkdir cp mv chmod sed rm rmdir; do ln -s "$SHIMS/op-shim-trampoline" "$SHIMS/$c"; done

# A second fake repo without the repo build: uninstall run from it has no enumerator once the installed agent is gone.
MINI2="$STAGE/repo-nobuild"
mkdir -p "$MINI2/bin" || exit 2
cp "$REPO/bin/clawd-pet" "$MINI2/bin/clawd-pet" && chmod 755 "$MINI2/bin/clawd-pet"
: > "$MINI2/Package.swift"

# The launchctl stub and the build the CLI under test installs from. Section 9 switches them for the start-versus-uninstall race.
STUB_LAUNCHCTL="$STUBS/launchctl"; BUILD_UNDER_TEST="$MINI/build"

# ---- helpers -------------------------------------------------------------------------------------------------------------------
root_of() { printf '%s' "$1/Library/Application Support/clawd-pet"; }
marker_of() { printf '%s' "$1/Library/Application Support/clawd-pet.installing"; }

new_home() { # dir [none|logs|emptyroot]  -> H
  H="$1"
  mkdir -p "$H/bin" "$H/Library/LaunchAgents" "$H/Library/Application Support/OtherApp" || return 1
  printf 'keep\n' > "$H/bin/other-tool"
  printf 'keep\n' > "$H/Library/LaunchAgents/other.plist"
  printf 'keep\n' > "$H/Library/Application Support/OtherApp/data"
  case "${2:-none}" in
    emptyroot) mkdir "$(root_of "$H")" ;;
    logs) mkdir "$(root_of "$H")"; printf 'old log\n' > "$(root_of "$H")/agent.log"; printf 'older log\n' > "$(root_of "$H")/agent.log.1" ;;
  esac
}

# The tree of a fake HOME: every path, then a checksum of every regular file (so changed contents show too).
tree() { (cd "$1" && LC_ALL=C find . -print | LC_ALL=C sort && LC_ALL=C find . -type f -exec /usr/bin/cksum {} + | LC_ALL=C sort -k3); }

cli() { # home, then the CLI arguments -> CLI_OUT, CLI_RC
  local h="$1"; shift
  CLI_OUT="$(HOME="$h" CLAWD_LAUNCHCTL="$STUB_LAUNCHCTL" STUB_LOG="$h.stub.log" STUB_STATE="$h.stub.loaded" STUB_ENUM_LOG="$h.enum.log" STUB_ROOT="$(root_of "$h")" \
    STUB_AGENT_EXEC="$(root_of "$h")/bin/clawd-pet-agent" STUB_AGENT_PIDFILE="$h.agent.pid" \
    CLAWD_TEST_REAL_AGENT="$REAL_AGENT" CLAWD_BUILD_DIR="$BUILD_UNDER_TEST" "$CLI_BASH" "${CLI_UNDER_TEST:-$MINI/bin/clawd-pet}" "$@" 2>&1)"
  CLI_RC=$?
}

uninstall_retry() { # home: one retry only when the live-writer check named a process that was still on its way out
  cli "$1" uninstall
  if [ "$CLI_RC" -ne 0 ] && contains "$CLI_OUT" "still using the installation"; then
    # Wait for the process(es) the refusal named to be gone (a poll of the real condition, generous bound), then retry once.
    for p in $(printf '%s\n' "$CLI_OUT" | sed -n 's/^  pid \([0-9][0-9]*\):.*/\1/p'); do wait_until 1200 is_gone "$p"; done
    cli "$1" uninstall
  fi
}

# Starts the CLI under the shim. The CLI process's own pid is written to <home>.<tag>.pid by a wrapper that then execs the CLI, so the
# shim knows exactly which process it may signal. To be called inside ( ) : it execs.
launch() { # home tag kill_at mode, then the CLI arguments
  local h="$1" tag="$2" at="$3" mode="$4"; shift 4
  local base="$h.$tag"
  export HOME="$h" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$STUB_LAUNCHCTL" STUB_LOG="$h.stub.log" STUB_STATE="$h.stub.loaded" STUB_ENUM_LOG="$h.enum.log" STUB_ROOT="$(root_of "$h")"
  export STUB_AGENT_EXEC="$(root_of "$h")/bin/clawd-pet-agent" STUB_AGENT_PIDFILE="$h.agent.pid"
  export CLAWD_TEST_REAL_AGENT="$REAL_AGENT" CLAWD_BUILD_DIR="$BUILD_UNDER_TEST"
  export OPSHIM_COUNT="$base.count" OPSHIM_LOG="$base.ops" OPSHIM_KILL_AT="$at" OPSHIM_KILL_MODE="$mode" OPSHIM_PIDFILE="$base.pid" OPSHIM_STOP_PIDFILE="$base.stop"
  if [ -n "${WAIT_AT:-}" ]; then export OPSHIM_WAIT_AT="$WAIT_AT" OPSHIM_WAIT_READY="$base.wait.ready" OPSHIM_WAIT_RELEASE="$base.wait.release" OPSHIM_WAIT_MAX="${WAIT_MAX:-120}"; fi
  if [ -n "${HOOK_AT:-}" ]; then
    export OPSHIM_HOOK_AT="$HOOK_AT" OPSHIM_HOOK_WHEN="${HOOK_WHEN:-before}" OPSHIM_HOOK="$SHIM_DIR_SRC/start-hook"
    export OPSHIM_HOOK_BASH="$CLI_BASH" OPSHIM_HOOK_CLI="${CLI_UNDER_TEST:-$MINI/bin/clawd-pet}" OPSHIM_HOOK_OUT="$base.hook.out" OPSHIM_HOOK_RC="$base.hook.rc"
  fi
  if [ -n "${LAUNCH_PERL:-}" ]; then
    # A background job of a non-interactive shell ignores SIGINT; perl puts the default back before the exec so the CLI's INT trap can fire.
    exec /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$CLI_BASH" -c 'echo $$ > "$1"; shift; exec "$@"' sh "$base.pid" "$CLI_BASH" "${CLI_UNDER_TEST:-$MINI/bin/clawd-pet}" "$@"
  fi
  exec "$CLI_BASH" -c 'echo $$ > "$1"; shift; exec "$@"' sh "$base.pid" "$CLI_BASH" "${CLI_UNDER_TEST:-$MINI/bin/clawd-pet}" "$@"
}
reset_run() { local base="$1.$2"; echo 0 > "$base.count"; : > "$base.ops"; rm -f -- "$base.pid" "$base.stop" "$base.wait.ready" "$base.wait.release"; }

run_shimmed() { # home kill_at mode tag, then the CLI arguments -> SH_RC; ops in <home>.<tag>.ops, call count in <home>.<tag>.count
  local h="$1" at="$2" mode="$3" tag="$4"; shift 4
  reset_run "$h" "$tag"
  { ( launch "$h" "$tag" "$at" "$mode" "$@" ) > "$h.$tag.out" 2>&1; } 2>/dev/null
  SH_RC=$?
}
op_count() { cat "$1.$2.count"; }
# The number of the call whose text ("<command> <arguments>") is exactly $3, in the ops log of <home>.<tag>.
op_no() { /usr/bin/awk -v s="$3" '{ rest = $0; sub(/^[0-9]+ /, "", rest); if (rest == s) { print $1; exit } }' "$1.$2.ops"; }
cp_ops() { /usr/bin/awk '$2 == "cp" { print $1 }' "$1.$2.ops"; }
# mkdir calls whose target is not inside $3, and cp calls that copy straight to $3
ops_mkdir_outside() { /usr/bin/awk -v root="$3" '$2 == "mkdir" { p = $0; sub(/^[0-9]+ mkdir /, "", p); if (index(p, root) != 1) print p }' "$1.$2.ops"; }
ops_cp_to() { /usr/bin/awk -v t="$3" '$2 == "cp" && length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t { print }' "$1.$2.ops"; }

wait_until() { # tries, then a command
  local tries="$1" n=0; shift
  while [ "$n" -lt "$tries" ]; do "$@" && return 0; sleep 0.05; n=$((n + 1)); done
  return 1
}
file_nonempty() { [ -s "$1" ]; }
file_exists() { [ -e "$1" ]; }
is_stopped() { [ "$(/bin/ps -o stat= -p "$1" 2>/dev/null | cut -c1)" = T ]; }
is_gone() { ! alive "$1"; }

# ---- job pool for the matrices -------------------------------------------------------------------------------------------------
JOB_PIDS=()
spawn() {
  "$@" &
  JOB_PIDS+=("$!")
  if [ "${#JOB_PIDS[@]}" -ge "$JOBS" ]; then wait "${JOB_PIDS[0]}"; JOB_PIDS=("${JOB_PIDS[@]:1}"); fi
}
drain() { local p; for p in ${JOB_PIDS[@]+"${JOB_PIDS[@]}"}; do wait "$p"; done; JOB_PIDS=(); }
bad() { echo "FAIL: $*" >> "$RES"; }
finish_job() { echo done > "$RES.done"; }
tally() { # name, dir, expected number of jobs
  local name="$1" dir="$2" expected="$3" done_n failing=0 f
  done_n=$(ls "$dir" | grep -c '\.done$')
  for f in "$dir"/res-*; do
    case "$f" in *.done) continue ;; esac
    [ -s "$f" ] || continue
    failing=$((failing + 1)); cat "$f"
  done
  local missing=$((expected - done_n))
  [ "$missing" -ge 0 ] || missing=0
  if [ "$missing" -gt 0 ]; then echo "FAIL: $name: $missing job(s) did not finish"; fi
  pass=$((pass + expected - failing - missing)); fail=$((fail + failing + missing))
  echo "interrupt: $name: $expected cases, $((failing + missing)) failing"
}

# ---- 1. the structure of an install: what it does, in what order, in which places -----------------------------------------------
new_home "$STAGE/count-none" none; HN="$H"; RN="$(root_of "$HN")"; MN="$(marker_of "$HN")"
run_shimmed "$HN" 0 before cnt install
check "counting install exits 0" test "$SH_RC" -eq 0
T_NONE="$(op_count "$HN" cnt)"
check "install counting run saw operations" test "${T_NONE:-0}" -ge 15
check "manifest ends with end and starts with schema 1" bash -c "[ \"\$(sed -n 1p '$RN/manifest')\" = 'schema 1' ] && [ \"\$(tail -n 1 '$RN/manifest')\" = end ]"
check "manifest lists the marker as a file" grep -qxF "file $MN" "$RN/manifest"
check "manifest lists the .partial names of the agent, the CLI and the launcher" bash -c "grep -qxF 'file $RN/bin/clawd-pet-agent.partial' '$RN/manifest' && grep -qxF 'file $HN/bin/clawd-pet.partial' '$RN/manifest' && grep -qxF 'file $RN/bin/clawd-pet-launch.partial' '$RN/manifest'"
check "manifest lists the launcher, control.lock and control.json.partial" bash -c "grep -qxF 'file $RN/bin/clawd-pet-launch' '$RN/manifest' && grep -qxF 'file $RN/control.lock' '$RN/manifest' && grep -qxF 'file $RN/control.json.partial' '$RN/manifest'"
check "manifest lists \$ROOT first among the directories (created by this install)" bash -c "[ \"\$(grep -m1 '^dir ' '$RN/manifest')\" = 'dir $RN' ]"
check "marker says root-created yes" test "$(cat "$MN")" = "root-created yes"
check "install leaves no .partial behind" bash -c "! find '$HN' -name '*.partial' | grep -q ."
# The order: marker, mkdir ROOT, manifest rename, then the copies.
n_marker="$(op_no "$HN" cnt "mv $MN.partial $MN")"; n_root="$(op_no "$HN" cnt "mkdir $RN")"; n_manifest="$(op_no "$HN" cnt "mv $RN/manifest.partial $RN/manifest")"
n_agent_cp="$(op_no "$HN" cnt "cp $MINI/build/clawd-pet-agent $RN/bin/clawd-pet-agent.partial")"; n_agent_mv="$(op_no "$HN" cnt "mv $RN/bin/clawd-pet-agent.partial $RN/bin/clawd-pet-agent")"
n_cli_cp="$(op_no "$HN" cnt "cp $MINI/bin/clawd-pet $HN/bin/clawd-pet.partial")"; n_cli_mv="$(op_no "$HN" cnt "mv $HN/bin/clawd-pet.partial $HN/bin/clawd-pet")"
n_launch_cp="$(op_no "$HN" cnt "cp $MINI/launcher/clawd-pet-launch $RN/bin/clawd-pet-launch.partial")"; n_launch_mv="$(op_no "$HN" cnt "mv $RN/bin/clawd-pet-launch.partial $RN/bin/clawd-pet-launch")"
n_plist="$(op_no "$HN" cnt "sed s|@INSTALL_ROOT@|$RN|g $MINI/launchd/com.tomtim.clawd-pet.plist.in")"
check "install writes the marker first, then creates \$ROOT, then publishes the manifest" bash -c "[ -n '$n_marker' ] && [ -n '$n_root' ] && [ -n '$n_manifest' ] && [ '$n_marker' -lt '$n_root' ] && [ '$n_root' -lt '$n_manifest' ]"
check "install publishes the manifest by renaming manifest.partial (a manifest is absent or complete)" test -n "$n_manifest"
check "install copies the agent through agent.partial and renames it" bash -c "[ -n '$n_agent_cp' ] && [ -n '$n_agent_mv' ] && [ '$n_agent_cp' -lt '$n_agent_mv' ] && [ '$n_manifest' -lt '$n_agent_cp' ]"
check "install copies the CLI through clawd-pet.partial and renames it" bash -c "[ -n '$n_cli_cp' ] && [ -n '$n_cli_mv' ] && [ '$n_cli_cp' -lt '$n_cli_mv' ]"
check "install copies the launcher through clawd-pet-launch.partial and renames it" bash -c "[ -n '$n_launch_cp' ] && [ -n '$n_launch_mv' ] && [ '$n_launch_cp' -lt '$n_launch_mv' ] && [ '$n_manifest' -lt '$n_launch_cp' ]"
check "the launcher is never copied straight to its final name" test -z "$(ops_cp_to "$HN" cnt "$RN/bin/clawd-pet-launch")"
check "install runs no compiler: no cc, clang or swiftc among the operations it performs" bash -c "! grep -Eq ' (cc|clang|swiftc|codesign) ' '$HN.cnt.ops'"
check "the agent is never copied straight to its final name" test -z "$(ops_cp_to "$HN" cnt "$RN/bin/clawd-pet-agent")"
check "the CLI is never copied straight to its final name" test -z "$(ops_cp_to "$HN" cnt "$HN/bin/clawd-pet")"
check "the plist is the last operation" bash -c "[ -n '$n_plist' ] && [ '$n_plist' -eq '$T_NONE' ]"
check "every directory install creates is inside \$ROOT (it creates nothing outside)" test -z "$(ops_mkdir_outside "$HN" cnt "$RN")"
n_bin="$(op_no "$HN" cnt "mkdir $RN/bin")"
check "install created the directories under \$ROOT only after the manifest" bash -c "[ -n '$n_bin' ] && [ '$n_bin' -gt '$n_manifest' ]"
# The focus-violation ledger: listed as an ordinary file line, created through its .partial strictly after the manifest and before the plist.
n_ledger_mv="$(op_no "$HN" cnt "mv $RN/focus-violations.log.partial $RN/focus-violations.log")"
check "ledger: the manifest lists it and its .partial name as ordinary file lines (a line kind every build's uninstall knows)" bash -c "grep -qxF 'file $RN/focus-violations.log' '$RN/manifest' && grep -qxF 'file $RN/focus-violations.log.partial' '$RN/manifest'"
check "ledger: install renames the ledger into place after the manifest is published and before the plist is written" bash -c "[ -n '$n_ledger_mv' ] && [ '$n_manifest' -lt '$n_ledger_mv' ] && [ '$n_ledger_mv' -lt '$n_plist' ]"
check "ledger: the ledger holds the one header line and has mode 600" bash -c "[ \$(grep -c '' '$RN/focus-violations.log') = 1 ] && grep -qE '^LEDGER 1 born=[0-9]+ how=install\$' '$RN/focus-violations.log' && [ \"\$(/usr/bin/stat -f %Lp '$RN/focus-violations.log')\" = 600 ]"
cli "$HN" uninstall
check "the counting install is removed by one uninstall" test "$CLI_RC" -eq 0
# A cut between the manifest and the ledger (before the rename that gives the ledger its name) leaves a manifest that names a file which is
# absent, and a header in the .partial: one uninstall clears it. A cut right after the ledger exists is cleared the same way.
for at_mode in "$n_ledger_mv before" "$n_ledger_mv after"; do
  set -- $at_mode
  new_home "$STAGE/ledger-cut-$2" none; h="$H"; r="$(root_of "$h")"; b="$(tree "$h")"
  run_shimmed "$h" "$1" "$2" ins install
  check "ledger: install cut $2 the ledger's rename: the installer died" test "$SH_RC" -eq 137
  if [ "$2" = before ]; then
    check "ledger: ... the manifest is published, the ledger is absent and its .partial holds the whole header" bash -c "[ -f '$r/manifest' ] && [ ! -e '$r/focus-violations.log' ] && grep -qE '^LEDGER 1 born=[0-9]+ how=install\$' '$r/focus-violations.log.partial'"
  else
    check "ledger: ... the ledger exists and the plist does not" bash -c "[ -f '$r/focus-violations.log' ] && [ ! -e '$h/Library/LaunchAgents/com.tomtim.clawd-pet.plist' ]"
  fi
  uninstall_retry "$h"
  check "ledger: ... one uninstall clears the install cut $2 the ledger's rename (exit 0, the tree equals the tree before the install)" bash -c "[ '$CLI_RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$h")" "$b"
done

new_home "$STAGE/count-logs" logs; HL="$H"
run_shimmed "$HL" 0 before cnt install
T_LOGS="$(op_count "$HL" cnt)"
check "install over retained logs exits 0 and records root-created no" bash -c "[ '$SH_RC' -eq 0 ] && [ \"\$(cat '$(marker_of "$HL")')\" = 'root-created no' ]"
check "install over retained logs does not create \$ROOT" test -z "$(op_no "$HL" cnt "mkdir $(root_of "$HL")")"
check "install over retained logs creates no directory outside \$ROOT" test -z "$(ops_mkdir_outside "$HL" cnt "$(root_of "$HL")")"
check "install over retained logs does not list \$ROOT as a directory it created" bash -c "! grep -qxF 'dir $(root_of "$HL")' '$(root_of "$HL")/manifest'"
new_home "$STAGE/count-empty" emptyroot; HE="$H"
run_shimmed "$HE" 0 before cnt install
T_EMPTY="$(op_count "$HE" cnt)"
check "install over an empty pre-existing \$ROOT records root-created no" test "$(cat "$(marker_of "$HE")")" = "root-created no"

# A name that is published is complete: cut right before each rename, the final name is absent and the .partial is whole.
new_home "$STAGE/rename-manifest" none; h="$H"; r="$(root_of "$h")"
run_shimmed "$h" "$n_manifest" before ins install
check "cut before the manifest rename: the manifest does not exist yet" test ! -e "$r/manifest"
check "cut before the manifest rename: manifest.partial is complete (starts with schema 1, ends with end)" bash -c "[ \"\$(sed -n 1p '$r/manifest.partial')\" = 'schema 1' ] && [ \"\$(tail -n 1 '$r/manifest.partial')\" = end ]"
new_home "$STAGE/rename-agent" none; h="$H"; r="$(root_of "$h")"
run_shimmed "$h" "$n_agent_mv" before ins install
check "cut before the agent rename: the agent does not exist yet" test ! -e "$r/bin/clawd-pet-agent"
check "cut before the agent rename: agent.partial is a complete executable copy of the build" bash -c "[ -x '$r/bin/clawd-pet-agent.partial' ] && cmp -s '$r/bin/clawd-pet-agent.partial' '$MINI/build/clawd-pet-agent'"
new_home "$STAGE/rename-launcher" none; h="$H"; r="$(root_of "$h")"
run_shimmed "$h" "$n_launch_mv" before ins install
check "cut before the launcher rename: the launcher does not exist yet" test ! -e "$r/bin/clawd-pet-launch"
check "cut before the launcher rename: launcher.partial is a complete executable copy of the checked-in launcher" bash -c "[ -x '$r/bin/clawd-pet-launch.partial' ] && cmp -s '$r/bin/clawd-pet-launch.partial' '$MINI/launcher/clawd-pet-launch'"
new_home "$STAGE/rename-cli" none; h="$H"
run_shimmed "$h" "$n_cli_mv" before ins install
check "cut before the CLI rename: the CLI does not exist yet" test ! -e "$h/bin/clawd-pet"
check "cut before the CLI rename: clawd-pet.partial is a complete executable copy of the CLI" bash -c "[ -x '$h/bin/clawd-pet.partial' ] && cmp -s '$h/bin/clawd-pet.partial' '$MINI/bin/clawd-pet'"

# A copy that "succeeds" and is wrong. Install proves the launcher by its sha256, not by cp's exit status: it dies before the launcher
# gets its final name, and one uninstall removes what it left.
new_home "$STAGE/corrupt-launcher" none; h="$H"; r="$(root_of "$h")"; b="$(tree "$h")"
export OPSHIM_CORRUPT_AT="$n_launch_cp"
run_shimmed "$h" 0 before cor install
unset OPSHIM_CORRUPT_AT
check "a launcher copy spoiled after a successful cp: install exits 2" test "$SH_RC" -eq 2
check "... says the copy does not match the recorded sha256" grep -q "does not match the recorded sha256" "$h.cor.out"
check "... says the install is incomplete and to run uninstall" grep -q "the install is incomplete" "$h.cor.out"
check "... the launcher never got its final name" test ! -e "$r/bin/clawd-pet-launch"
check "... and the spoiled copy is still a .partial" test -f "$r/bin/clawd-pet-launch.partial"
check "... install went no further (no plist)" test ! -e "$h/Library/LaunchAgents/com.tomtim.clawd-pet.plist"
uninstall_retry "$h"
check "... one uninstall removes what it left (exit 0)" test "$CLI_RC" -eq 0
check "... and the tree equals the tree before install" test "$(tree "$h")" = "$b"

# ---- 2. install cut before every operation, and every copy cut mid-write ---------------------------------------------------------
MX="$STAGE/m-install"; mkdir -p "$MX"
iter_install() { # id at mode preset T
  local id="$1" at="$2" mode="$3" preset="$4" T="$5" RES="$MX/res-$1" h base killed rc
  new_home "$MX/home-$id" "$preset"; h="$H"; base="$(tree "$h")"
  run_shimmed "$h" "$at" "$mode" ins install
  killed="$(tree "$h")"
  if [ "$at" -le "$T" ]; then
    [ "$SH_RC" -eq 137 ] || bad "install($preset) cut at op $at/$mode: the installer did not die (rc $SH_RC)"
    ! grep -q 'nothing signalled' "$h.ins.ops" || bad "install($preset) cut at op $at/$mode: the shim could not signal"
  else
    [ "$SH_RC" -eq 0 ] || bad "install($preset) with no cut exited $SH_RC"
  fi
  uninstall_retry "$h"; rc=$CLI_RC
  if [ "$killed" = "$base" ]; then
    [ "$rc" -eq 2 ] || bad "install($preset) cut at op $at/$mode left nothing, uninstall should refuse with 'no record' (rc $rc)"
  else
    [ "$rc" -eq 0 ] || bad "install($preset) cut at op $at/$mode: one uninstall exited $rc: $CLI_OUT"
  fi
  [ "$(tree "$h")" = "$base" ] || bad "install($preset) cut at op $at/$mode: the tree after uninstall differs from the tree before install"
  finish_job
}
expected=0
for preset in none logs emptyroot; do
  case "$preset" in none) T="$T_NONE" ;; logs) T="$T_LOGS" ;; emptyroot) T="$T_EMPTY" ;; esac
  at=1
  while [ "$at" -le $((T + 1)) ]; do spawn iter_install "$preset-$at-before" "$at" before "$preset" "$T"; expected=$((expected + 1)); at=$((at + 1)); done
  case "$preset" in none) cph="$HN" ;; logs) cph="$HL" ;; emptyroot) cph="$HE" ;; esac
  for at in $(cp_ops "$cph" cnt); do spawn iter_install "$preset-$at-tear" "$at" tear "$preset" "$T"; expected=$((expected + 1)); done
done
drain
tally "install cut before every operation and every copy cut mid-write (3 starting trees)" "$MX" "$expected"

# Cut right after the marker, with a pre-existing empty $ROOT: the marker says root-created no, uninstall keeps $ROOT and removes the marker.
new_home "$STAGE/after-marker" emptyroot; h="$H"
run_shimmed "$h" 1 after ins install
check "install cut right after the marker: marker exists" test -f "$(marker_of "$h")"
check "install cut right after the marker: the marker says root-created no" test "$(cat "$(marker_of "$h")")" = "root-created no"
check "install cut right after the marker: the pre-existing \$ROOT is untouched and empty" bash -c "[ -d '$(root_of "$h")' ] && [ -z \"\$(ls -A '$(root_of "$h")')\" ]"
cli "$h" uninstall
check "install cut after the marker (pre-existing empty \$ROOT): uninstall exits 0 and reports an interrupted install" bash -c "[ '$CLI_RC' -eq 0 ] && printf '%s' '$CLI_OUT' | grep -q 'removed an interrupted install'"
check "install cut after the marker (pre-existing empty \$ROOT): uninstall leaves \$ROOT and removes the marker" bash -c "[ -d '$(root_of "$h")' ] && [ ! -e '$(marker_of "$h")' ]"

# ---- 3. uninstall cut before every operation, for every state an interrupted install leaves ----------------------------------------
MX="$STAGE/m-uninstall"; mkdir -p "$MX"
iter_uninstall_state() { # id preset inst_at   (inst_at 0 = a completed install)
  local id="$1" preset="$2" inst_at="$3" RES="$MX/res-$1" k U b h
  new_home "$MX/home-$id-count" "$preset"; h="$H"; b="$(tree "$h")"
  run_shimmed "$h" "$inst_at" before mk install
  run_shimmed "$h" 0 before unc uninstall
  U="$(op_count "$h" unc)"
  [ "$(tree "$h")" = "$b" ] || bad "uninstall($preset, install cut at $inst_at): the counting run left a different tree"
  k=1
  while [ "$k" -le "${U:-0}" ]; do
    new_home "$MX/home-$id-$k" "$preset"; h="$H"; b="$(tree "$h")"
    run_shimmed "$h" "$inst_at" before mk install
    run_shimmed "$h" "$k" before un uninstall
    [ "$SH_RC" -eq 137 ] || bad "uninstall($preset, install cut at $inst_at) was not cut at op $k (rc $SH_RC)"
    uninstall_retry "$h"
    [ "$CLI_RC" -eq 0 ] || bad "uninstall($preset, install cut at $inst_at) cut at op $k: the rerun exited $CLI_RC: $CLI_OUT"
    [ "$(tree "$h")" = "$b" ] || bad "uninstall($preset, install cut at $inst_at) cut at op $k: the tree after the rerun differs from the tree before install"
    k=$((k + 1))
  done
  echo "$U" > "$MX/ops-$id"
  finish_job
}
expected=0
for preset in none logs emptyroot; do
  case "$preset" in none) T="$T_NONE" ;; logs) T="$T_LOGS" ;; emptyroot) T="$T_EMPTY" ;; esac
  at=1
  while [ "$at" -le $((T + 1)) ]; do
    inst_at="$at"; [ "$at" -le "$T" ] || inst_at=0
    spawn iter_uninstall_state "$preset-$at" "$preset" "$inst_at"; expected=$((expected + 1)); at=$((at + 1))
  done
done
drain
cases=0; for f in "$MX"/ops-*; do cases=$((cases + $(cat "$f"))); done
tally "uninstall cut before every operation of every interrupted state ($cases cuts)" "$MX" "$expected"

# The named case: SIGKILL right after the manifest rm, before rmdir $ROOT. The marker stays; the rerun removes $ROOT and then the marker.
for preset in none logs; do
  new_home "$STAGE/amr-$preset-cnt" "$preset"; h="$H"
  run_shimmed "$h" 0 before mk install
  run_shimmed "$h" 0 before unc uninstall
  n_rm="$(op_no "$h" unc "rm -- $(root_of "$h")/manifest")"
  check "uninstall($preset): found the manifest rm" test -n "$n_rm"
  new_home "$STAGE/amr-$preset" "$preset"; h="$H"; b="$(tree "$h")"
  run_shimmed "$h" 0 before mk install
  run_shimmed "$h" "${n_rm:-0}" after un uninstall
  check "uninstall($preset) cut right after the manifest rm: the cut happened" test "$SH_RC" -eq 137
  check "uninstall($preset) cut right after the manifest rm: manifest gone, marker kept" bash -c "[ ! -e '$(root_of "$h")/manifest' ] && [ -f '$(marker_of "$h")' ]"
  check "uninstall($preset) cut right after the manifest rm: \$ROOT not yet removed" test -d "$(root_of "$h")"
  uninstall_retry "$h"
  check "uninstall($preset) rerun after the cut: exit 0, reports an interrupted install" bash -c "[ '$CLI_RC' -eq 0 ] && printf '%s' '$CLI_OUT' | grep -q 'removed an interrupted install'"
  check "uninstall($preset) rerun after the cut: the marker is gone" test ! -e "$(marker_of "$h")"
  if [ "$preset" = none ]; then
    check "uninstall(none) rerun after the cut: \$ROOT is removed" test ! -e "$(root_of "$h")"
  else
    check "uninstall(logs) rerun after the cut: \$ROOT stays with its retained logs" test -f "$(root_of "$h")/agent.log"
  fi
  check "uninstall($preset) rerun after the cut: the tree equals the tree before install" test "$(tree "$h")" = "$b"
done

# ---- 4. a delayed orphan writer: a copy child that outlives the SIGKILLed installer -----------------------------------------------
orphan_case() { # label, literal of the cp op to stop at (taken from the counting log)
  local label="$1" literal="$2" n h b orphan installer stopfile t0
  n="$(op_no "$HN" cnt "$literal")"
  check "orphan($label): found the copy operation to stop" test -n "$n"
  new_home "$STAGE/orphan-$label" none; h="$H"; b="$(tree "$h")"
  reset_run "$h" orp
  ( launch "$h" orp "$n" stop install ) > "$h.orp.out" 2>&1 &
  BG_PID=$!
  wait_until 1200 file_nonempty "$h.orp.stop"
  orphan="$(cat "$h.orp.stop" 2>/dev/null)"; installer="$(cat "$h.orp.pid" 2>/dev/null)"
  [ -z "$orphan" ] || tracked+=("$orphan")
  [ -z "$installer" ] || tracked+=("$installer")
  check "orphan($label): the copy child stopped itself" bash -c "[ -n '$orphan' ]"
  wait_until 1200 is_stopped "${orphan:-0}"
  check "orphan($label): the copy child is stopped (SIGSTOP) before it opened its target" is_stopped "${orphan:-0}"
  [ -n "$installer" ] && kill -KILL "$installer"
  { wait "$BG_PID"; } 2>/dev/null
  check "orphan($label): the installer is dead and the copy child is not" bash -c "! kill -0 '$installer' 2>/dev/null && kill -0 '$orphan' 2>/dev/null"
  t0="$(tree "$h")"
  cli "$h" uninstall
  check "orphan($label): uninstall refuses while the copy child lives (exit 2)" test "$CLI_RC" -eq 2
  check "orphan($label): the refusal names the copy child's pid" contains "$CLI_OUT" "pid $orphan:"
  check "orphan($label): the refusal says nothing was removed" contains "$CLI_OUT" "nothing was removed"
  check "orphan($label): the refused uninstall removed nothing" test "$(tree "$h")" = "$t0"
  kill -CONT "$orphan" 2>/dev/null
  wait_until 1200 is_gone "${orphan:-0}"
  check "orphan($label): the copy child finished after SIGCONT" is_gone "${orphan:-0}"
  uninstall_retry "$h"
  check "orphan($label): the rerun after it exited removes everything (exit 0)" test "$CLI_RC" -eq 0
  check "orphan($label): the tree equals the tree before install" test "$(tree "$h")" = "$b"
}
orphan_case agent-partial "cp $MINI/build/clawd-pet-agent $RN/bin/clawd-pet-agent.partial"
orphan_case art-file "cp $MINI/art/clawd-atlas.json $RN/art/clawd-atlas.json"
orphan_case cli-partial "cp $MINI/bin/clawd-pet $HN/bin/clawd-pet.partial"
orphan_case launcher-partial "cp $MINI/launcher/clawd-pet-launch $RN/bin/clawd-pet-launch.partial"

# ---- 5. states injected by hand --------------------------------------------------------------------------------------------------
inj() { new_home "$STAGE/inj-$1" "${2:-none}"; h="$H"; r="$(root_of "$h")"; mk="$(marker_of "$h")"; b="$(tree "$h")"; b0="$b"; }

# 5a. truncated manifest.partial with the marker -> removed (root created by the install, and a pre-existing root)
inj trunc-marker-yes; printf 'root-created yes\n' > "$mk"; mkdir "$r"; printf 'schema 1\nfile /x' > "$r/manifest.partial"
cli "$h" uninstall
check "5a truncated manifest.partial + marker(yes): removed, exit 0" test "$CLI_RC" -eq 0
check "5a ... the tree equals the tree before" test "$(tree "$h")" = "$b"
inj trunc-marker-no emptyroot; printf 'root-created no\n' > "$mk"; printf 'schema 1\nfile /x' > "$r/manifest.partial"
cli "$h" uninstall
check "5a truncated manifest.partial + marker(no) in a pre-existing \$ROOT: manifest.partial and marker removed, \$ROOT kept" bash -c "[ '$CLI_RC' -eq 0 ] && [ -d '$r' ] && [ ! -e '$r/manifest.partial' ] && [ ! -e '$mk' ]"
check "5a ... the tree equals the tree before (pre-existing \$ROOT)" test "$(tree "$h")" = "$b"
# 5b. the same without the marker -> refused, nothing removed
inj trunc-nomarker; mkdir "$r"; printf 'schema 1\nfile /x' > "$r/manifest.partial"; b="$(tree "$h")"
cli "$h" uninstall
check "5b truncated manifest.partial without the marker: refused (exit 2)" test "$CLI_RC" -eq 2
check "5b ... says there is no record and nothing was removed" bash -c "printf '%s' '$CLI_OUT' | grep -q 'no record' && printf '%s' '$CLI_OUT' | grep -q 'nothing removed'"
check "5b ... removed nothing" test "$(tree "$h")" = "$b"
# 5c. manifest without end -> refused, nothing removed; with a line after end -> refused
inj no-end; cli "$h" install; cp "$r/manifest" "$STAGE/inj-no-end.manifest"; sed '$d' "$STAGE/inj-no-end.manifest" > "$r/manifest"; b="$(tree "$h")"
check "5c the injected manifest really lacks its end line" bash -c "! grep -qx end '$r/manifest'"
cli "$h" uninstall
check "5c manifest without end: refused (exit 2)" test "$CLI_RC" -eq 2
check "5c ... removed nothing" test "$(tree "$h")" = "$b"
cp "$STAGE/inj-no-end.manifest" "$r/manifest"; printf 'file /etc/hosts\n' >> "$r/manifest"; b="$(tree "$h")"
cli "$h" uninstall
check "5c manifest with a line after end: refused (exit 2), nothing removed" bash -c "[ '$CLI_RC' -eq 2 ] && [ -f /etc/hosts ]"
check "5c ... removed nothing" test "$(tree "$h")" = "$b"
cp "$STAGE/inj-no-end.manifest" "$r/manifest"
cli "$h" uninstall
check "5c the restored manifest uninstalls" test "$CLI_RC" -eq 0
# 5d. half-written agent.partial with no agent -> removed, and the enumeration came from the repo build
inj half-agent; cli "$h" install; rm -f -- "$r/bin/clawd-pet-agent"; printf 'MZ half' > "$r/bin/clawd-pet-agent.partial"; : > "$h.enum.log"
cli "$h" uninstall
check "5d half-written agent.partial and no agent: uninstall exits 0" test "$CLI_RC" -eq 0
check "5d ... the tree equals the tree before install" test "$(tree "$h")" = "$b"
check "5d ... the processes were enumerated by the repo build (no installed agent existed)" bash -c "grep -qx repo '$h.enum.log' && ! grep -qx installed '$h.enum.log'"
# 5e. no enumerator available -> refused, nothing removed
inj no-enum; cli "$h" install; rm -f -- "$r/bin/clawd-pet-agent"; printf 'MZ half' > "$r/bin/clawd-pet-agent.partial"; b="$(tree "$h")"
CLI_UNDER_TEST="$h/bin/clawd-pet" cli "$h" uninstall
check "5e no installed agent, run from the installed CLI (no repo): refused (exit 2)" test "$CLI_RC" -eq 2
check "5e ... the message says to run scripts/uninstall from the repo after swift build -c release" contains "$CLI_OUT" "run scripts/uninstall from the repo after swift build -c release"
check "5e ... removed nothing" test "$(tree "$h")" = "$b"
CLI_UNDER_TEST="$MINI2/bin/clawd-pet" cli "$h" uninstall
check "5e no installed agent, repo without a build: refused (exit 2) and nothing removed" bash -c "[ '$CLI_RC' -eq 2 ]"
check "5e ... removed nothing (repo without a build)" test "$(tree "$h")" = "$b"
cli "$h" uninstall
check "5e the same state is removed from the repo with a build" test "$CLI_RC" -eq 0
check "5e ... and the tree equals the tree before install" test "$(tree "$h")" = "$b0"
# 5f. a pre-existing empty $ROOT with no marker -> refused and left alone
inj empty-root-nomarker emptyroot
cli "$h" uninstall
check "5f pre-existing empty \$ROOT, no marker: uninstall refuses (exit 2)" test "$CLI_RC" -eq 2
check "5f ... leaves \$ROOT as it was" test "$(tree "$h")" = "$b"
# 5g. a marker, no manifest, and something unexpected inside $ROOT -> refused, listed, nothing removed
inj unexpected-entry; printf 'root-created yes\n' > "$mk"; mkdir "$r" "$r/bin"; b="$(tree "$h")"
cli "$h" uninstall
check "5g marker + unexpected entry in \$ROOT: refused (exit 2) and the entry is named" bash -c "[ '$CLI_RC' -eq 2 ] && printf '%s' '$CLI_OUT' | grep -q 'holds bin'"
check "5g ... removed nothing" test "$(tree "$h")" = "$b"
# 5h. a stray marker partial alone -> removed as a single file
inj stray-partial; printf 'root-c' > "$mk.partial"
cli "$h" uninstall
check "5h a stray clawd-pet.installing.partial alone: removed (exit 0), tree restored" bash -c "[ '$CLI_RC' -eq 0 ] && [ ! -e '$mk.partial' ]"
check "5h ... the tree equals the tree before" test "$(tree "$h")" = "$b"
# 5i. an unreadable marker -> refused
inj bad-marker; printf 'garbage\n' > "$mk"; mkdir "$r"; b="$(tree "$h")"
cli "$h" uninstall
check "5i unreadable marker: refused (exit 2), nothing removed" bash -c "[ '$CLI_RC' -eq 2 ]"
check "5i ... removed nothing" test "$(tree "$h")" = "$b"
# 5j. a complete manifest and no marker: everything listed is removed, \$ROOT is left (nothing says this install created it)
inj marker-lost; cli "$h" install; rm -f -- "$mk"
cli "$h" uninstall
check "5j manifest but no marker: uninstall exits 0" test "$CLI_RC" -eq 0
check "5j ... removed every listed file and left only an empty \$ROOT" bash -c "[ -d '$r' ] && [ -z \"\$(ls -A '$r')\" ] && [ ! -e '$h/bin/clawd-pet' ]"
# 5k. a symlinked $ROOT -> refused
inj symlink-root; mkdir "$h/elsewhere"; ln -s "$h/elsewhere" "$r"; b="$(tree "$h")"
cli "$h" uninstall
check "5k symlinked \$ROOT: uninstall refuses (exit 2), nothing removed" bash -c "[ '$CLI_RC' -eq 2 ]"
check "5k ... removed nothing" test "$(tree "$h")" = "$b"
# 5l. residue keeps the manifest (A-N2): an unlisted file inside a listed directory makes uninstall exit 2 with the record intact; a retry finishes
inj residue; cli "$h" install; printf 'x\n' > "$r/art/extra.txt"
cli "$h" uninstall
check "5l an unlisted file inside \$ROOT/art: uninstall exits 2" test "$CLI_RC" -eq 2
check "5l ... names what is left" bash -c "printf '%s' '$CLI_OUT' | grep -q '$r/art'"
check "5l ... keeps the manifest and the marker so a retry still has its record" bash -c "[ -f '$r/manifest' ] && [ -f '$mk' ]"
rm -f -- "$r/art/extra.txt"
cli "$h" uninstall
check "5l after the unlisted file is removed the retry finishes (exit 0)" test "$CLI_RC" -eq 0
check "5l ... and the tree equals the tree before install" test "$(tree "$h")" = "$b0"
# 5m. a listed path that is not a regular file is refused, not removed
inj not-regular; cli "$h" install; rm -f -- "$r/art/clawd-atlas.json"; mkdir "$r/art/clawd-atlas.json"; b="$(tree "$h")"
cli "$h" uninstall
check "5m a listed file replaced by a directory: uninstall refuses (exit 2)" test "$CLI_RC" -eq 2
# 5n. a manifest.partial beside a complete manifest is not part of the record (install renames it away, so the two never coexist), and
# unless it provably is a cut update's leftover (Tests/update.test.sh 5f has those shapes) uninstall refuses, lists it and removes nothing;
# once its owner removes it, the retry finishes. A dangling symlink counts too.
inj partial-beside-manifest; cli "$h" install; printf 'not a manifest\n' > "$r/manifest.partial"; b="$(tree "$h")"
cli "$h" uninstall
check "5n manifest.partial beside a complete manifest: uninstall refuses (exit 2)" test "$CLI_RC" -eq 2
check "5n ... names the file" contains "$CLI_OUT" "$r/manifest.partial"
check "5n ... says it removed nothing" contains "$CLI_OUT" "nothing was removed"
check "5n ... removed nothing (the plist and the other copy included)" test "$(tree "$h")" = "$b"
rm -f -- "$r/manifest.partial"; ln -s /nonexistent-clawd-target "$r/manifest.partial"; b="$(tree "$h")"
cli "$h" uninstall
check "5n a dangling symlink named manifest.partial: refused (exit 2), nothing removed" bash -c "[ '$CLI_RC' -eq 2 ] && [ -L '$r/manifest.partial' ]"
check "5n ... removed nothing" test "$(tree "$h")" = "$b"
rm -f -- "$r/manifest.partial"
cli "$h" uninstall
check "5n after its owner removes the file the retry finishes (exit 0)" test "$CLI_RC" -eq 0
check "5n ... and the tree equals the tree before install" test "$(tree "$h")" = "$b0"

# 5o. the residue check knows the launcher: a launcher the manifest does not list is left behind by an uninstall, and an uninstall that
# leaves it says so (exit 2, naming $ROOT/bin, keeping the manifest and the marker); once it is removed by hand the retry finishes.
inj launcher-unlisted; cli "$h" install; grep -vxF "file $r/bin/clawd-pet-launch" "$r/manifest" > "$STAGE/inj-launcher.manifest"; cp "$STAGE/inj-launcher.manifest" "$r/manifest"
check "5o the injected manifest really lacks the launcher" bash -c "! grep -qxF 'file $r/bin/clawd-pet-launch' '$r/manifest'"
cli "$h" uninstall
check "5o a launcher the manifest does not list: uninstall exits 2" test "$CLI_RC" -eq 2
check "5o ... names what is left (the bin directory that still holds it)" contains "$CLI_OUT" "$r/bin"
check "5o ... keeps the manifest and the marker so a retry still has its record" bash -c "[ -f '$r/manifest' ] && [ -f '$mk' ]"
check "5o ... and the launcher is still there (it was never listed, so it is never removed blindly)" test -f "$r/bin/clawd-pet-launch"
rm -f -- "$r/bin/clawd-pet-launch"
cli "$h" uninstall
check "5o once the unlisted launcher is removed by hand the retry finishes (exit 0)" test "$CLI_RC" -eq 0
check "5o ... and the tree equals the tree before install" test "$(tree "$h")" = "$b0"

# ---- 6. install refusals: nothing is created, nothing is changed -------------------------------------------------------------------
refuse_case() { # label, preparation command run with $h $r $mk set
  new_home "$STAGE/refuse-$1" "${3:-none}"; h="$H"; r="$(root_of "$h")"; mk="$(marker_of "$h")"
  eval "$2"
  b="$(tree "$h")"
  cli "$h" install
  check "install refuses: $1 (exit 2)" test "$CLI_RC" -eq 2
  check "install refusal ($1) changed nothing" test "$(tree "$h")" = "$b"
}
refuse_case "marker exists" 'printf "root-created no\n" > "$mk"'
refuse_case "marker partial exists" 'printf "x" > "$mk.partial"'
refuse_case "manifest exists" 'mkdir "$r"; printf "schema 1\nend\n" > "$r/manifest"'
refuse_case "manifest.partial exists" 'mkdir "$r"; printf "schema 1\n" > "$r/manifest.partial"'
refuse_case "plist exists" 'printf "x" > "$h/Library/LaunchAgents/com.tomtim.clawd-pet.plist"'
refuse_case "CLI target exists" 'printf "x" > "$h/bin/clawd-pet"'
refuse_case "CLI partial exists" 'printf "x" > "$h/bin/clawd-pet.partial"'
refuse_case "\$ROOT holds something besides logs" 'mkdir "$r"; printf "x" > "$r/state.json"'
refuse_case "\$ROOT holds a stray agent.partial" 'mkdir "$r"; mkdir "$r/bin"; printf "x" > "$r/bin/clawd-pet-agent.partial"'
refuse_case "\$ROOT holds a stray clawd-pet-launch.partial" 'mkdir "$r"; mkdir "$r/bin"; printf "x" > "$r/bin/clawd-pet-launch.partial"'
refuse_case "\$ROOT holds a control.lock" 'mkdir "$r"; printf "" > "$r/control.lock"'
refuse_case "\$ROOT is a symlink" 'mkdir "$h/elsewhere"; ln -s "$h/elsewhere" "$r"'
refuse_case "agent.log is a symlink" 'mkdir "$r"; ln -s "$h/bin/other-tool" "$r/agent.log"'
for parent in "bin" "Library/LaunchAgents" "Library/Application Support"; do
  new_home "$STAGE/noparent-$(printf '%s' "$parent" | tr -c 'A-Za-z0-9\n' '_')" none; h="$H"
  # take the parent away: its decoy files go first, one by one
  case "$parent" in
    "bin") rm -f -- "$h/bin/other-tool" ;;
    "Library/LaunchAgents") rm -f -- "$h/Library/LaunchAgents/other.plist" ;;
    "Library/Application Support") rm -f -- "$h/Library/Application Support/OtherApp/data"; rmdir "$h/Library/Application Support/OtherApp" ;;
  esac
  rmdir "$h/$parent"
  b="$(tree "$h")"
  cli "$h" install
  check "install refuses when $parent does not exist (exit 2)" test "$CLI_RC" -eq 2
  check "... and says to create $parent first" contains "$CLI_OUT" "create $h/$parent first"
  check "... and created nothing (no \$ROOT, no marker, no parent)" test "$(tree "$h")" = "$b"
done
new_home "$STAGE/nolibrary" none; h="$H"
rm -f -- "$h/Library/LaunchAgents/other.plist" "$h/Library/Application Support/OtherApp/data"; rmdir "$h/Library/LaunchAgents" "$h/Library/Application Support/OtherApp" "$h/Library/Application Support" "$h/Library"; b="$(tree "$h")"
cli "$h" install
check "install refuses when ~/Library does not exist (exit 2)" test "$CLI_RC" -eq 2
check "... and creates nothing" test "$(tree "$h")" = "$b"

# ---- 7. signals during an install: INT, TERM and HUP ---------------------------------------------------------------------------------
# The copy of the agent is held by a handshake (Tests/interrupt-shims/op-shim, OPSHIM_WAIT_*): the shim blocks inside the copy until
# this test has sent the signal and creates the release file. CLAWD_TEST_SIGNAL_DELAY (seconds, default 0) adds a pause between "the
# installer is inside the copy" and the signal, which is what a loaded machine does; the result must not depend on it.
sig_case() { # signal, expected exit status
  local sig="$1" want="$2" h b installer n rc
  n="$(op_no "$HN" cnt "cp $MINI/build/clawd-pet-agent $RN/bin/clawd-pet-agent.partial")"
  new_home "$STAGE/sig-$sig" none; h="$H"; b="$(tree "$h")"
  reset_run "$h" sig
  WAIT_AT="$n"
  if [ "$sig" = INT ]; then LAUNCH_PERL=1; fi
  ( launch "$h" sig 0 before install ) > "$h.sig.out" 2>&1 &
  BG_PID=$!
  unset WAIT_AT LAUNCH_PERL
  wait_until 1200 file_exists "$h.sig.wait.ready"
  installer="$(cat "$h.sig.pid" 2>/dev/null)"
  [ -z "$installer" ] || tracked+=("$installer")
  check "signal($sig): the installer is inside the held copy" bash -c "[ -n '$installer' ] && [ -e '$h.sig.wait.ready' ] && kill -0 '$installer'"
  sleep "${CLAWD_TEST_SIGNAL_DELAY:-0}"
  kill "-$sig" "$installer"
  : > "$h.sig.wait.release"
  wait "$BG_PID"; rc=$?
  check "signal($sig): the handshake did not time out" bash -c "! grep -q HANDSHAKE-TIMEOUT '$h.sig.ops'"
  check "signal($sig): the installer exits nonzero ($want)" test "$rc" -eq "$want"
  check "signal($sig): it prints 'interrupted; run scripts/uninstall from the repo'" grep -qF "interrupted; run scripts/uninstall from the repo" "$h.sig.out"
  check "signal($sig): the installer was gone when the copy child had finished (nothing outlives it)" is_gone "$installer"
  uninstall_retry "$h"
  check "signal($sig): one uninstall removes what was installed" bash -c "[ '$CLI_RC' -eq 0 ]"
  check "signal($sig): the tree equals the tree before install" test "$(tree "$h")" = "$b"
}
sig_case INT 130
sig_case TERM 143
sig_case HUP 129

# The shim's own handshake: a held call that is never released fails (exit 125, HANDSHAKE-TIMEOUT, the operation not done); a released one proceeds.
h="$STAGE/shim-handshake"; mkdir -p "$h" || exit 2
printf 'payload\n' > "$h/src"
run_wait() { # release-first? -> SHIM_RC; the copy is call 1
  rm -f -- "$h/dst" "$h/ready" "$h/release" "$h/log"
  [ "$1" != yes ] || : > "$h/release"
  OPSHIM_COUNT="$h/count" OPSHIM_LOG="$h/log" OPSHIM_WAIT_AT=1 OPSHIM_WAIT_READY="$h/ready" OPSHIM_WAIT_RELEASE="$h/release" OPSHIM_WAIT_MAX=1 \
    "$SHIMS/cp" "$h/src" "$h/dst" > /dev/null 2>&1
  SHIM_RC=$?
}
echo 0 > "$h/count"; run_wait no
check "shim handshake: no release within the bound: exit 125" test "$SHIM_RC" -eq 125
check "shim handshake: ... HANDSHAKE-TIMEOUT is logged" grep -q HANDSHAKE-TIMEOUT "$h/log"
check "shim handshake: ... the operation was not done" test ! -e "$h/dst"
check "shim handshake: ... and the ready file was created" test -e "$h/ready"
echo 0 > "$h/count"; run_wait yes
check "shim handshake: released: the operation runs (exit 0)" test "$SHIM_RC" -eq 0
check "shim handshake: ... and copies the file" cmp -s "$h/src" "$h/dst"
check "shim handshake: ... without a timeout in the log" bash -c "! grep -q HANDSHAKE-TIMEOUT '$h/log'"

# ---- 8. `clawd-pet start` racing an uninstall -------------------------------------------------------------------------------------
# Trigger: the user runs `clawd-pet start` from another terminal while uninstall runs. The stub launchctl (Tests/stubs/launchctl-race)
# loads the job only while its plist exists and, on kickstart, starts a real --test-hold process from the installed agent path; its
# bootout stops that process. The start is run by the shim hook at three points of the uninstall: just before the plist is
# removed, just after it, and just before the first listed file (the agent) is removed, which is right after the final enumeration.
# Whichever point the start lands on, uninstall must end with the label not loaded, nothing running under the installed path and
# the tree as before the install. A start before the plist is removed may succeed (the second bootout takes it down); after it, start must fail.
RACE_BUILD="$STAGE/build-real"; mkdir -p "$RACE_BUILD" && cp "$REAL_AGENT" "$RACE_BUILD/clawd-pet-agent"
STUB_LAUNCHCTL="$STUBS/launchctl-race"; BUILD_UNDER_TEST="$RACE_BUILD"
new_home "$STAGE/race-count" none; hc="$H"
cli "$hc" install
check "race: the counting install succeeds" test "$CLI_RC" -eq 0
run_shimmed "$hc" 0 before unc uninstall
check "race: the counting uninstall exits 0" test "$SH_RC" -eq 0
n_rm_plist="$(op_no "$hc" unc "rm -- $hc/Library/LaunchAgents/com.tomtim.clawd-pet.plist")"
# uninstall removes its files in batches of up to 100 per rm call: the first listed file (the agent) is the first name of the first batch.
n_rm_agent="$(/usr/bin/awk -v s="rm -- $(root_of "$hc")/bin/clawd-pet-agent " '$2 == "rm" { rest = $0; sub(/^[0-9]+ /, "", rest); if (index(rest, s) == 1) { print $1; exit } }' "$hc.unc.ops")"
check "race: found the plist rm and the agent rm in the uninstall's operations" bash -c "[ -n '$n_rm_plist' ] && [ -n '$n_rm_agent' ]"
check "race: the plist is removed before any process step, so before the first listed file" bash -c "[ '$n_rm_plist' -lt '$n_rm_agent' ]"

race_case() { # label, call number, when (before|after), want (up: the start may bring the agent up | down: it must fail)
  local label="$1" at="$2" when="$3" want="$4" h b pid hrc own
  new_home "$STAGE/race-$label" none; h="$H"; b="$(tree "$h")"
  cli "$h" install
  check "race($label): the install succeeds" test "$CLI_RC" -eq 0
  HOOK_AT="$at"; HOOK_WHEN="$when"
  run_shimmed "$h" 0 before race uninstall
  unset HOOK_AT HOOK_WHEN
  pid="$(cat "$h.agent.pid" 2>/dev/null)"; hrc="$(cat "$h.race.hook.rc" 2>/dev/null)"
  check "race($label): the hook ran" test -n "$hrc"
  if [ "$want" = up ]; then
    check "race($label): the start went through and brought the agent up (the race is real)" bash -c "[ '$hrc' = 0 ] && [ -n '$pid' ]"
  else
    check "race($label): the start failed" bash -c "[ -n '$hrc' ] && [ '$hrc' != 0 ]"
    check "race($label): ... because the install is being removed, and it says so" grep -qF "unfinished" "$h.race.hook.out"
    check "race($label): ... and brought nothing up" test -z "$pid"
  fi
  check "race($label): uninstall exits 0" test "$SH_RC" -eq 0
  check "race($label): the label is not loaded at the end" test ! -e "$h.stub.loaded"
  check "race($label): the process the start brought up is gone" bash -c "[ -z '$pid' ] || ! kill -0 '$pid' 2>/dev/null"
  # A listing that refuses (fail closed) because some agent of this suite is being torn down at that instant (under a second, with no path and
  # the agent's name) says nothing about this install, so it is asked again for up to 5 s. An agent of THIS install left running after its file
  # was removed also has no path and refuses every time: its command line still names the install's agent, and that ends the retries at once,
  # so the check fails on the refusal instead of waiting the agent out.
  own_listing() {
    own="$(HOME="$h" "$REAL_AGENT" --own-pids 2>&1 | tail -n 1)"
    case "$own" in "OWN-PIDS "[0-9]*) return 0 ;; esac
    # pgrep never lists itself (a ps | grep would match the grep's own command line, which names the path too)
    /usr/bin/pgrep -f -- "$(root_of "$h")/bin/clawd-pet-agent" > /dev/null && { own="$own (and a process still names $(root_of "$h")/bin/clawd-pet-agent)"; return 0; }
    return 1
  }
  wait_until 100 own_listing
  check "race($label): --own-pids finds nothing under the installed path (got: $own)" test "$own" = "OWN-PIDS 0"
  check "race($label): the tree equals the tree before install" test "$(tree "$h")" = "$b"
  # a process the stub started and uninstall left running is stopped here, by the pid the stub recorded and only while its command line names the installed agent
  if [ -n "$pid" ] && alive "$pid" && /bin/ps -o command= -p "$pid" 2>/dev/null | grep -qF -- "$(root_of "$h")/bin/clawd-pet-agent"; then kill -KILL "$pid" 2>/dev/null; fi
}
race_case before-plist-rm "$n_rm_plist" before up
race_case after-plist-rm "$n_rm_plist" after down
race_case after-enumeration "$n_rm_agent" before down

# A live writer while the plist is present: the plist goes first, so the refusal names the pid and says no other file was removed;
# every other file is kept, and the retry after the writer exits finishes.
new_home "$STAGE/race-writer" none; h="$H"; b="$(tree "$h")"
cli "$h" install
/usr/bin/perl -e 'sleep 100' "$(root_of "$h")/writer" > /dev/null 2>&1 &
writer=$!; tracked+=("$writer"); disown "$writer" 2>/dev/null
t0="$(tree "$h" | grep -vF 'com.tomtim.clawd-pet.plist')"
cli "$h" uninstall
check "writer: uninstall refuses while a process names the installation (exit 2)" test "$CLI_RC" -eq 2
check "writer: ... names the pid" contains "$CLI_OUT" "pid $writer:"
check "writer: ... says no other file was removed and that the plist already went" bash -c "printf '%s' '$CLI_OUT' | grep -qF 'no other file was removed' && printf '%s' '$CLI_OUT' | grep -qF 'already removed the LaunchAgent plist'"
check "writer: the plist is gone and the agent is still in place" bash -c "[ ! -e '$h/Library/LaunchAgents/com.tomtim.clawd-pet.plist' ] && [ -f '$(root_of "$h")/bin/clawd-pet-agent' ]"
check "writer: the tree is the tree before the uninstall, minus the plist" test "$(tree "$h" | grep -vF 'com.tomtim.clawd-pet.plist')" = "$t0"
check "writer: the manifest is still there, so a retry has its record" test -f "$(root_of "$h")/manifest"
kill "$writer" 2>/dev/null
wait_until 1200 is_gone "$writer"
uninstall_retry "$h"
check "writer: the retry after it exits finishes (exit 0)" test "$CLI_RC" -eq 0
check "writer: ... and the tree equals the tree before install" test "$(tree "$h")" = "$b"
STUB_LAUNCHCTL="$STUBS/launchctl"; BUILD_UNDER_TEST="$MINI/build"

# ---- 8b. `clawd-pet update` cut before every operation, and every copy cut mid-write ---------------------------------------------------
# A second version of the fake repo: a new agent and CLI, changed pictures and catalogs, new pictures (7 in one directory), a new look and
# a new frame. An update of an installed v1 is cut right before each of its operations
# (and each copy is also left half-written); after every cut the plist, the launcher, control.json and control.lock must be as they were,
# one more update must finish (and end in exactly the tree an uncut update ends in), and an uninstall, run instead, must remove the install
# entirely. A manifest.partial beside the manifest (a cut in the instant before the rename) is that update's leftover: the next update, or an
# uninstall run instead, discards it (both hold the update lock, so no update is writing it) and goes on.
MINI_UP="$STAGE/repo-up"
mkdir -p "$MINI_UP/bin" "$MINI_UP/launchd" "$MINI_UP/launcher" "$MINI_UP/art/frames" "$MINI_UP/art/motions/M1" "$MINI_UP/art/motions/M2" "$MINI_UP/art/looks/L1" "$MINI_UP/art/looks/L2" "$MINI_UP/build" || exit 2
cp "$MINI/bin/clawd-pet" "$MINI_UP/bin/clawd-pet" && chmod 755 "$MINI_UP/bin/clawd-pet" && printf '# cli v2\n' >> "$MINI_UP/bin/clawd-pet"
cp "$MINI/launchd/com.tomtim.clawd-pet.plist.in" "$MINI_UP/launchd/"
cp "$MINI/launcher/clawd-pet-launch" "$MINI/launcher/clawd-pet-launch.sha256" "$MINI_UP/launcher/"
: > "$MINI_UP/Package.swift"
cp "$MINI/build/clawd-pet-agent" "$MINI_UP/build/clawd-pet-agent" && printf '# agent v2\n' >> "$MINI_UP/build/clawd-pet-agent"
for n in 1 2 3 4; do printf 'frame %s\n' "$n" > "$MINI_UP/art/frames/f$n.png"; done
# Three changed pictures in two directories (motions/M1 twice, looks/L1 once) and nine new ones (3 directories): update places the twelve as sets of
# pictures (every copy written to its .partial name, then the flush, then the renames, then the directories; CLAWD_FLUSH_CHUNK is 4 for this
# matrix, so there are three sets), so a cut can land between two copies, between two renames, between two sets, or between the renames and the
# next step. A new picture goes the same way as a replaced one: it never has its final name before it is on the disk.
printf 'picture motions/M1/000.png v2\n' > "$MINI_UP/art/motions/M1/000.png"; printf 'picture motions/M1/001.png v2\n' > "$MINI_UP/art/motions/M1/001.png"
printf 'picture looks/L1/layer.png v2\n' > "$MINI_UP/art/looks/L1/layer.png"; printf 'picture looks/L2/layer.png\n' > "$MINI_UP/art/looks/L2/layer.png"
up_named='"motions/M1/000.png","motions/M1/001.png","looks/L1/layer.png","looks/L2/layer.png","frames/f4.png"'
n=0; while [ "$n" -lt 7 ]; do rel="$(printf 'motions/M2/%03d.png' "$n")"; printf 'picture %s\n' "$rel" > "$MINI_UP/art/$rel"; up_named="$up_named,\"$rel\""; n=$((n + 1)); done
printf '{"schema":2,"files":[%s]}\n' "$up_named" > "$MINI_UP/art/clawd-atlas.json"
printf '{"v":2}\n' > "$MINI_UP/art/claude-code-elements.json"

# The tree of a home with the home's own path left out of every file's content (the plist names it) and the ledger's birth epoch left out
# (it is the second the install ran), so that the trees of two different homes can be compared. The manifest's content is left out too: a copy cut mid-write is seen by the next update as a file that differs,
# which is replaced through a .partial name, and update records that name, so the manifest of a finished update that was cut earlier lists
# more names than an uncut one's (`manifest_covers` checks that it lists at least the same).
tree_n() {
  (cd "$1" && LC_ALL=C find . -print | LC_ALL=C sort
   LC_ALL=C find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
     if [ "$f" = "./Library/Application Support/clawd-pet/manifest" ]; then printf 'manifest %s\n' "$f"; continue; fi
     printf '%s %s\n' "$(LC_ALL=C /usr/bin/sed -e "s|$1|@HOME@|g" -e 's/^LEDGER 1 born=[0-9][0-9]*/LEDGER 1 born=@EPOCH@/' "$f" | /usr/bin/cksum | cut -d' ' -f1)" "$f"
   done) | LC_ALL=C grep -v '/clawd-pet/status.json$'
}
# status.json is the running agent's: a running pet (make_running) has one, an install that was never started has none.
manifest_lines() { LC_ALL=C /usr/bin/sed "s|$1|@HOME@|g" "$(root_of "$1")/manifest" | LC_ALL=C sort; }
# True when the manifest of home $1 lists every line the manifest in file $2 does.
manifest_covers() { [ -z "$(LC_ALL=C comm -13 <(manifest_lines "$1") "$2")" ]; }
keep_files() { # home -> the digests of what an update must never touch
  local r f; r="$(root_of "$1")"
  for f in "$1/Library/LaunchAgents/com.tomtim.clawd-pet.plist" "$r/bin/clawd-pet-launch" "$r/control.json" "$r/control.lock"; do
    printf '%s %s %s\n' "$(/usr/bin/stat -f '%i %m %z' "$f")" "$(/usr/bin/cksum < "$f")" "${f##*/}"
  done
}
install_v1() { # home -> installs the base version
  CLI_UNDER_TEST="$MINI/bin/clawd-pet"; BUILD_UNDER_TEST="$MINI/build"
  cli "$1" install
  [ "$CLI_RC" -eq 0 ] || bad "install of v1 failed: $CLI_OUT"
}
# An install made before the restart marker existed: its manifest does not list $ROOT/restart-pending (update adds the line first).
old_manifest() {
  local r; r="$(root_of "$1")"
  grep -vxF "file $r/restart-pending" "$r/manifest" > "$r/manifest.new" && mv "$r/manifest.new" "$r/manifest" || bad "cannot make an old-style manifest for $1"
}
# A running pet: the stub launchd (Tests/stubs/launchctl-update) lists the job with pid 4242, changes the pid on `kickstart -k` and answers
# as the restarted agent (status.json with the new pid and the generation); the old agent's status.json is there.
make_running() {
  : > "$1.stub.loaded"; echo 4242 > "$1.stub.loaded.pid"
  printf '{"focusViolations":0,"pid":4242,"appliedGeneration":0}\n' > "$(root_of "$1")/status.json"
}
to_v2() { CLI_UNDER_TEST="$MINI_UP/bin/clawd-pet"; BUILD_UNDER_TEST="$MINI_UP/build"; }
to_v1() { CLI_UNDER_TEST="$MINI/bin/clawd-pet"; BUILD_UNDER_TEST="$MINI/build"; }

export CLAWD_FLUSH_CHUNK=4
new_home "$STAGE/upd-count" none; hU="$H"; rU="$(root_of "$hU")"
to_v1; cli "$hU" install; keep_u="$(keep_files "$hU")"
to_v2; run_shimmed "$hU" 0 before upd update
T_UPD="$(op_count "$hU" upd)"
F_UPD="$(tree_n "$hU")"
check "update counting run exits 0 and saw operations" bash -c "[ '$SH_RC' -eq 0 ] && [ '${T_UPD:-0}' -ge 15 ]"
check "update: the plist, the launcher, control.json and control.lock were not touched (inode, mtime, bytes)" test "$(keep_files "$hU")" = "$keep_u"
check "update: no operation names the plist, the launcher, control.json or control.lock" bash -c "! grep -qE 'LaunchAgents|clawd-pet-launch|control\\.(json|lock)' '$hU.upd.ops'"
check "update: the art is the v2 art, byte for byte, and the agent and the CLI are v2" bash -c "cd '$MINI_UP/art' && find . -type f | while read -r f; do cmp -s \"\$f\" '$rU/art/'\"\$f\" || exit 1; done && cmp -s '$MINI_UP/build/clawd-pet-agent' '$rU/bin/clawd-pet-agent' && cmp -s '$MINI_UP/bin/clawd-pet' '$hU/bin/clawd-pet'"
check "update: no .partial is left behind" bash -c "! find '$hU' -name '*.partial' | grep -q ."
check "update: the manifest is published before any directory is made or file is copied" bash -c "[ \"\$(awk '\$2 == \"mv\" && index(\$0, \"manifest.partial\") { print \$1; exit }' '$hU.upd.ops')\" -lt \"\$(awk '\$2 == \"mkdir\" || \$2 == \"cp\" { print \$1; exit }' '$hU.upd.ops')\" ]"
check "update: a replaced picture, a new picture and the two catalogs go through .partial names" bash -c "awk '\$2 == \"cp\"' '$hU.upd.ops' | grep -q 'art/motions/M1/000.png.partial' && awk '\$2 == \"cp\"' '$hU.upd.ops' | grep -q 'art/motions/M2/003.png.partial' && awk '\$2 == \"cp\"' '$hU.upd.ops' | grep -q 'art/clawd-atlas.json.partial'"
check "update: no copy into the art tree names anything but a .partial file (a new picture is never copied to its final name)" bash -c "! awk '\$2 == \"cp\" && index(\$0, \"clawd-pet/art/\") && !/\\.partial\$/' '$hU.upd.ops' | grep -q ."
check "update: the twelve pictures are three sets of four: four copies, four renames, four copies, four renames, four copies, four renames" bash -c "[ \"\$(awk '\$2 == \"cp\" && /\\.png\\.partial\$/ { printf \"c\" } \$2 == \"mv\" && index(\$0, \".png.partial \") { printf \"m\" }' '$hU.upd.ops')\" = ccccmmmmccccmmmmccccmmmm ]"
check "update: the catalogs' copies come after the last picture is renamed" bash -c "awk '\$2 == \"mv\" && index(\$0, \".png.partial \") { l = NR } \$2 == \"cp\" && index(\$0, \"art/clawd-atlas.json.partial\") { k = NR } END { exit (l && k && l < k) ? 0 : 1 }' '$hU.upd.ops'"
check "update: the agent and the CLI go through .partial names" bash -c "awk '\$2 == \"cp\"' '$hU.upd.ops' | grep -q 'clawd-pet-agent.partial' && awk '\$2 == \"cp\"' '$hU.upd.ops' | grep -q 'bin/clawd-pet.partial'"
check "update runs no compiler" bash -c "! grep -Eq ' (cc|clang|swiftc|codesign) ' '$hU.upd.ops'"
to_v1; cli "$hU" uninstall
check "update: the counting run is removed by one uninstall" test "$CLI_RC" -eq 0
# The same update on a running pet (the stub launchd of make_running): the operations up to the last copy are the same ones, and the restart
# adds calls that no cut can reach (sed inside the pid lookup runs in a subshell), so the cut points of a running pet are the file
# operations, the removal of the marker after the confirmed restart, and no cut at all.
n_last_mv="$(op_no "$hU" upd "mv $hU/bin/clawd-pet.partial $hU/bin/clawd-pet")"
last_mv_n="$(awk '$2 == "mv" { n = $1 } END { print n }' "$hU.upd.ops")"
STUB_LAUNCHCTL="$STUBS/launchctl-update"
new_home "$STAGE/upd-count-running" none; hUL="$H"
to_v1; cli "$hUL" install; make_running "$hUL"
to_v2; run_shimmed "$hUL" 0 before upd update
n_rm_loaded="$(awk '$2 == "rm" && index($0, "restart-pending") { n = $1 } END { print n }' "$hUL.upd.ops")"
check "update on a running pet: exit 0, one kickstart -k, and the operations up to the last copy are the plain run's" bash -c "[ '$SH_RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$hUL.stub.log')\" = 1 ] && [ \"\$(head -n $n_last_mv '$hUL.upd.ops' | sed 's|$hUL|@H@|g')\" = \"\$(head -n $n_last_mv '$hU.upd.ops' | sed 's|$hU|@H@|g')\" ]"
check "update on a running pet: the marker is removed after the restart, by a call the CLI itself makes (it can be cut)" bash -c "[ -n '$n_rm_loaded' ] && [ '$n_rm_loaded' -gt '$n_last_mv' ]"
to_v1; cli "$hUL" uninstall
check "update on a running pet: the counting run is removed by one uninstall" test "$CLI_RC" -eq 0
STUB_LAUNCHCTL="$STUBS/launchctl"

MX="$STAGE/m-update"; mkdir -p "$MX"
iter_update() { # id at mode
  local id="$1" at="$2" mode="$3" RES="$MX/res-$1" h hb k0 t0 partial_a partial_b had_partial pid_after kicks at_a
  # Home A: cut, then update again. The pet is running (a stub launchd whose pid changes on kickstart -k) and its manifest predates the
  # restart marker, so the marker's line has to reach the manifest before the marker exists.
  STUB_LAUNCHCTL="$STUBS/launchctl-update"
  new_home "$MX/a-$id" none; h="$H"
  install_v1 "$h"; old_manifest "$h"; make_running "$h"; t0="$(tree "$h")"; k0="$(keep_files "$h")"
  at_a="$at"
  if [ "$at" -gt "$T_UPD" ]; then at_a=0; elif [ "$at" -gt "$n_last_mv" ]; then at_a="$n_rm_loaded"; fi
  to_v2; run_shimmed "$h" "$at_a" "$mode" upd update
  if [ "$at_a" -ne 0 ]; then
    [ "$SH_RC" -eq 137 ] || bad "update cut at op $at/$mode: the update did not die (rc $SH_RC)"
    ! grep -q 'nothing signalled' "$h.upd.ops" || bad "update cut at op $at/$mode: the shim could not signal"
  else
    [ "$SH_RC" -eq 0 ] || bad "update with no cut exited $SH_RC"
  fi
  [ "$(keep_files "$h")" = "$k0" ] || bad "update cut at op $at/$mode: the plist, the launcher or the settings files changed"
  [ -f "$(root_of "$h")/bin/clawd-pet-agent" ] && [ -x "$(root_of "$h")/bin/clawd-pet-agent" ] || bad "update cut at op $at/$mode: the installed agent is not a complete executable"
  [ -x "$h/bin/clawd-pet" ] || bad "update cut at op $at/$mode: the installed CLI is not an executable"
  partial_a="$(root_of "$h")/manifest.partial"
  if [ -e "$partial_a" ]; then
    # A cut in the instant before the rename: the next update holds the lock, knows no other update is writing it, and discards it.
    to_v2; cli "$h" update
    { [ "$CLI_RC" -eq 0 ] && contains "$CLI_OUT" "discarded a stale manifest.partial"; } || bad "update cut at op $at/$mode left manifest.partial: the next update should discard it and go on (rc $CLI_RC: $CLI_OUT)"
    [ ! -e "$partial_a" ] || bad "update cut at op $at/$mode left manifest.partial: the next update did not discard it"
  fi
  to_v2; cli "$h" update
  [ "$CLI_RC" -eq 0 ] || bad "update cut at op $at/$mode: running update again exited $CLI_RC: $CLI_OUT"
  [ "$(tree_n "$h")" = "$F_UPD_NORM" ] || bad "update cut at op $at/$mode: the tree after running update again differs from the tree of an uncut update"
  manifest_covers "$h" "$STAGE/upd-final.manifest" || bad "update cut at op $at/$mode: the manifest after running update again lacks lines the manifest of an uncut update has"
  [ "$(keep_files "$h")" = "$k0" ] || bad "update cut at op $at/$mode: running update again changed the plist, the launcher or the settings files"
  # Whatever the cut, the running agent has been restarted onto the new files by now, and the marker is gone. Once is enough; twice happens
  # when the cut came after a confirmed restart and before the marker was removed (a restart too many is safe, one too few is not).
  pid_after="$(cat "$h.stub.loaded.pid" 2>/dev/null)"; kicks="$(grep -c '^launchctl kickstart -k ' "$h.stub.log" 2>/dev/null)"
  { [ "${pid_after:-0}" -ge 4243 ] && [ "${kicks:-0}" -ge 1 ] && [ "${kicks:-0}" -le 2 ]; } || bad "update cut at op $at/$mode, then update again: the running agent was not restarted as needed (pid ${pid_after:-none}, ${kicks:-0} kickstart -k)"
  grep -q "\"pid\":${pid_after:-none}[,}]" "$(root_of "$h")/status.json" 2>/dev/null || bad "update cut at op $at/$mode, then update again: status.json does not name the restarted agent (pid ${pid_after:-none})"
  [ ! -e "$(root_of "$h")/restart-pending" ] || bad "update cut at op $at/$mode, then update again: the restart marker is still there after the confirmed restart"
  ! grep -qE '^launchctl (bootout|bootstrap|kickstart [^-])' "$h.stub.log" || bad "update cut at op $at/$mode: a launchd verb other than kickstart -k was sent"
  to_v1; uninstall_retry "$h"
  [ "$CLI_RC" -eq 0 ] || bad "update cut at op $at/$mode, finished, then uninstall exited $CLI_RC: $CLI_OUT"
  # Home B: cut, then uninstall instead (also an install whose manifest predates the marker: the marker may not outlive the uninstall).
  STUB_LAUNCHCTL="$STUBS/launchctl"
  new_home "$MX/b-$id" none; hb="$H"
  install_v1 "$hb"; old_manifest "$hb"; t0="$(tree "$hb")"
  to_v2; run_shimmed "$hb" "$at" "$mode" upd update
  partial_b="$(root_of "$hb")/manifest.partial"
  had_partial=0; [ ! -e "$partial_b" ] || had_partial=1
  to_v1; uninstall_retry "$hb"
  [ "$CLI_RC" -eq 0 ] || bad "update cut at op $at/$mode: one uninstall exited $CLI_RC: $CLI_OUT"
  # A cut in the instant before the rename leaves a manifest.partial beside the manifest: the same one uninstall (under the lock, by the rule
  # update uses) discards it, says so in one line, and removes everything.
  if [ "$had_partial" = 1 ]; then
    contains "$CLI_OUT" "discarded a stale manifest.partial" || bad "update cut at op $at/$mode left manifest.partial: uninstall should have discarded it and said so (rc $CLI_RC: $CLI_OUT)"
  else
    ! contains "$CLI_OUT" "discarded a stale manifest.partial" || bad "update cut at op $at/$mode left no manifest.partial, but uninstall says it discarded one"
  fi
  [ "$(tree "$hb")" = "$PRE_UPD_TREE" ] || bad "update cut at op $at/$mode: the tree after one uninstall differs from the tree before the install"
  finish_job
}
# The tree an uncut update ends in, with the fake home's own name left out (the trees of different homes differ in no path below the home).
new_home "$STAGE/upd-pre" none; PRE_UPD_TREE="$(tree "$H")"
new_home "$STAGE/upd-final" none; hF="$H"
to_v1; cli "$hF" install; to_v2; cli "$hF" update
F_UPD_NORM="$(tree_n "$hF")"; manifest_lines "$hF" > "$STAGE/upd-final.manifest"
check "update: an uncut update ends in the same tree whether or not the shim counts its operations" test "$F_UPD_NORM" = "$F_UPD"
expected=0
at=1
while [ "$at" -le $((T_UPD + 1)) ]; do spawn iter_update "$at-before" "$at" before; expected=$((expected + 1)); at=$((at + 1)); done
for at in $(cp_ops "$hU" upd); do spawn iter_update "$at-tear" "$at" tear; expected=$((expected + 1)); done
drain
tally "update cut before every operation and every copy cut mid-write (each followed by update again, and by an uninstall instead)" "$MX" "$expected"

# ---- 8c. a cut between the last copy and the restart --------------------------------------------------------------------------------
# The update is killed right after it swapped in the CLI (its last copy), before the proofs and before `launchctl kickstart -k`: every file on
# disk is the new build and the agent that runs still holds the old one in memory. A plain `update` used to find the files current, say
# "already up to date" and leave the old agent running (it could then load frames of the new art: the delivery-1 failure class). It now
# restarts the agent, because the update that was cut left the restart marker and the marker is removed only by a confirmed restart.
STUB_LAUNCHCTL="$STUBS/launchctl-update"
check "8c: the last copy of an update (the CLI swap) is found in the counting run, and it is the last mv" test -n "$n_last_mv" -a "$n_last_mv" = "$last_mv_n"
new_home "$STAGE/upd-lastcut" none; hL="$H"; rL="$(root_of "$hL")"
to_v1; cli "$hL" install; old_manifest "$hL"; make_running "$hL"
to_v2; run_shimmed "$hL" "$n_last_mv" after upd update
check "8c: cut right after the last copy: the update died (rc 137)" test "$SH_RC" -eq 137
check "8c: ... every file is the new build (agent, CLI, art) and no .partial is left" bash -c "cmp -s '$MINI_UP/build/clawd-pet-agent' '$rL/bin/clawd-pet-agent' && cmp -s '$MINI_UP/bin/clawd-pet' '$hL/bin/clawd-pet' && cmp -s '$MINI_UP/art/motions/M2/006.png' '$rL/art/motions/M2/006.png' && ! find '$hL' -name '*.partial' | grep -q ."
check "8c: ... nothing was sent to launchd (no restart yet), the running agent is still pid 4242, and the marker says the restart is owed" bash -c "! grep -q 'kickstart' '$hL.stub.log' && [ \"\$(cat '$hL.stub.loaded.pid')\" = 4242 ] && [ -f '$rL/restart-pending' ] && grep -qxF 'file $rL/restart-pending' '$rL/manifest'"
cli "$hL" update
check "8c: a plain update after the cut: exit 0 and it restarts the agent (pid 4242 -> 4243) instead of saying 'already up to date'" bash -c "[ '$CLI_RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'restarted the agent (pid 4242 -> 4243)' && ! printf '%s' \"\$1\" | grep -q 'already up to date'" _ "$CLI_OUT"
check "8c: ... exactly one kickstart -k was sent, nothing else but list; status.json names the new agent; the marker is gone" bash -c "[ \"\$(grep -c '^launchctl kickstart -k ' '$hL.stub.log')\" = 1 ] && [ \"\$(grep -vc '^launchctl list ' '$hL.stub.log')\" = 1 ] && grep -q '\"pid\":4243' '$rL/status.json' && [ ! -e '$rL/restart-pending' ]"
cli "$hL" update
check "8c: ... and the update after that has nothing to do: 'already up to date', no further restart" bash -c "[ '$CLI_RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date' && [ \"\$(grep -c '^launchctl kickstart -k ' '$hL.stub.log')\" = 1 ]" _ "$CLI_OUT"
to_v1; uninstall_retry "$hL"
check "8c: ... one uninstall leaves the tree as it was before the install" bash -c "[ '$CLI_RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$hL")" "$PRE_UPD_TREE"
STUB_LAUNCHCTL="$STUBS/launchctl"

# Signals during an update: the copy of the agent is held by the handshake while INT, TERM or HUP arrives (see section 7). The update stops
# with the signal's status after that copy, says that running it again finishes the job, and leaves a pet that still works.
sig_case_update() { # signal, expected exit status
  local sig="$1" want="$2" h installer n rc k0
  n="$(op_no "$hU" upd "cp $MINI_UP/build/clawd-pet-agent $rU/bin/clawd-pet-agent.partial")"
  new_home "$STAGE/usig-$sig" none; h="$H"
  install_v1 "$h"; k0="$(keep_files "$h")"
  to_v2; reset_run "$h" usig
  WAIT_AT="$n"
  if [ "$sig" = INT ]; then LAUNCH_PERL=1; fi
  ( launch "$h" usig 0 before update ) > "$h.usig.out" 2>&1 &
  BG_PID=$!
  unset WAIT_AT LAUNCH_PERL
  wait_until 1200 file_exists "$h.usig.wait.ready"
  installer="$(cat "$h.usig.pid" 2>/dev/null)"
  [ -z "$installer" ] || tracked+=("$installer")
  check "update signal($sig): the update is inside the held copy of the agent" bash -c "[ -n '$n' ] && [ -n '$installer' ] && [ -e '$h.usig.wait.ready' ] && kill -0 '$installer'"
  sleep "${CLAWD_TEST_SIGNAL_DELAY:-0}"
  kill "-$sig" "$installer"
  : > "$h.usig.wait.release"
  wait "$BG_PID"; rc=$?
  check "update signal($sig): the handshake did not time out" bash -c "! grep -q HANDSHAKE-TIMEOUT '$h.usig.ops'"
  check "update signal($sig): the update exits with the signal's status ($want)" test "$rc" -eq "$want"
  check "update signal($sig): it says it was interrupted and that running update again finishes it" grep -qF "update interrupted; the pet still works, and running update again finishes it" "$h.usig.out"
  check "update signal($sig): the update was gone when the copy child had finished (nothing outlives it)" is_gone "$installer"
  check "update signal($sig): the plist, the launcher and the settings files are as they were" test "$(keep_files "$h")" = "$k0"
  to_v2; cli "$h" update
  check "update signal($sig): update again finishes (exit 0)" test "$CLI_RC" -eq 0
  check "update signal($sig): ... in the tree an uncut update ends in" test "$(tree_n "$h")" = "$F_UPD_NORM"
  check "update signal($sig): ... with a manifest that lists at least the lines an uncut update's lists" manifest_covers "$h" "$STAGE/upd-final.manifest"
  to_v1; uninstall_retry "$h"
  check "update signal($sig): one uninstall removes it all (exit 0, the tree equals the tree before the install)" bash -c "[ '$CLI_RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$h")" "$PRE_UPD_TREE"
}
sig_case_update INT 130
sig_case_update TERM 143
sig_case_update HUP 129
to_v1
unset CLAWD_FLUSH_CHUNK

# ---- 8d. the stale-partial guard and the ledger lines -----------------------------------------------------------------------------------
# `manifest_partial_is_stale` accepts only a leftover whose added file and directory lines sit just before the first log line. A partial that
# adds the ledger's lines AFTER the first log line is not what any update writes, so it is refused by name and nothing changes. The test builds
# that partial by hand: update is not its producer. (The same lines, put where update puts them, are accepted: the control case.)
to_v1
for where in after-the-logs before-the-logs; do
  new_home "$STAGE/stale-ledger-$where" none; h="$H"; r="$(root_of "$h")"
  install_v1 "$h"
  grep -vxF -e "file $r/focus-violations.log" -e "file $r/focus-violations.log.partial" "$r/manifest" > "$r/manifest.new" && mv "$r/manifest.new" "$r/manifest" && rm -f -- "$r/focus-violations.log"
  if [ "$where" = after-the-logs ]; then
    awk -v l="file $r/focus-violations.log" -v p="file $r/focus-violations.log.partial" '{ print } /^log / && !done { print l; print p; done = 1 }' "$r/manifest" > "$r/manifest.partial"
  else
    awk -v l="file $r/focus-violations.log" -v p="file $r/focus-violations.log.partial" '/^log / && !done { print l; print p; done = 1 } { print }' "$r/manifest" > "$r/manifest.partial"
  fi
  before="$(tree "$h")"
  cli "$h" update
  if [ "$where" = after-the-logs ]; then
    check "a partial whose ledger line follows the first log line is refused as stale (update exits 2, names it, changes nothing)" bash -c "[ '$CLI_RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'not provably the leftover of a cut update' && [ \"\$2\" = \"\$3\" ]" _ "$CLI_OUT" "$(tree "$h")" "$before"
  else
    check "the same ledger lines just before the first log line are accepted as a cut update's leftover (control case: discarded, update goes on)" bash -c "[ '$CLI_RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'discarded a stale manifest.partial'" _ "$CLI_OUT"
  fi
done

# ---- 9. which interpreter ran every CLI process the stubs saw -----------------------------------------------------------------------
shells="$(sort "$STUB_SHELL_LOG" | uniq -c | sed 's/^ *//' | tr '\n' ';')"
echo "interrupt: interpreters seen by the stubs: $shells"
check "the stubs recorded the interpreter of many CLI processes" bash -c "[ \$(wc -l < '$STUB_SHELL_LOG') -ge 100 ]"
if [ "${CLAWD_TEST_BASH:-}" = /bin/bash ]; then
  check "pinned: every CLI process the stubs saw was /bin/bash (bash 3.2)" bash -c "! grep -vxF /bin/bash '$STUB_SHELL_LOG'"
else
  check "unpinned: every CLI process the stubs saw was $CLI_BASH" bash -c "! grep -vxF '$CLI_BASH' '$STUB_SHELL_LOG'"
fi

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
