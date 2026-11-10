#!/bin/bash
# CLI test: runs bin/clawd-pet against a FAKE HOME with a stub launchctl and a stub open.
# Nothing is loaded in the real session, no real launchctl is called, no window can appear.
# The only real processes are the ones this script starts itself (holders of the fake install path and one unrelated sleep).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/bin/clawd-pet"
# Every invocation of the CLI under test goes through $CLI_BASH. CLAWD_TEST_BASH=/bin/bash pins every child CLI process to macOS's
# bash 3.2; unset, they use the bash found on PATH. The stubs record which interpreter called them (STUB_SHELL_LOG), and the checks
# at the end assert that record, so the claim "ran under 3.2" rests on the processes that actually ran, not on the shell that started this file.
CLI_BASH="${CLAWD_TEST_BASH:-bash}"
STUBS="$REPO/Tests/stubs"
STAGE="$REPO/.build/cli-test/$(date +%s)-$$"
mkdir -p "$STAGE/home" "$STAGE/build" || { echo "cannot create $STAGE"; exit 2; }
FAKE="$STAGE/home"
# install creates nothing outside its own root, so the shared parents of a real HOME exist before it runs
mkdir -p "$FAKE/bin" "$FAKE/Library/LaunchAgents" "$FAKE/Library/Application Support" || { echo "cannot create the fake HOME parents"; exit 2; }

pass=0; fail=0
check() { # name, then a command whose success is the check
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
alive() { kill -0 "$1" 2>/dev/null; }
wait_until() { # tries, then a command (a poll of a real condition with a generous bound; the test fails when the bound is hit)
  local tries="$1" n=0; shift
  while [ "$n" -lt "$tries" ]; do "$@" && return 0; sleep 0.05; n=$((n + 1)); done
  return 1
}
# CLAWD_TEST_STOP_AFTER=<section> ends the run after that section (a development aid for running one part of this file).
stop_here() {
  [ "${CLAWD_TEST_STOP_AFTER:-}" = "$1" ] || return 0
  echo "clawd-pet-cli.test: stopped after section $1: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]; exit $?
}
plist_value() { /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
num_eq() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }

AGENT_BIN=""
for candidate in "$REPO/.build/release/clawd-pet-agent" "$REPO/.build/debug/clawd-pet-agent"; do
  if [ -x "$candidate" ]; then AGENT_BIN="$candidate"; break; fi
done
[ -n "$AGENT_BIN" ] || { echo "build the agent first (swift build)"; exit 2; }
cp "$AGENT_BIN" "$STAGE/build/clawd-pet-agent"

export HOME="$FAKE"
export CLAWD_LAUNCHCTL="$STUBS/launchctl"
export STUB_LOG="$STAGE/launchctl.calls"; export STUB_STATE="$STAGE/loaded"
export STUB_OPEN_LOG="$STAGE/open.calls"; export STUB_OWN_LOG="$STAGE/own-pids.calls"; export STUB_SHELL_LOG="$STAGE/cli-shell.calls"
export STUB_CC_LOG="$STAGE/compiler.calls"
: > "$STUB_LOG"; : > "$STUB_OPEN_LOG"; : > "$STUB_OWN_LOG"; : > "$STUB_SHELL_LOG"; : > "$STUB_CC_LOG"
echo "clawd-pet-cli.test: CLI interpreter = $CLI_BASH, version $("$CLI_BASH" -c 'echo "$BASH_VERSION"')"
export PATH="$STUBS:$PATH"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.21.4</string></dict></plist>' > "$STAGE/Info-tested.plist"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.21.2</string></dict></plist>' > "$STAGE/Info-previous.plist"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.22.0</string></dict></plist>' > "$STAGE/Info-newer.plist"
export CLAWD_AQUA_INFO_PLIST="$STAGE/Info-tested.plist"

ROOT="$FAKE/Library/Application Support/clawd-pet"
PLIST="$FAKE/Library/LaunchAgents/com.tomtim.clawd-pet.plist"
INSTALLED_CLI="$FAKE/bin/clawd-pet"
INSTALLED_AGENT="$ROOT/bin/clawd-pet-agent"
INSTALLED_LAUNCHER="$ROOT/bin/clawd-pet-launch"
snapshot() { (cd "$FAKE" && find "Library/Application Support/clawd-pet" "Library/Application Support/clawd-pet.installing" "Library/Application Support/clawd-pet.installing.partial" "Library/LaunchAgents/com.tomtim.clawd-pet.plist" "bin/clawd-pet" "bin/clawd-pet.partial" 2>/dev/null | sort); }
calls() { cat "$STUB_LOG"; }
# uninstall removes the LaunchAgent plist before any process step (so a start cannot bring the agent up while its files go), which
# means a refusal after that point has taken the plist and nothing else: this snapshot leaves the plist out.
snap_noplist() { snapshot | grep -vxF "Library/LaunchAgents/com.tomtim.clawd-pet.plist"; }

holders=()
cleanup() { for p in ${holders[@]+"${holders[@]}"}; do alive "$p" && kill -KILL "$p" 2>/dev/null; done; }
trap cleanup EXIT

# ---- 1. read-only commands work from the repo with nothing installed ----------------------------------------
check "bash 5 syntax" bash -n "$CLI"
check "bash 3.2 syntax" /bin/bash -n "$CLI"
out="$("$CLI_BASH" "$CLI" help 2>&1)"; rc=$?
check "help from the repo exits 0" test "$rc" -eq 0
for word in start stop status size helmet walk motion look-every bubble aqua full-screen chat hide show install uninstall; do check "help mentions $word" contains "$out" "$word"; done
check "help documents look random|ID" contains "$out" "look random|ID"
check "help documents aqua follow|ignore|auto" contains "$out" "aqua follow|ignore|auto"
check "help says look-every is the mean of the drawn interval" contains "$out" "(4h by default; the mean of the drawn interval"
out32="$(/bin/bash "$CLI" help 2>&1)"; check "help under /bin/bash 3.2" test "$?" -eq 0
check "help needs no install (fake HOME is empty)" test ! -e "$ROOT"
"$CLI_BASH" "$CLI" bogus >/dev/null 2>&1; check "unknown command exits 2" test "$?" -eq 2
out="$("$CLI_BASH" "$CLI" status 2>&1)"; rc=$?
check "status works with nothing installed" test "$rc" -eq 0
check "status says not installed" contains "$out" "installed: no"
check "status says not loaded" contains "$out" "service: not loaded"
check "status: wake coverage not yet observed" contains "$out" "wake coverage: not yet observed"
check "status: display-change coverage not yet observed" contains "$out" "display-change coverage: not yet observed"
check "status: Aqua version printed" contains "$out" "Aqua version: 0.21.4"
check "status: no warning for the tested Aqua 0.21.4" lacks "$out" "WARNING"
out="$(CLAWD_AQUA_INFO_PLIST="$STAGE/Info-newer.plist" "$CLI_BASH" "$CLI" status 2>&1)"
check "status warns when Aqua differs from 0.21.4" contains "$out" "WARNING: Aqua version differs"
out="$(CLAWD_AQUA_INFO_PLIST="$STAGE/Info-previous.plist" "$CLI_BASH" "$CLI" status 2>&1)"
check "status warns for the previously tested Aqua 0.21.2" contains "$out" "WARNING: Aqua version differs from the tested 0.21.4"
out="$(CLAWD_AQUA_INFO_PLIST="$STAGE/Info-absent.plist" "$CLI_BASH" "$CLI" status 2>&1)"
check "status without Aqua Voice installed says so" contains "$out" "Aqua Voice: not installed"
check "... and prints no version line" lacks "$out" "Aqua version"
check "... and no warning" lacks "$out" "WARNING"
check "read-only commands only ever ran launchctl list" bash -c "! grep -vE '^launchctl list ' '$STUB_LOG'"

# ---- 2. install ---------------------------------------------------------------------------------------------
before="$(snapshot)"
CLAWD_BUILD_DIR="$STAGE/missing-build" "$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "install without a built binary fails" test "$?" -ne 0
check "failed install changed nothing" test "$(snapshot)" = "$before"
export CLAWD_BUILD_DIR="$STAGE/build"
out="$("$CLI_BASH" "$CLI" install 2>&1)"; rc=$?
check "install exits 0" test "$rc" -eq 0
check "install says nothing was started" contains "$out" "nothing started"
check "plist exists" test -f "$PLIST"
check "plist lints" /usr/bin/plutil -lint "$PLIST"
check "plist Label" test "$(plist_value Label "$PLIST")" = "com.tomtim.clawd-pet"
check "plist RunAtLoad true" test "$(plist_value RunAtLoad "$PLIST")" = "true"
check "plist KeepAlive SuccessfulExit false" test "$(plist_value KeepAlive.SuccessfulExit "$PLIST")" = "false"
check "plist ThrottleInterval 30" test "$(plist_value ThrottleInterval "$PLIST")" = "30"
check "plist LimitLoadToSessionType Aqua" test "$(plist_value LimitLoadToSessionType "$PLIST")" = "Aqua"
check "plist ProgramArguments names the installed launcher" test "$(plist_value ProgramArguments.0 "$PLIST")" = "$INSTALLED_LAUNCHER"
check "... and not the agent (a rebuilt agent must not change what macOS tracks)" test "$(plist_value ProgramArguments.0 "$PLIST")" != "$INSTALLED_AGENT"
check "plist ProgramArguments has exactly one element" test "$(plist_value ProgramArguments "$PLIST")" = 1
check "installed agent is executable and identical to the build" bash -c "[ -x '$INSTALLED_AGENT' ] && cmp -s '$INSTALLED_AGENT' '$STAGE/build/clawd-pet-agent'"
LAUNCHER_REC="$(cut -d' ' -f1 "$REPO/launcher/clawd-pet-launch.sha256")"
check "installed launcher is executable and byte-identical to the checked-in launcher" bash -c "[ -x '$INSTALLED_LAUNCHER' ] && cmp -s '$INSTALLED_LAUNCHER' '$REPO/launcher/clawd-pet-launch'"
check "installed launcher has the sha256 recorded in launcher/clawd-pet-launch.sha256" test "$(/usr/bin/shasum -a 256 < "$INSTALLED_LAUNCHER" | cut -d' ' -f1)" = "$LAUNCHER_REC"
check "install never ran a compiler (the launcher is copied, never built)" test ! -s "$STUB_CC_LOG"
check "manifest lists the launcher and its .partial name" bash -c "grep -qxF 'file $INSTALLED_LAUNCHER' '$ROOT/manifest' && grep -qxF 'file $INSTALLED_LAUNCHER.partial' '$ROOT/manifest'"
check "manifest lists control.lock and control.json.partial" bash -c "grep -qxF 'file $ROOT/control.lock' '$ROOT/manifest' && grep -qxF 'file $ROOT/control.json.partial' '$ROOT/manifest'"
check "control.lock exists, is a regular empty file, and control.json starts at generation 0" bash -c "[ -f '$ROOT/control.lock' ] && [ ! -L '$ROOT/control.lock' ] && [ ! -s '$ROOT/control.lock' ] && [ \"\$(/usr/bin/plutil -extract generation raw -o - '$ROOT/control.json')\" = 0 ]"
LEDGER_FILE="$ROOT/focus-violations.log"
check "ledger: the manifest lists the focus-violation ledger and its .partial name as ordinary file lines" bash -c "grep -qxF 'file $LEDGER_FILE' '$ROOT/manifest' && grep -qxF 'file $LEDGER_FILE.partial' '$ROOT/manifest'"
check "ledger: both lines come before the first log line (the place update puts the lines it adds)" bash -c "[ \$(grep -nxF 'file $LEDGER_FILE' '$ROOT/manifest' | cut -d: -f1) -lt \$(grep -n '^log ' '$ROOT/manifest' | head -n 1 | cut -d: -f1) ]"
check "ledger: no manifest line has a kind an older uninstall would reject (only schema, file, dir, log, logbase, end)" bash -c "! grep -vE '^(schema 1|file |dir |log |logbase |end)' '$ROOT/manifest'"
check "ledger: exists, is a regular file with mode 600 and holds exactly the install header (LEDGER 1 born=<epoch> how=install)" bash -c "[ -f '$LEDGER_FILE' ] && [ ! -L '$LEDGER_FILE' ] && [ \"\$(/usr/bin/stat -f %Lp '$LEDGER_FILE')\" = 600 ] && [ \$(grep -c '' '$LEDGER_FILE') = 1 ] && grep -qE '^LEDGER 1 born=[0-9]+ how=install\$' '$LEDGER_FILE'"
check "ledger: no .partial of the ledger is left behind" test ! -e "$LEDGER_FILE.partial"
check "installed CLI is executable" test -x "$INSTALLED_CLI"
out="$("$CLI_BASH" "$INSTALLED_CLI" help 2>&1)"; check "help works from the installed path" contains "$out" "stop"
MARKER="$FAKE/Library/Application Support/clawd-pet.installing"
check "install leaves the ownership marker outside \$ROOT (root-created yes: \$ROOT did not exist)" test "$(cat "$MARKER")" = "root-created yes"
check "manifest is complete: schema 1 first, end last" bash -c "[ \"\$(sed -n 1p '$ROOT/manifest')\" = 'schema 1' ] && [ \"\$(tail -n 1 '$ROOT/manifest')\" = end ]"
check "manifest records logbase absent for both logs (no log was retained), as the last two lines before end" bash -c "[ \"\$(tail -n 3 '$ROOT/manifest')\" = \"\$(printf '%s\n%s\n%s' 'logbase $ROOT/agent.log absent' 'logbase $ROOT/agent.log.1 absent' end)\" ]"
check "manifest lists the marker, the .partial names and \$ROOT as the first directory" bash -c "grep -qxF 'file $MARKER' '$ROOT/manifest' && grep -qxF 'file $INSTALLED_AGENT.partial' '$ROOT/manifest' && grep -qxF 'file $INSTALLED_CLI.partial' '$ROOT/manifest' && [ \"\$(grep -m1 '^dir ' '$ROOT/manifest')\" = 'dir $ROOT' ]"
check "no .partial and no manifest.partial is left behind by a finished install" bash -c "! find '$FAKE' -name '*.partial' | grep -q ."
check "manifest records schema, agent, plist, cli, atlas" bash -c "grep -qx 'schema 1' '$ROOT/manifest' && grep -qxF 'file $INSTALLED_AGENT' '$ROOT/manifest' && grep -qxF 'file $PLIST' '$ROOT/manifest' && grep -qxF 'file $INSTALLED_CLI' '$ROOT/manifest' && grep -qxF 'file $ROOT/art/clawd-atlas.json' '$ROOT/manifest'"
frames_repo="$(ls "$REPO"/art/frames/*.png | wc -l | tr -d ' ')"; frames_installed="$(ls "$ROOT"/art/frames/*.png | wc -l | tr -d ' ')"
check "all art frames installed" test "$frames_repo" = "$frames_installed"
# The agent draws every motion and look from the installed tree: each file the repo's own atlas names must be installed, byte for byte.
missing_art=0; named_art=0
while IFS= read -r rel; do
  named_art=$((named_art + 1))
  cmp -s "$REPO/art/$rel" "$ROOT/art/$rel" || { missing_art=$((missing_art + 1)); echo "not installed or different: art/$rel"; }
done < <(grep -oE '"[^"]*\.png"' "$REPO/art/clawd-atlas.json" | sed -e 's/^"//' -e 's/"$//' | sort -u)
check "the real atlas names more than the 20 pose frames (motions and looks)" test "$named_art" -gt 1000
check "every file the real atlas names is installed and identical to the repo's" test "$missing_art" -eq 0
check "manifest lists a nested motion frame and the directories above it" bash -c "grep -qxF 'file $ROOT/art/motions/A1-thinking/000.png' '$ROOT/manifest' && grep -qxF 'dir $ROOT/art/motions' '$ROOT/manifest' && grep -qxF 'dir $ROOT/art/motions/A1-thinking' '$ROOT/manifest' && grep -qxF 'dir $ROOT/art/looks/helmet' '$ROOT/manifest'"
# The chat page (Stage 2): the repo's chat-page/ holds exactly the files the installer lists, and all of them are installed byte for byte.
page_files=(index.html page.css page.js marked.min.js Geist-Variable.woff2 OFL.txt LICENSE-marked.txt LICENSE-lucide.txt)
page_bad=0; for rel in "${page_files[@]}"; do cmp -s "$REPO/chat-page/$rel" "$ROOT/chat-page/$rel" || { page_bad=$((page_bad + 1)); echo "chat page file not installed or different: $rel"; }; done
check "every file of the chat page is installed and identical to the repo's" test "$page_bad" -eq 0
check "the repo's chat-page/ holds exactly the 8 listed files (an unlisted file would never be installed)" test "$(ls -A "$REPO/chat-page" | LC_ALL=C sort | tr '\n' ' ')" = "$(printf '%s\n' "${page_files[@]}" | LC_ALL=C sort | tr '\n' ' ')"
check "nothing else is installed in chat-page/" test "$(find "$ROOT/chat-page" -type f | wc -l | tr -d ' ')" = "${#page_files[@]}"
check "the manifest lists the chat-page directory and its files" bash -c "grep -qxF 'dir $ROOT/chat-page' '$ROOT/manifest' && [ \"\$(grep -c '^file $ROOT/chat-page/' '$ROOT/manifest')\" = 8 ]"
check "control.json: release hints disabled by default" test "$(plist_value releaseHintsEnabled "$ROOT/control.json")" = "false"
check "control.json: scale 1 and helmet off" bash -c "[ \"\$(/usr/bin/plutil -extract scale raw -o - '$ROOT/control.json')\" = 1 ] && [ \"\$(/usr/bin/plutil -extract helmet raw -o - '$ROOT/control.json')\" = false ]"
check "install started nothing (no bootstrap, bootout or kickstart)" bash -c "! grep -E 'bootstrap|bootout|kickstart' '$STUB_LOG'"
check "open was never called" test ! -s "$STUB_OPEN_LOG"
afterfirst="$(snapshot)"
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "a second install refuses to overwrite" test "$?" -ne 0
check "the refused install changed nothing" test "$(snapshot)" = "$afterfirst"

# ---- 2b. install copies every file the atlas names (motions/<id>/NNN.png, looks/<id>/...), not only frames/ ------------------------
# A small repo of its own (the real art is over two thousand files) with a schema-2 catalog whose pictures sit in nested directories, one
# of them holding 250 files so that the batched copy and the batched removal cross their 100-file boundary twice. It has its own fake HOME.
ART_REPO="$STAGE/art-repo"; ART_HOME="$STAGE/art-home"
ART_ROOT="$ART_HOME/Library/Application Support/clawd-pet"
mkdir -p "$ART_REPO/bin" "$ART_REPO/launchd" "$ART_REPO/launcher" "$ART_REPO/art/frames" "$ART_REPO/art/motions/A1-thinking" "$ART_REPO/art/motions/B2-long" \
  "$ART_REPO/art/looks/helmet" "$ART_HOME/bin" "$ART_HOME/Library/LaunchAgents" "$ART_HOME/Library/Application Support" || { echo "cannot create $ART_REPO"; exit 2; }
cp "$CLI" "$ART_REPO/bin/clawd-pet" && chmod 755 "$ART_REPO/bin/clawd-pet"
cp "$REPO/launchd/com.tomtim.clawd-pet.plist.in" "$ART_REPO/launchd/"
cp "$REPO/launcher/clawd-pet-launch" "$REPO/launcher/clawd-pet-launch.sha256" "$ART_REPO/launcher/"
: > "$ART_REPO/Package.swift"
printf '{}\n' > "$ART_REPO/art/claude-code-elements.json"
art_named=("frames/idle_0.png" "frames/blink_0.png" "motions/A1-thinking/000.png" "motions/A1-thinking/001.png" "looks/helmet/layer.png")
n=0; while [ "$n" -lt 250 ]; do art_named+=("$(printf 'motions/B2-long/%03d.png' "$n")"); n=$((n + 1)); done
write_art_atlas() { # atlas file, then the relative paths it names
  local f="$1" first=1 rel; shift
  { printf '{"schema":2,"poses":{"idle":{"frames":["frames/idle_0.png"]}},"motions":[{"id":"x","frames":['
    for rel in "$@"; do if [ "$first" = 1 ]; then first=0; else printf ','; fi; printf '"%s"' "$rel"; done
    printf ']}]}\n'; } > "$f"
}
for rel in "${art_named[@]}"; do printf 'picture %s\n' "$rel" > "$ART_REPO/art/$rel"; done
printf 'unnamed frame\n' > "$ART_REPO/art/frames/not_in_the_atlas.png"      # a pose frame the atlas does not name is still copied (v1 behaviour)
write_art_atlas "$ART_REPO/art/clawd-atlas.json" "${art_named[@]}"
art_cli() { # arguments -> ART_OUT, ART_RC; the CLI of the small repo against the small fake HOME
  ART_OUT="$(HOME="$ART_HOME" "$CLI_BASH" "$ART_REPO/bin/clawd-pet" "$@" 2>&1)"; ART_RC=$?
}
art_tree() { (cd "$ART_HOME" && find . | sort); }
art_before="$(art_tree)"
art_cli install
check "art fixture: install exits 0" test "$ART_RC" -eq 0
ok=1; for rel in "${art_named[@]}" frames/not_in_the_atlas.png; do cmp -s "$ART_REPO/art/$rel" "$ART_ROOT/art/$rel" || { ok=0; echo "not installed: $rel"; }; done
check "art fixture: every file the atlas names (nested motion frames, look layer, 250 in one directory) is installed byte for byte" test "$ok" = 1
check "art fixture: a pose frame the atlas does not name is installed too" test -f "$ART_ROOT/art/frames/not_in_the_atlas.png"
check "art fixture: nothing else is in art/ (255 + 1 + 2 json = the files that were named)" test "$(find "$ART_ROOT/art" -type f | wc -l | tr -d ' ')" = "$((${#art_named[@]} + 1 + 2))"
check "art fixture: the manifest lists every installed art file once" bash -c "[ \"\$(grep -c '^file $ART_ROOT/art/' '$ART_ROOT/manifest')\" = \"\$(find '$ART_ROOT/art' -type f | wc -l | tr -d ' ')\" ] && [ -z \"\$(grep '^file ' '$ART_ROOT/manifest' | sort | uniq -d)\" ]"
pos() { grep -nxF -- "$2" "$1" | head -n 1 | cut -d: -f1; }
pa="$(pos "$ART_ROOT/manifest" "dir $ART_ROOT/art")"; pb="$(pos "$ART_ROOT/manifest" "dir $ART_ROOT/art/motions")"; pc="$(pos "$ART_ROOT/manifest" "dir $ART_ROOT/art/motions/A1-thinking")"
pd="$(pos "$ART_ROOT/manifest" "dir $ART_ROOT/art/looks")"; pe="$(pos "$ART_ROOT/manifest" "dir $ART_ROOT/art/looks/helmet")"
check "art fixture: the manifest lists the directories, parents before children" bash -c "[ -n '$pa' ] && [ -n '$pb' ] && [ -n '$pc' ] && [ -n '$pd' ] && [ -n '$pe' ] && [ '$pa' -lt '$pb' ] && [ '$pb' -lt '$pc' ] && [ '$pa' -lt '$pd' ] && [ '$pd' -lt '$pe' ]"
check "art fixture: no .partial is left behind" bash -c "! find '$ART_HOME' -name '*.partial' | grep -q ."
art_cli uninstall
check "art fixture: one uninstall removes the 250-file directory and every other art file" test "$ART_RC" -eq 0
check "art fixture: the tree after uninstall is the tree before install (no file, no art directory left)" test "$(art_tree)" = "$art_before"

# A catalog that names a file the source lacks: install refuses before it creates anything.
rm -- "$ART_REPO/art/motions/A1-thinking/001.png"
art_cli install
check "art fixture: an atlas naming a missing motion frame refuses the install (exit 2)" test "$ART_RC" -eq 2
check "art fixture: ... naming the missing file" contains "$ART_OUT" "art/motions/A1-thinking/001.png"
check "art fixture: ... and created nothing at all" test "$(art_tree)" = "$art_before"
printf 'picture motions/A1-thinking/001.png\n' > "$ART_REPO/art/motions/A1-thinking/001.png"
rm -- "$ART_REPO/art/looks/helmet/layer.png"
art_cli install
check "art fixture: an atlas naming a missing look layer refuses the install (exit 2), nothing created" bash -c "[ '$ART_RC' -eq 2 ] && [ \"\$(cd '$ART_HOME' && find . | sort)\" = \"\$(cat <<'EOF'
$art_before
EOF
)\" ]"
printf 'picture looks/helmet/layer.png\n' > "$ART_REPO/art/looks/helmet/layer.png"

# A path the installer would write outside art/ or under a name it cannot keep is refused, not copied. Each of these files EXISTS in the
# source (so a refusal comes from the path rules and not from a missing file), except the glob, which no file can be named by.
mkdir -p "$ART_REPO/art/motions/a b" || exit 2
printf 'x\n' > "$ART_REPO/escape.png"; printf 'x\n' > "$ART_REPO/art/motions/a b/000.png"; printf 'x\n' > "$ART_REPO/art/top.png"
unsafe_ok=1
for bad in "../escape.png" "/etc/abs.png" "motions/a b/000.png" "motions/./A1-thinking/000.png" "motions//A1-thinking/000.png" "top.png" 'motions/A1-thinking/*.png'; do
  write_art_atlas "$ART_REPO/art/clawd-atlas.json" "${art_named[@]}" "$bad"
  art_cli install
  [ "$ART_RC" -eq 2 ] && [ "$(art_tree)" = "$art_before" ] || { unsafe_ok=0; echo "not refused cleanly: $bad (rc $ART_RC)"; }
done
check "art fixture: unsafe or unusable atlas paths are refused (exit 2) and nothing is created" test "$unsafe_ok" = 1
# A v1-style atlas (pose frames only) still installs, with no motions or looks directory.
write_art_atlas "$ART_REPO/art/clawd-atlas.json" frames/idle_0.png frames/blink_0.png
art_cli install
check "art fixture: a catalog that names only pose frames installs (v1 shape)" test "$ART_RC" -eq 0
check "art fixture: ... and installs no motions or looks directory" test ! -e "$ART_ROOT/art/motions" -a ! -e "$ART_ROOT/art/looks"
art_cli uninstall
check "art fixture: ... and one uninstall removes it" bash -c "[ '$ART_RC' -eq 0 ]"
# The focus-violation ledger goes with the install, and uninstall says how many violations it held before the file goes.
art_cli install
ART_LEDGER="$ART_ROOT/focus-violations.log"
printf '%s\n' 'BOOT 1792000000.000001 pid=4 counter=0 violations=0' '1792000001.000002 VIOLATION n=1 pid=4 trigger=launch notification=NSWindowDidBecomeKeyNotification' '1792000002.000003 VIOLATION n=2 pid=4 trigger=click notification=NSApplicationDidBecomeActiveNotification' >> "$ART_LEDGER"
ledger_born="$(sed -n '1s/^LEDGER 1 born=\([0-9]*\) how=.*$/\1/p' "$ART_LEDGER")"
art_cli uninstall
art_after="$(art_tree)"
check "uninstall removes the ledger and prints its violation count and birth first" bash -c "[ '$ART_RC' -eq 0 ] && [ ! -e '$ART_LEDGER' ] && [ ! -e '$ART_LEDGER.partial' ]"
check "... and the tree after that uninstall equals the tree before the install" test "$art_after" = "$art_before"
check "the ledger header carried a birth epoch to compare" test -n "$ledger_born"
check "... the line says: focus violations recorded: 2, ledger born <the header's epoch>" contains "$ART_OUT" "focus violations recorded: 2, ledger born $ledger_born"
stop_here 2b

# ---- 3. start, stop, size, helmet, status -----------------------------------------------------------------
: > "$STUB_LOG"
"$CLI_BASH" "$CLI" start >/dev/null 2>&1; check "start exits 0" test "$?" -eq 0
uid="$(id -u)"
check "start bootstraps the plist then kickstarts the label" bash -c "[ \"\$(sed -n 1p '$STUB_LOG')\" = 'launchctl list com.tomtim.clawd-pet' ] && grep -qxF 'launchctl bootstrap gui/$uid $PLIST' '$STUB_LOG' && grep -qxF 'launchctl kickstart gui/$uid/com.tomtim.clawd-pet' '$STUB_LOG' && [ \$(grep -n bootstrap '$STUB_LOG' | cut -d: -f1) -lt \$(grep -n kickstart '$STUB_LOG' | cut -d: -f1) ]"
out="$("$CLI_BASH" "$CLI" status 2>&1)"
check "status shows the loaded service and its pid" bash -c "printf '%s' '$out' | grep -q 'service: loaded' && printf '%s' '$out' | grep -q 'pid: 4242'"
check "start never used open" test ! -s "$STUB_OPEN_LOG"
# The running agent (here: a stand-in that reports appliedGeneration) confirms each setting; the real applier is the agent's SettingsWatcher.
"$STUBS/status-writer" "$ROOT" 0 >/dev/null 2>&1 & sw=$!; holders+=("$sw"); disown "$sw" 2>/dev/null
: > "$STUB_LOG"
"$CLI_BASH" "$CLI" size 2 >/dev/null 2>&1; check "size 2 accepted" test "$?" -eq 0
check "size 2 stored" num_eq "$(plist_value scale "$ROOT/control.json")" 2
check "a size change no longer restarts the agent (settings apply live)" bash -c "! grep -E 'kickstart|bootout|bootstrap' '$STUB_LOG'"
"$CLI_BASH" "$CLI" size 7 >/dev/null 2>&1; check "size 7 rejected with exit 2" test "$?" -eq 2
check "rejected size left control unchanged" num_eq "$(plist_value scale "$ROOT/control.json")" 2
"$CLI_BASH" "$CLI" size 1.5 >/dev/null 2>&1; check "size 1.5 accepted" num_eq "$(plist_value scale "$ROOT/control.json")" 1.5
"$CLI_BASH" "$CLI" size 0.75 >/dev/null 2>&1; check "size 0.75 accepted" test "$?" -eq 0
check "size 0.75 stored" num_eq "$(plist_value scale "$ROOT/control.json")" 0.75
"$CLI_BASH" "$CLI" size 0.5 >/dev/null 2>&1; check "size 0.5 stored" num_eq "$(plist_value scale "$ROOT/control.json")" 0.5
"$CLI_BASH" "$CLI" size 0.6 >/dev/null 2>&1; check "size 0.6 rejected with exit 2" test "$?" -eq 2
check "rejected size 0.6 left control unchanged" num_eq "$(plist_value scale "$ROOT/control.json")" 0.5
check "the usage line lists 0.5 and 0.75" bash -c "'$CLI_BASH' '$CLI' help 2>&1 | grep -qF 'N is 0.5, 0.75, 1, 1.5, 2, 3 or 4 (1 is 48 pt'"
"$CLI_BASH" "$CLI" helmet on >/dev/null 2>&1; check "helmet on stored" test "$(plist_value helmet "$ROOT/control.json")" = "true"
"$CLI_BASH" "$CLI" helmet maybe >/dev/null 2>&1; check "helmet maybe rejected" test "$?" -eq 2
"$CLI_BASH" "$CLI" helmet off >/dev/null 2>&1; check "helmet off stored" test "$(plist_value helmet "$ROOT/control.json")" = "false"
kill "$sw" 2>/dev/null; wait "$sw" 2>/dev/null
minute_ago="$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
printf '{"focusViolations":3,"wakeCount":2,"displayChangeCount":0,"lastEvent":"%s","scene":"idle","sourceBEnabled":false,"idleBudgetMode":false}\n' "$minute_ago" > "$ROOT/status.json"
out="$("$CLI_BASH" "$CLI" status 2>&1)"; rc=$?
check "status accepts an older agent without scheduler status fields" test "$rc" -eq 0
check "older status omits the quiet line" lacks "$out" "quiet:"
check "older status omits the next look due line" lacks "$out" "next look change due:"
check "status prints the activation/key/main count" contains "$out" "activation/key/main events since install: 3"
check "status prints observed wake coverage" contains "$out" "wake coverage: 2 observed"
check "status keeps display-change at not yet observed" contains "$out" "display-change coverage: not yet observed"
check "status prints the age of the last parsed event" contains "$out" "last parsed event: $minute_ago ("
check "status prints source B disabled" contains "$out" "release hint (source B): disabled"
printf '%s\n' '{"focusViolations":0,"quiet":"exam-browser","nextLookChange":1800000123.75}' > "$ROOT/status.json"
out="$(TZ=America/Chicago "$CLI_BASH" "$CLI" status 2>&1)"; rc=$?
check "status with scheduler fields exits 0" test "$rc" -eq 0
check "status prints the exam quiet reason" contains "$out" "quiet: exam-browser"
due_local="$(TZ=America/Chicago date -r 1800000123 '+%Y-%m-%d %H:%M:%S %Z')"
check "status prints the scheduler due epoch in local time" contains "$out" "next look change due: $due_local"
printf '%s\n' '{"focusViolations":0,"quiet":"none"}' > "$ROOT/status.json"
out="$("$CLI_BASH" "$CLI" status 2>&1)"
check "status prints none when no quiet reason is active" contains "$out" "quiet: none"
check "status with no due threshold omits its line" lacks "$out" "next look change due:"
: > "$STUB_LOG"
"$CLI_BASH" "$CLI" stop >/dev/null 2>&1; check "stop exits 0" test "$?" -eq 0
check "stop boots the label out" grep -qxF "launchctl bootout gui/$uid/com.tomtim.clawd-pet" "$STUB_LOG"
check "status after stop says not loaded" contains "$("$CLI_BASH" "$CLI" status 2>&1)" "service: not loaded"
stop_here 3

# ---- 3a. settings: one writer path (the lock, the atomic replace, the generation) and the wait for the running agent ------------------
# Spec 5.1. Every setting is written by the same code: exclusive flock on $ROOT/control.lock held across read-modify-write, then a rename
# of control.json.partial over control.json. `generation` goes up by one per write. The CLI then waits up to 2 s for the agent's
# appliedGeneration in status.json: exit 0 applied (or the agent is not running), 3 saved but not confirmed, 2 invalid input.
CONTROL_JSON="$ROOT/control.json"
jx() { /usr/bin/plutil -extract "$1" raw -o - "$CONTROL_JSON" 2>/dev/null; }
jj() { /usr/bin/plutil -extract "$1" json -o - "$CONTROL_JSON" 2>/dev/null; }
inode() { /usr/bin/stat -f %i "$1"; }
ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)'; }
run_cli() { OUT="$("$CLI_BASH" "$CLI" "$@" 2>&1)"; RC=$?; }
within() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; } # value, low, high
is_loaded_now() { [ -f "$STUB_STATE" ]; }

# the agent is not running (stopped above): a setting is saved and applies at the next start
lock_ino="$(inode "$ROOT/control.lock")"; ctl_ino="$(inode "$CONTROL_JSON")"; g="$(jx generation)"
run_cli walk off
check "walk off with the agent not running exits 0" test "$RC" -eq 0
check "... and says it was saved and applies at the next start" contains "$OUT" "saved; applies at the next start"
check "... and names the generation" contains "$OUT" "generation $((g + 1))"
check "walk off is stored as the boolean false" test "$(jx walk)" = false
check "walk off raised generation by exactly 1" test "$(jx generation)" = "$((g + 1))"
check "control.json was replaced by a rename (a new inode)" test "$(inode "$CONTROL_JSON")" != "$ctl_ino"
check "control.lock is the same file after a write (same inode, never replaced)" test "$(inode "$ROOT/control.lock")" = "$lock_ino"
check "no control.json.partial is left behind" test ! -e "$ROOT/control.json.partial"
check "the v1 keys survived the write" bash -c "[ \"\$(/usr/bin/plutil -extract releaseHintsEnabled raw -o - '$CONTROL_JSON')\" = false ] && [ \"\$(/usr/bin/plutil -extract selectedInputKeyPath raw -o - '$CONTROL_JSON')\" = nativeMicrophone.id ]"

# every command and every value
run_cli walk on;            check "walk on" test "$RC" -eq 0 -a "$(jx walk)" = true
for level in off quiet normal lively; do
  run_cli motion "$level";  check "motion $level" test "$RC" -eq 0 -a "$(jx motion)" = "$level"
done
for h in 2h 3h 4h; do
  run_cli look-every "$h";  check "look-every $h" test "$RC" -eq 0 -a "$(jx lookEveryHours)" = "${h%h}"
done
run_cli look-every 3;       check "look-every 3 (without the h)" test "$RC" -eq 0 -a "$(jx lookEveryHours)" = 3
run_cli chat view stream;   check "chat view stream" test "$RC" -eq 0 -a "$(jx chatView)" = stream
run_cli chat view terminal; check "chat view terminal" test "$RC" -eq 0 -a "$(jx chatView)" = terminal
run_cli chat view chat;     check "chat view chat" test "$RC" -eq 0 -a "$(jx chatView)" = chat
run_cli chat queue off;     check "chat queue off" test "$RC" -eq 0 -a "$(jx chatQueueFollowUps)" = false
run_cli chat queue on;      check "chat queue on" test "$RC" -eq 0 -a "$(jx chatQueueFollowUps)" = true
# chat folder PATH writes chatFolder and no other key but the generation (M-4); the path is a folder that exists
keys_but() { # the control file as plutil prints it (keys sorted) without the keys named here
  local f; f="$STAGE/keys-but.$$"; cp "$CONTROL_JSON" "$f"; for k in "$@"; do /usr/bin/plutil -remove "$k" "$f" 2>/dev/null; done
  /usr/bin/plutil -p "$f"; rm -f "$f"
}
mkdir -p "$STAGE/chat-folder"
folder_before="$(keys_but chatFolder generation)"
run_cli chat folder "$STAGE/chat-folder"
check "chat folder writes chatFolder" test "$RC" -eq 0 -a "$(jx chatFolder)" = "$STAGE/chat-folder"
check "chat folder changed no other key but the generation" test "$(keys_but chatFolder generation)" = "$folder_before"
run_cli chat folder "$STAGE/chat-folder" extra;  check "chat folder with an extra word exits 2" test "$RC" -eq 2
# SA4: each chat verb writes its own key and changes no other key but the generation (M-4).
chat_row() { # label, key, expected raw value, then the verb's words
  local label="$1" key="$2" want="$3" before; shift 3
  before="$(keys_but "$key" generation)"
  run_cli chat "$@"
  check "chat $label writes $key" test "$RC" -eq 0 -a "$(jx "$key")" = "$want"
  check "chat $label changed no other key but $key and the generation" test "$(keys_but "$key" generation)" = "$before"
}
full_screen_row() { # label, expected raw value, then the verb's word
  local label="$1" want="$2" before; shift 2
  before="$(keys_but overFullScreen generation)"
  run_cli full-screen "$@"
  check "full-screen $label writes overFullScreen" test "$RC" -eq 0 -a "$(jx overFullScreen)" = "$want"
  check "full-screen $label changed no other key but overFullScreen and the generation" test "$(keys_but overFullScreen generation)" = "$before"
}
full_screen_row "on" true on
full_screen_row "off" false off
chat_row "off" chat false off
chat_row "on" chat true on
chat_row "permissions bypass" chatPermissions bypass permissions bypass
chat_row "permissions deny" chatPermissions deny permissions deny
chat_row "model sonnet" chatModel sonnet model sonnet
chat_row "model claude-opus-4[1m]" chatModel 'claude-opus-4[1m]' model 'claude-opus-4[1m]'
chat_row "claude (absolute)" chatClaude /opt/homebrew/bin/claude claude /opt/homebrew/bin/claude
chat_row "claude (~/)" chatClaude '~/.local/bin/claude' claude '~/.local/bin/claude'
chat_row "claude (~)" chatClaude '~' claude '~'
run_cli chat model default
check "chat model default takes chatModel out" test "$RC" -eq 0 -a -z "$(jx chatModel)"
check "... and the other chat keys stay" test "$(jx chat)" = true -a "$(jx chatPermissions)" = deny -a "$(jx chatClaude)" = '~'
run_cli chat model default
check "chat model default with no chatModel is still exit 0" test "$RC" -eq 0
run_cli chat claude /opt/homebrew/bin/claude
long_model="$(printf 'a%.0s' $(seq 1 64))"
run_cli chat model "$long_model"
check "chat model of 64 letters is accepted" test "$RC" -eq 0 -a "$(jx chatModel)" = "$long_model"
run_cli chat model default
run_cli bubble off;         check "bubble off" test "$RC" -eq 0 -a "$(jx bubble)" = false
run_cli bubble on;          check "bubble on" test "$RC" -eq 0 -a "$(jx bubble)" = true
run_cli helmet on;          check "helmet on (v1 key)" test "$RC" -eq 0 -a "$(jx helmet)" = true
run_cli helmet off;         check "helmet off (v1 key)" test "$RC" -eq 0 -a "$(jx helmet)" = false
for sz in 0.5 0.75 1 1.5 2 3 4; do
  run_cli size "$sz";       check "size $sz" test "$RC" -eq 0; check "size $sz is stored" num_eq "$(jx scale)" "$sz"
done
now_s="$(date +%s)"
run_cli hide;               check "hide with no minutes hides for 60 minutes" within "$(( $(jx hiddenUntil) - now_s ))" 3590 3610
run_cli hide 5;             check "hide 5 hides for 5 minutes" within "$(( $(jx hiddenUntil) - $(date +%s) ))" 290 300
run_cli hide 007;           check "hide 007 reads as 7 minutes" within "$(( $(jx hiddenUntil) - $(date +%s) ))" 410 420
run_cli hide 10080;         check "hide 10080 (one week) is the longest timed hide" within "$(( $(jx hiddenUntil) - $(date +%s) ))" 604790 604800
run_cli hide 0;             check "hide 0 hides until show (-1)" test "$RC" -eq 0 -a "$(jx hiddenUntil)" = -1
run_cli show;               check "show clears the hide (0)" test "$RC" -eq 0 -a "$(jx hiddenUntil)" = 0

# look random|ID (spec 5.1, the verb the menu's Look row runs): an id is one of the looks of the installed atlas; random takes the pin out
look_count="$(/usr/bin/plutil -extract looks raw -o - "$ROOT/art/clawd-atlas.json" 2>/dev/null)"
look_ids=()
for ((li = 0; li < look_count; li++)); do look_ids+=("$(/usr/bin/plutil -extract "looks.$li.id" raw -o - "$ROOT/art/clawd-atlas.json")"); done
check "the installed atlas has looks to pin (the verb reads them from the installed art)" test "${#look_ids[@]}" -ge 4
check "... plain, helmet and sunglasses among them" bash -c "[ \"\$1\" = plain ] && [[ ' ${look_ids[*]} ' == *' helmet '* ]] && [[ ' ${look_ids[*]} ' == *' sunglasses '* ]]" _ "${look_ids[0]}"
for id in "${look_ids[@]}"; do
  g="$(jx generation)"
  run_cli look "$id"
  check "look $id exits 0" test "$RC" -eq 0
  check "look $id raised generation by exactly 1" test "$(jx generation)" = "$((g + 1))"
  if [ "$id" = helmet ]; then
    check "look helmet pins the helmet and switches the v1 helmet key on (so a later helmet off is a real way back to plain)" test "$(jx helmet)" = true -a "$(jx lookPin)" = helmet
  else
    check "look $id stores the pin as a string" test "$(jx lookPin)" = "$id"
  fi
done
run_cli look sunglasses
check "look sunglasses says it was saved and applies at the next start (the agent is not running)" contains "$OUT" "saved; applies at the next start"
run_cli look random
check "look random exits 0, takes the pin out and switches the helmet key off" test "$RC" -eq 0 -a -z "$(jx lookPin)" -a "$(jx helmet)" = false
g="$(jx generation)"; run_cli look random
check "look random again is a write like any other (generation +1)" test "$RC" -eq 0 -a "$(jx generation)" = "$((g + 1))"
# `helmet on|off` stays the v1 alias of a pin even beside an explicit pin (the agent lets a pin win over the helmet key)
run_cli look sunglasses; run_cli helmet on
check "helmet on after a pin takes the pin out and turns the helmet on" test "$RC" -eq 0 -a "$(jx helmet)" = true -a -z "$(jx lookPin)"
run_cli look sunglasses; run_cli helmet off
check "helmet off after a pin takes the pin out and turns the helmet off" test "$RC" -eq 0 -a "$(jx helmet)" = false -a -z "$(jx lookPin)"
run_cli helmet on; run_cli look random
check "look random after helmet on switches the helmet off too (rotation resumes)" test "$RC" -eq 0 -a "$(jx helmet)" = false -a -z "$(jx lookPin)"
run_cli look helmet; run_cli helmet off
check "helmet off after look helmet takes the pin out and turns the helmet key off (the agent then goes back to plain)" test "$RC" -eq 0 -a "$(jx helmet)" = false -a -z "$(jx lookPin)"
run_cli look helmet; run_cli look random
check "look random after look helmet takes the pin out and turns the helmet key off" test "$RC" -eq 0 -a "$(jx helmet)" = false -a -z "$(jx lookPin)"
g="$(jx generation)"; run_cli look coffee; run_cli helmet on
check "a look and the helmet alias are two writes, one generation each" test "$(jx generation)" = "$((g + 2))"
run_cli look random
# a pin that is not a string (a hand-edited file) is taken out too: the key is removed whatever its type (jt reads any type; json would
# refuse a string and a number, so the CLI's own presence test must not be the json one)
jt() { /usr/bin/plutil -extract "$1" xml1 -o - "$CONTROL_JSON" 2>/dev/null; }
for odd in '"coffee"' '["x"]' '{"a":1}' '7' 'true' '1.5'; do
  /usr/bin/plutil -replace lookPin -json "$odd" -o "$STAGE/control.odd" "$CONTROL_JSON" && /bin/mv -f "$STAGE/control.odd" "$CONTROL_JSON"
  check "setup: lookPin holds $odd" test -n "$(jt lookPin)"
  run_cli look random
  check "look random removes a lookPin holding $odd" test "$RC" -eq 0 -a -z "$(jt lookPin)"
done
# look takes the settings lock like every writer (waits for it, then gives up and changes nothing)
( exec 9<"$ROOT/control.lock"; /usr/bin/lockf -s -t 5 9 && exec /bin/sleep 8 ) &
lock_holder=$!; holders+=("$lock_holder")
/bin/sleep 0.4
cp "$CONTROL_JSON" "$STAGE/control.before"
look_lock_out="$(CLAWD_CONTROL_LOCK_WAIT_S=1 "$CLI_BASH" "$CLI" look sunglasses 2>&1)"; look_lock_rc=$?
check "look sunglasses waits for control.lock and gives up with exit 2 while it is held" test "$look_lock_rc" -eq 2
check "... naming the lock and saying nothing was changed" bash -c "[[ \"\$1\" == *control.lock* && \"\$1\" == *'nothing was changed'* ]]" _ "$look_lock_out"
check "... and control.json is byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
look_lock_out="$(CLAWD_CONTROL_LOCK_WAIT_S=1 "$CLI_BASH" "$CLI" look random 2>&1)"; look_lock_rc=$?
check "look random waits for the lock and gives up too" test "$look_lock_rc" -eq 2
check "... and control.json is byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
# the bubble style chips of the menu write through bubble exclude and include: the same lock, the same refusal
bubble_lock_out="$(CLAWD_CONTROL_LOCK_WAIT_S=1 "$CLI_BASH" "$CLI" bubble exclude 13 2>&1)"; bubble_lock_rc=$?
check "bubble exclude 13 waits for control.lock and gives up with exit 2 while it is held" test "$bubble_lock_rc" -eq 2
check "... and bubbleExcluded unchanged" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
kill "$lock_holder" 2>/dev/null; /bin/sleep 0.2
run_cli look sunglasses
check "after the lock is released look works again" test "$RC" -eq 0 -a "$(jx lookPin)" = sunglasses
run_cli look random
# an id that is not one of the installed looks, or holds a second line: exit 2, control.json byte-identical, same generation
cp "$CONTROL_JSON" "$STAGE/control.before"; g_look="$(jx generation)"
for bad_id in nosuch PLAIN Plain 'plain ' ' plain' 'sun glasses' random2 $'plain\nx' $'x\nplain' $'plain\nsunglasses' $'\nplain' $'plain\n' ''; do
  run_cli look "$bad_id"
  check "look with an invalid id exits 2 ($(printf '%q' "$bad_id"))" test "$RC" -eq 2
  check "... leaves control.json byte-identical ($(printf '%q' "$bad_id"))" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
done
check "invalid looks changed no generation and left no partial" bash -c "[ ! -e '$ROOT/control.json.partial' ] && [ \"\$(/usr/bin/plutil -extract generation raw -o - '$CONTROL_JSON')\" = '$g_look' ]"
run_cli look nosuch
check "an unknown look lists the valid ones" contains "$OUT" "one of: plain helmet"

# the bubble style list: both exclusion keys change under one lock and generation
run_cli bubble exclude 7;   check "bubble exclude 7" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "[7]"
run_cli bubble exclude 3;   check "bubble exclude 3 keeps 7 and sorts" test "$(jj bubbleExcluded)" = "[3,7]"
run_cli bubble exclude 7;   check "excluding 7 again changes nothing in the list" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "[3,7]"
run_cli bubble list
check "bubble list prints 15 style lines" test "$(printf '%s\n' "$OUT" | grep -c '^bubble style ')" = 15
check "... and the on/off state" contains "$OUT" "bubble: on"
check "... marks 3 excluded, 7 excluded and 1 enabled" bash -c "[ \"\$(printf '%s\n' \"\$1\" | grep -cx -e 'bubble style 3: excluded' -e 'bubble style 7: excluded' -e 'bubble style 1: enabled')\" = 3 ]" _ "$OUT"
check "bubble list changes nothing (generation unchanged by the listing)" bash -c "g1=\"\$(/usr/bin/plutil -extract generation raw -o - '$CONTROL_JSON')\"; '$CLI_BASH' '$CLI' bubble list >/dev/null 2>&1; [ \"\$g1\" = \"\$(/usr/bin/plutil -extract generation raw -o - '$CONTROL_JSON')\" ]"
run_cli bubble include 7;   check "bubble include 7" test "$(jj bubbleExcluded)" = "[3]"
run_cli bubble include 9;   check "including a style that is not excluded is fine" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "[3]"
run_cli bubble include 3;   check "bubble include 3 empties the list" test "$(jj bubbleExcluded)" = "[]"
run_cli bubble exclude 15;  check "bubble exclude 15" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "[]" -a "$(jj bubbleExcludedNew)" = "[15]"
run_cli bubble include 15;  check "bubble include 15" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "[]" -a "$(jj bubbleExcludedNew)" = "[]"
# bubble side: below (default), above, left, right; the list ends with the side in force
run_cli bubble list
check "bubble list ends with 'bubble side: below' on a fresh install (no bubbleSide key)" test "$(printf '%s\n' "$OUT" | tail -n 1)" = "bubble side: below" -a -z "$(jx bubbleSide)"
g_side="$(jx generation)"
run_cli bubble side left
check "bubble side left writes bubbleSide and exits 0 after the agent confirms" test "$RC" -eq 0 -a "$(jx bubbleSide)" = left -a "$(jx generation)" -eq "$((g_side + 1))"
run_cli bubble list
check "bubble list now ends with 'bubble side: left'" test "$(printf '%s\n' "$OUT" | tail -n 1)" = "bubble side: left"
for side in right above below; do
  run_cli bubble side "$side"; check "bubble side $side" test "$RC" -eq 0 -a "$(jx bubbleSide)" = "$side"
done
check "a side write keeps the exclusions" test "$(jj bubbleExcluded)" = "[]" -a "$(jj bubbleExcludedNew)" = "[]"
/usr/bin/plutil -replace bubbleSide -string sideways "$CONTROL_JSON"
run_cli bubble list
check "bubble list reads an invalid bubbleSide as below" test "$(printf '%s\n' "$OUT" | tail -n 1)" = "bubble side: below"
# A newline inside the value makes it invalid for the agent too; a bare command substitution would strip it and show "above".
/usr/bin/plutil -replace bubbleSide -json '"above\n"' "$CONTROL_JSON"
run_cli bubble list
check "bubble list reads \"above\\n\" as below, as the agent does" test "$(printf '%s\n' "$OUT" | tail -n 1)" = "bubble side: below"
/usr/bin/plutil -remove bubbleSide "$CONTROL_JSON"
# aqua follow|ignore|auto: stored as a string; the status line shows the agent's resolved mode and the stored setting
g_aqua="$(jx generation)"
run_cli aqua ignore
check "aqua ignore writes \"aqua\":\"ignore\" and exits 0 after the agent confirms" test "$RC" -eq 0 -a "$(jx aqua)" = ignore -a "$(jx generation)" -eq "$((g_aqua + 1))"
check "aqua ignore is a string in the file" grep -q '"aqua" *: *"ignore"' "$CONTROL_JSON"
for mode in follow auto ignore; do run_cli aqua "$mode"; check "aqua $mode" test "$RC" -eq 0 -a "$(jx aqua)" = "$mode"; done
cp "$CONTROL_JSON" "$STAGE/control.before"
run_cli aqua bogus
check "aqua bogus exits 2" test "$RC" -eq 2
check "... names the accepted words" contains "$OUT" "aqua takes follow, ignore or auto"
check "... and leaves control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
cp "$ROOT/status.json" "$STAGE/status.before" 2>/dev/null
printf '%s\n' '{"focusViolations":0,"aquaMode":"ignore"}' > "$ROOT/status.json"
out="$("$CLI_BASH" "$CLI" status 2>&1)"
check "status prints the resolved aqua mode and the stored setting" contains "$out" "aqua: ignore (setting ignore)"
printf '%s\n' '{"focusViolations":0}' > "$ROOT/status.json"
out="$("$CLI_BASH" "$CLI" status 2>&1)"
check "status of an agent that reports no mode says unknown" contains "$out" "aqua: unknown (setting ignore)"
/usr/bin/plutil -replace aqua -json '"ignore\n"' "$CONTROL_JSON"
out="$("$CLI_BASH" "$CLI" status 2>&1)"
check "status reads \"ignore\\n\" as the agent does: invalid, so auto" contains "$out" "aqua: unknown (setting auto)"
[ -f "$STAGE/status.before" ] && cp "$STAGE/status.before" "$ROOT/status.json"
/usr/bin/plutil -remove aqua "$CONTROL_JSON"
# SA6: aqua react on|off writes aquaReact and no other key but the generation (M-4). The agent is not running here, so it applies at the next start.
react_before="$(keys_but aquaReact generation)"
run_cli aqua react off
check "aqua react off writes aquaReact false and exits 0" test "$RC" -eq 0 -a "$(jx aquaReact)" = false
check "aqua react off changed no other key but aquaReact and the generation" test "$(keys_but aquaReact generation)" = "$react_before"
run_cli aqua react on
check "aqua react on writes aquaReact true and exits 0" test "$RC" -eq 0 -a "$(jx aquaReact)" = true
check "aqua react on changed no other key but aquaReact and the generation" test "$(keys_but aquaReact generation)" = "$react_before"
/usr/bin/plutil -remove aquaReact "$CONTROL_JSON"
for change in "exclude 13" "exclude 4" "exclude 14" "exclude 15" "include 4" "include 13" "include 14" "include 15"; do
  case "$change" in
    "exclude 13") old_expected='[]'; new_expected='[13]' ;;
    "exclude 4") old_expected='[4]'; new_expected='[13]' ;;
    "exclude 14") old_expected='[4]'; new_expected='[13,14]' ;;
    "exclude 15") old_expected='[4]'; new_expected='[13,14,15]' ;;
    "include 4") old_expected='[]'; new_expected='[13,14,15]' ;;
    "include 13") old_expected='[]'; new_expected='[14,15]' ;;
    "include 14") old_expected='[]'; new_expected='[15]' ;;
    "include 15") old_expected='[]'; new_expected='[]' ;;
  esac
  g_bubble="$(jx generation)"
  run_cli bubble $change
  check "bubble rollback sequence keeps both keys valid after $change" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = "$old_expected" -a "$(jj bubbleExcludedNew)" = "$new_expected" -a "$(jx generation)" -eq "$((g_bubble + 1))"
  if [ "$change" = "exclude 4" ]; then
    run_cli bubble list
    check "bubble list reads the union of both keys" test "$(printf '%s\n' "$OUT" | grep -cx -e 'bubble style 4: excluded' -e 'bubble style 13: excluded')" = 2
  fi
done

# A malformed key is empty as a whole, while the other key still applies; the next edit repairs both arrays.
for bad in '["13"]' '[4,"5"]' '[4,16]' '[4,true]' '[4,4.5]' '4' '{"style":4}'; do
  /usr/bin/plutil -replace bubbleExcluded -json "$bad" "$CONTROL_JSON"
  /usr/bin/plutil -replace bubbleExcludedNew -json '[14]' "$CONTROL_JSON"
  run_cli bubble list
  check "bubble list rejects the entire invalid old exclusion key: $bad" test "$RC" -eq 0 -a "$(printf '%s\n' "$OUT" | grep ': excluded$')" = 'bubble style 14: excluded'
  run_cli bubble exclude 3
  check "bubble edit repairs the invalid old key and keeps the new key: $bad" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = '[3]' -a "$(jj bubbleExcludedNew)" = '[14]'
done
for bad in '["13"]' '[13,16]' '[13,true]' '[13,13.5]' '[12]' 'null'; do
  /usr/bin/plutil -replace bubbleExcluded -json '[4]' "$CONTROL_JSON"
  /usr/bin/plutil -replace bubbleExcludedNew -json "$bad" "$CONTROL_JSON"
  run_cli bubble list
  check "bubble list rejects the entire invalid new exclusion key: $bad" test "$RC" -eq 0 -a "$(printf '%s\n' "$OUT" | grep ': excluded$')" = 'bubble style 4: excluded'
  run_cli bubble include 4
  check "bubble edit repairs the invalid new key: $bad" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = '[]' -a "$(jj bubbleExcludedNew)" = '[]'
done
/usr/bin/plutil -replace bubbleExcluded -json '[4,4.0,4e0]' "$CONTROL_JSON"
/usr/bin/plutil -replace bubbleExcludedNew -json '[13,13.0]' "$CONTROL_JSON"
run_cli bubble list
check "bubble list accepts whole numeric values and removes duplicates" test "$(printf '%s\n' "$OUT" | grep -c ': excluded$')" = 2
run_cli bubble include 4
run_cli bubble include 13
# At least one of styles 1-12 stays enabled, so bubbleExcluded never holds all twelve: a previous build reads it as this one does.
for n in 1 2 3 4 5 6 7 8 9 10 11 13 14 15; do "$CLI_BASH" "$CLI" bubble exclude "$n" >/dev/null 2>&1; done
check "fourteen styles excluded, style 12 left" test "$(jj bubbleExcluded)" = "[1,2,3,4,5,6,7,8,9,10,11]" -a "$(jj bubbleExcludedNew)" = "[13,14,15]"
cp "$CONTROL_JSON" "$STAGE/control.before"
run_cli bubble exclude 12
check "excluding the last of styles 1-12 is refused (exit 2)" test "$RC" -eq 2
check "... and says why" contains "$OUT" "cannot exclude every one of styles 1-12; style 12 stays enabled"
check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
for n in 1 2 3 4 5 6 7 8 9 10 11 13 14 15; do "$CLI_BASH" "$CLI" bubble include "$n" >/dev/null 2>&1; done
check "all styles included again" test "$(jj bubbleExcluded)" = "[]" -a "$(jj bubbleExcludedNew)" = "[]"
/usr/bin/plutil -replace bubbleExcluded -json '[1,2,3,4,5,6,7,8,9,10,11,12]' "$CONTROL_JSON"
/usr/bin/plutil -replace bubbleExcludedNew -json '[13,14,15]' "$CONTROL_JSON"
run_cli bubble list
check "bubble list voids an old key that holds all twelve and keeps the new key" test "$(printf '%s\n' "$OUT" | grep -c ': enabled$')" = 12 -a "$(printf '%s\n' "$OUT" | grep ': excluded$' | tr '\n' ' ')" = "bubble style 13: excluded bubble style 14: excluded bubble style 15: excluded "
run_cli bubble exclude 4
check "bubble edit repairs an old key that held all twelve" test "$RC" -eq 0 -a "$(jj bubbleExcluded)" = '[4]' -a "$(jj bubbleExcludedNew)" = '[13,14,15]'
run_cli bubble include 4
for n in 13 14 15; do "$CLI_BASH" "$CLI" bubble include "$n" >/dev/null 2>&1; done

# invalid input: exit 2, control.json byte-identical, no partial, generation unchanged
cp "$CONTROL_JSON" "$STAGE/control.before"; g_before="$(jx generation)"
bad_inputs=("walk maybe" "walk" "walk on extra" "motion fast" "motion" "motion quiet extra" "look-every 5h" "look-every 1" "look-every 2hours" "look-every" "look-every 02h"
  "size 7" "size" "size 1.25" "size 0" "helmet maybe" "helmet" "bubble" "bubble sideways" "bubble exclude" "bubble exclude 0" "bubble exclude 16" "bubble exclude x"
  "bubble exclude 01" "bubble include 99" "bubble include" "bubble on extra" "bubble exclude 3 4" "bubble side" "bubble side up" "bubble side LEFT" "bubble side lefty" "bubble side left right" "bubble side below extra" "aqua bogus" "aqua" "aqua FOLLOW" "aqua follow extra" "aqua auto extra" "aqua ignore extra" "aqua react" "aqua react maybe" "aqua react On" "aqua react follow" "aqua react on extra" "full-screen" "full-screen maybe" "full-screen On" "full-screen on extra" "hide abc" "hide -5" "hide 1.5" "hide 10081" "hide 99999999999999999999"
  "hide 1 2" "show now" "chat" "chat view" "chat view nonsense" "chat view Terminal" "chat view terminal extra" "chat bogus" "chat queue" "chat queue maybe" "chat queue On" "chat queue on extra"
  "chat folder" "chat folder ." "chat folder relative/path" "chat folder /nonexistent-clawd-folder-for-the-test" "chat folder /etc/hosts" "chat folder / extra"
  "chat on extra" "chat off extra" "chat on off" "chat On" "chat permissions" "chat permissions ask" "chat permissions Deny" "chat permissions deny extra" "chat permissions bypass extra"
  "chat model" "chat model bad/name" "chat model sonnet!" "chat model default extra" "chat model two words"
  "chat claude" "chat claude claude" "chat claude relative/claude" "chat claude ./claude" "chat claude ~user/claude" "chat claude ~x" "chat claude /a /b")
for bad in "${bad_inputs[@]}"; do
  # shellcheck disable=SC2086
  run_cli $bad
  check "invalid '$bad' exits 2" test "$RC" -eq 2
  check "invalid '$bad' left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
done
# the invalid forms a word split cannot spell: a space, a newline, a control character, a non-ASCII letter, and the lengths just over each limit
long_model_bad="$(printf 'a%.0s' $(seq 1 65))"; long_path_ok="/$(printf 'a%.0s' $(seq 1 1023))"; long_path_bad="/$(printf 'a%.0s' $(seq 1 1024))"
for bad_model in "bad name" "$(printf 'a\nb')" "$(printf 'a\tb')" "caf$(printf '\303\251')" "$long_model_bad" ""; do
  run_cli chat model "$bad_model"
  check "invalid chat model (${#bad_model} chars) exits 2" test "$RC" -eq 2
  check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
done
for bad_path in "" "$long_path_bad" "claude" "~root/claude"; do
  run_cli chat claude "$bad_path"
  check "invalid chat claude (${#bad_path} chars) exits 2" test "$RC" -eq 2
  check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
done
check "an invalid chat claude names no path in its text" lacks "$OUT" "~root"
run_cli chat claude "$long_path_bad"
check "... not even the long one" lacks "$OUT" "$long_path_bad"
run_cli chat claude "$long_path_ok"
check "chat claude of exactly 1024 bytes is accepted" test "$RC" -eq 0 -a "$(jx chatClaude)" = "$long_path_ok"
cp "$CONTROL_JSON" "$STAGE/control.before"; g_before="$(jx generation)"
check "invalid input left no control.json.partial and the same generation" bash -c "[ ! -e '$ROOT/control.json.partial' ] && [ \"\$(/usr/bin/plutil -extract generation raw -o - '$CONTROL_JSON')\" = '$g_before' ]"
run_cli hide ""
check "an empty minutes argument is invalid (exit 2), not the default" test "$RC" -eq 2
check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
# SA6-5: an empty word counts as a word, so aqua follow|ignore|auto with an empty third word is refused (as before SA6), and so is aqua react ""
for mode in follow ignore auto react; do
  run_cli aqua "$mode" ""
  check "aqua $mode with an empty third word exits 2" test "$RC" -eq 2
  check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
done
run_cli aqua react on ""
check "aqua react on with an empty fourth word exits 2" test "$RC" -eq 2
check "... and left control.json byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"

# a setting never reverts another: set several keys, then check them all at once
"$CLI_BASH" "$CLI" walk off >/dev/null 2>&1; "$CLI_BASH" "$CLI" motion normal >/dev/null 2>&1; "$CLI_BASH" "$CLI" look-every 2h >/dev/null 2>&1
"$CLI_BASH" "$CLI" bubble off >/dev/null 2>&1; "$CLI_BASH" "$CLI" bubble exclude 5 >/dev/null 2>&1; "$CLI_BASH" "$CLI" helmet on >/dev/null 2>&1
"$CLI_BASH" "$CLI" hide 0 >/dev/null 2>&1; "$CLI_BASH" "$CLI" size 3 >/dev/null 2>&1
check "after eight different writes all eight values stand together" bash -c "[ \"\$(/usr/bin/plutil -extract walk raw -o - '$CONTROL_JSON')\" = false ] && [ \"\$(/usr/bin/plutil -extract motion raw -o - '$CONTROL_JSON')\" = normal ] && [ \"\$(/usr/bin/plutil -extract lookEveryHours raw -o - '$CONTROL_JSON')\" = 2 ] && [ \"\$(/usr/bin/plutil -extract bubble raw -o - '$CONTROL_JSON')\" = false ] && [ \"\$(/usr/bin/plutil -extract bubbleExcluded json -o - '$CONTROL_JSON')\" = '[5]' ] && [ \"\$(/usr/bin/plutil -extract helmet raw -o - '$CONTROL_JSON')\" = true ] && [ \"\$(/usr/bin/plutil -extract hiddenUntil raw -o - '$CONTROL_JSON')\" = -1 ] && [ \"\$(/usr/bin/plutil -extract scale raw -o - '$CONTROL_JSON')\" = 3 ]"
# put the defaults back for the sections below
for c in "walk on" "motion quiet" "look-every 4h" "bubble on" "bubble include 5" "helmet off" "show" "size 1"; do "$CLI_BASH" "$CLI" $c >/dev/null 2>&1; done

# not installed, no lock, damaged file: each refuses and creates nothing
NOHOME="$STAGE/nohome"; mkdir -p "$NOHOME"
out="$(HOME="$NOHOME" "$CLI_BASH" "$CLI" walk off 2>&1)"; rc=$?
check "a setting with nothing installed exits 2" test "$rc" -eq 2
check "... and says it is not installed" contains "$out" "not installed"
check "... and created nothing in HOME" test -z "$(find "$NOHOME" -mindepth 1)"
mv "$ROOT/control.lock" "$STAGE/control.lock.away"
cp "$CONTROL_JSON" "$STAGE/control.before"
run_cli walk off
check "a setting with no control.lock exits 2" test "$RC" -eq 2
check "... and names the lock" contains "$OUT" "control.lock"
check "... a writer never creates the lock file" test ! -e "$ROOT/control.lock"
check "... and control.json is byte-identical" cmp -s "$CONTROL_JSON" "$STAGE/control.before"
mv "$STAGE/control.lock.away" "$ROOT/control.lock"
printf 'not json at all' > "$CONTROL_JSON"; cp "$CONTROL_JSON" "$STAGE/control.damaged"
run_cli walk off
check "a damaged control.json exits 2" test "$RC" -eq 2
check "... says it is damaged" contains "$OUT" "damaged"
check "... and is left byte-identical, with no partial" bash -c "cmp -s '$CONTROL_JSON' '$STAGE/control.damaged' && [ ! -e '$ROOT/control.json.partial' ]"
printf '[1,2]' > "$CONTROL_JSON"; cp "$CONTROL_JSON" "$STAGE/control.damaged"
run_cli walk off
check "a control.json that is not an object exits 2 and stays byte-identical" bash -c "[ '$RC' -eq 2 ] && cmp -s '$CONTROL_JSON' '$STAGE/control.damaged' && [ ! -e '$ROOT/control.json.partial' ]"
cp "$STAGE/control.before" "$CONTROL_JSON"
run_cli walk on
check "after the file is restored the writer works again" test "$RC" -eq 0 -a "$(jx walk)" = true

# a stale partial from a killed writer is overwritten, not an error
printf 'stale leftovers' > "$ROOT/control.json.partial"
run_cli walk off
check "a stale control.json.partial from a killed writer does not stop the next writer" test "$RC" -eq 0 -a "$(jx walk)" = false -a ! -e "$ROOT/control.json.partial"
run_cli walk on

# ---- 3b. the wait for the running agent (appliedGeneration in status.json) ------------------------------------------------------
"$CLI_BASH" "$CLI" start >/dev/null 2>&1
check "the stub agent is loaded and has a pid" bash -c "'$CLI_BASH' '$CLI' status 2>&1 | grep -q 'pid: 4242'"
run_writer() { # delay [max generation]: starts a stand-in applier for $ROOT and records its pid in SW
  rm -f -- "$ROOT/status.json"
  "$STUBS/status-writer" "$ROOT" "$1" ${2:+"$2"} >/dev/null 2>&1 & SW=$!; holders+=("$SW"); disown "$SW" 2>/dev/null
}
stop_writer() { kill "$SW" 2>/dev/null; /bin/sleep 0.1; }
timed_cli() { T0="$(ms)"; run_cli "$@"; T1="$(ms)"; ELAPSED=$((T1 - T0)); }

run_writer 0
g="$(jx generation)"
timed_cli walk off
check "applied at once: exit 0" test "$RC" -eq 0
check "... says applied and names the generation" contains "$OUT" "applied (generation $((g + 1)))"
check "... and returned quickly (well inside 2 s)" test "$ELAPSED" -lt 1800
g="$(jx generation)"
timed_cli look sunglasses
check "look is confirmed like every setting: exit 0 once the agent has applied the generation" test "$RC" -eq 0 -a "$(jx lookPin)" = sunglasses
check "... and says applied and names the generation" contains "$OUT" "look sunglasses: applied (generation $((g + 1)))"
timed_cli look random
check "look random is confirmed too" test "$RC" -eq 0 -a -z "$(jx lookPin)"
stop_writer
run_writer 1.2
timed_cli walk on
check "applied after 1.2 s: still exit 0, and it waited for it" bash -c "[ '$RC' -eq 0 ] && [ '$ELAPSED' -ge 1000 ] && [ '$ELAPSED' -lt 2400 ]"
stop_writer
g="$(jx generation)"
run_writer 3
timed_cli walk off
check "not applied within 2 s: exit 3" test "$RC" -eq 3
check "... after waiting the whole 2 s and not much longer" bash -c "[ '$ELAPSED' -ge 1950 ] && [ '$ELAPSED' -lt 3400 ]"
check "... the message names the generation" contains "$OUT" "generation $((g + 1))"
check "... and says the agent did not confirm it" contains "$OUT" "did not confirm"
check "... and the change was saved anyway" test "$(jx walk)" = false -a "$(jx generation)" = "$((g + 1))"
stop_writer
run_writer 0 "$(jx generation)"
g="$(jx generation)"
timed_cli walk on
check "an applier that has stopped (never reaches the new generation): exit 3" test "$RC" -eq 3
stop_writer
# the agent has already applied a LATER generation (another writer got there first): the wait is satisfied
rm -f -- "$ROOT/status.json"; printf '{"appliedGeneration":%s}\n' "$(( $(jx generation) + 50 ))" > "$ROOT/status.json"
run_cli walk off
check "an appliedGeneration above the written one counts as applied" test "$RC" -eq 0
# an old appliedGeneration, or none, is not a confirmation
printf '{"appliedGeneration":0}\n' > "$ROOT/status.json"
timed_cli walk on
check "appliedGeneration below the written generation is not a confirmation (exit 3)" test "$RC" -eq 3
printf '{"focusViolations":0}\n' > "$ROOT/status.json"
timed_cli walk off
check "a status.json without appliedGeneration is not a confirmation (exit 3)" test "$RC" -eq 3
printf '{"appliedGeneration":"7"}\n' > "$ROOT/status.json"
run_cli walk on
check "a non-numeric appliedGeneration is not a confirmation (exit 3)" test "$RC" -eq 3
rm -f -- "$ROOT/status.json"
run_cli walk off
check "no status.json at all is not a confirmation (exit 3)" test "$RC" -eq 3
"$CLI_BASH" "$CLI" stop >/dev/null 2>&1
rm -f -- "$ROOT/status.json"
run_cli walk on
check "after stop the agent is not running again: exit 0" test "$RC" -eq 0
check "... applies at the next start" contains "$OUT" "applies at the next start"

# ---- 3c. the forced order of two writers (spec 7b): writer B waits for the lock writer A holds, then reads A's file ------------------
FO="$STAGE/forced"; FOH="$FO/home"; FOR="$FOH/Library/Application Support/clawd-pet"
mkdir -p "$FOR" "$FO/shims" || { echo "cannot create $FO"; exit 2; }
# /usr/bin/cc by path: $STUBS, first on PATH here, holds a cc that must never run (install never builds) and exits 99.
/usr/bin/cc -O1 -DOPSHIM_SCRIPT="\"$REPO/Tests/interrupt-shims/op-shim\"" -o "$FO/shims/op-shim-trampoline" "$REPO/Tests/interrupt-shims/op-shim-trampoline.c" || { echo "cannot compile the op-shim trampoline"; exit 2; }
ln -s "$FO/shims/op-shim-trampoline" "$FO/shims/mv"; ln -s "$FO/shims/op-shim-trampoline" "$FO/shims/rm"
printf '%s\n' '{"scale":1,"helmet":false,"generation":0}' > "$FOR/control.json"; : > "$FOR/control.lock"
fo_ino="$(inode "$FOR/control.lock")"; cp "$FOR/control.json" "$FO/control.base"
fo_jx() { /usr/bin/plutil -extract "$1" raw -o - "$FOR/control.json" 2>/dev/null; }
# A: stopped inside its critical section, holding the lock, with its new file written and not yet renamed (its first mv is the rename).
( export HOME="$FOH" PATH="$FO/shims:$PATH" OPSHIM_COUNT="$FO/a.count" OPSHIM_LOG="$FO/a.ops" OPSHIM_WAIT_AT=1 OPSHIM_WAIT_READY="$FO/a.ready" OPSHIM_WAIT_RELEASE="$FO/a.release" OPSHIM_WAIT_MAX=60
  echo 0 > "$FO/a.count"; exec "$CLI_BASH" "$CLI" walk off ) > "$FO/a.out" 2>&1 &
pa=$!; holders+=("$pa")
wait_until 600 test -e "$FO/a.ready"
check "forced order: writer A is inside its critical section (holding the lock, about to rename)" test -e "$FO/a.ready"
check "... A's new file is written beside control.json, which is still the old one" bash -c "[ -f '$FOR/control.json.partial' ] && cmp -s '$FOR/control.json' '$FO/control.base'"
# B starts now and must wait for the lock: it is alive, and control.json is untouched, for as long as A holds.
( export HOME="$FOH"; exec "$CLI_BASH" "$CLI" size 2 ) > "$FO/b.out" 2>&1 &
pb=$!; holders+=("$pb")
/bin/sleep 1.2
check "forced order: B is still waiting 1.2 s after it started (it has not taken the lock)" alive "$pb"
check "... and control.json is byte-identical to before (B changed nothing while A holds the lock)" cmp -s "$FOR/control.json" "$FO/control.base"
check "... and B has no partial of its own to write (the one partial is A's)" bash -c "[ \"\$(/usr/bin/plutil -extract walk raw -o - '$FOR/control.json.partial')\" = false ] && ! /usr/bin/plutil -extract scale raw -o - '$FOR/control.json.partial' | grep -qx 2"
: > "$FO/a.release"
wait "$pa"; rca=$?; wait "$pb"; rcb=$?
check "forced order: A exits 0 after the release" test "$rca" -eq 0
check "forced order: B exits 0 after A released the lock" test "$rcb" -eq 0
check "forced order: both changes are present (B read A's file, not the old one)" bash -c "[ \"\$(/usr/bin/plutil -extract walk raw -o - '$FOR/control.json')\" = false ] && [ \"\$(/usr/bin/plutil -extract scale raw -o - '$FOR/control.json')\" = 2 ]"
check "forced order: generation is 2 (A made 1, B made 2 on top of it)" test "$(fo_jx generation)" = 2
check "forced order: control.lock has the same inode as before (no writer replaced it)" test "$(inode "$FOR/control.lock")" = "$fo_ino"
check "forced order: no partial is left" test ! -e "$FOR/control.json.partial"
# the lock wait is bounded: B gives up (exit 2, changed nothing) when A holds longer than its wait
printf '%s\n' '{"scale":1,"helmet":false,"generation":0}' > "$FOR/control.json"; cp "$FOR/control.json" "$FO/control.base"
rm -f -- "$FO/a.count" "$FO/a.ready" "$FO/a.release"
( export HOME="$FOH" PATH="$FO/shims:$PATH" OPSHIM_COUNT="$FO/a.count" OPSHIM_LOG="$FO/a.ops" OPSHIM_WAIT_AT=1 OPSHIM_WAIT_READY="$FO/a.ready" OPSHIM_WAIT_RELEASE="$FO/a.release" OPSHIM_WAIT_MAX=60
  echo 0 > "$FO/a.count"; exec "$CLI_BASH" "$CLI" walk off ) > "$FO/a2.out" 2>&1 &
pa=$!; holders+=("$pa")
wait_until 600 test -e "$FO/a.ready"
T0="$(ms)"; out="$(HOME="$FOH" CLAWD_CONTROL_LOCK_WAIT_S=1 "$CLI_BASH" "$CLI" size 2 2>&1)"; rcb=$?; T1="$(ms)"
check "lock wait: B gives up with exit 2 when the lock stays held" test "$rcb" -eq 2
check "... after about its 1 s wait" bash -c "[ $((T1 - T0)) -ge 900 ] && [ $((T1 - T0)) -lt 4000 ]"
check "... names the lock" contains "$out" "control.lock"
check "... and says nothing was changed" contains "$out" "nothing was changed"
check "... and control.json is untouched by B" cmp -s "$FOR/control.json" "$FO/control.base"
: > "$FO/a.release"; wait "$pa"; rca=$?
check "lock wait: A finishes normally afterwards" test "$rca" -eq 0 -a "$(fo_jx walk)" = false

# ---- 3d. the race: two writers on different keys at the same moment, 200 times (4 lanes of 50, one fake HOME each) ----------------------
RACE="$STAGE/race"; mkdir -p "$RACE" || exit 2
race_lane() { # lane iterations
  local lane="$1" iterations="$2" h r i pair a b go pa pb rca rcb ok=0 bad=0 gen_ok reader readerpid readerbad
  h="$RACE/lane$lane/home"; r="$h/Library/Application Support/clawd-pet"
  mkdir -p "$r" || { echo "lane $lane: cannot create $r" >> "$RACE/lane$lane.res"; return 1; }
  : > "$r/control.lock"
  local base='{"scale":1,"helmet":false,"selectedInputKeyPath":"nativeMicrophone.id","generation":0}'
  # control.json exists before the reader starts: a file that is not there yet is not a torn one.
  printf '%s\n' "$base" > "$r/control.json.base"; mv -f "$r/control.json.base" "$r/control.json"
  # a reader that must never see a half-written control.json: scale is in every version of the file
  # A failed read is judged on a snapshot of the file taken at that moment: a torn file stays torn in the copy ("bad"), a plutil that
  # failed for its own reasons (a process that could not start under load) reads the same copy fine ("transient", reported, not counted).
  ( while :; do
      if ! /usr/bin/plutil -extract scale raw -o - "$r/control.json" >/dev/null 2>&1; then
        cp "$r/control.json" "$RACE/lane$lane.snapshot" 2>/dev/null
        if /usr/bin/plutil -extract scale raw -o - "$RACE/lane$lane.snapshot" >/dev/null 2>&1; then echo transient >> "$RACE/lane$lane.reader"
        else echo bad >> "$RACE/lane$lane.reader"; cat "$RACE/lane$lane.snapshot" >> "$RACE/lane$lane.reader.detail" 2>&1; fi
      fi
      /bin/sleep 0.004
    done ) &
  readerpid=$!
  : > "$RACE/lane$lane.reader"
  i=0
  while [ "$i" -lt "$iterations" ]; do
    printf '%s\n' "$base" > "$r/control.json.base"; mv -f "$r/control.json.base" "$r/control.json"
    go="$RACE/lane$lane/go.$i"
    case $((i % 5)) in
      0) a="walk off"; b="size 2" ;;
      1) a="motion lively"; b="helmet on" ;;
      2) a="bubble exclude 3"; b="bubble exclude 4" ;;
      3) a="hide 5"; b="look-every 2h" ;;
      4) a="walk off"; b="foreign" ;;
    esac
    ( while [ ! -e "$go" ]; do /bin/sleep 0.002; done; export HOME="$h"; exec "$CLI_BASH" "$CLI" $a ) > "$RACE/lane$lane/a.out" 2>&1 & pa=$!
    if [ "$b" = foreign ]; then
      ( while [ ! -e "$go" ]; do /bin/sleep 0.002; done; exec "$STUBS/control-writer" "$r" bubble false ) > "$RACE/lane$lane/b.out" 2>&1 & pb=$!
    else
      ( while [ ! -e "$go" ]; do /bin/sleep 0.002; done; export HOME="$h"; exec "$CLI_BASH" "$CLI" $b ) > "$RACE/lane$lane/b.out" 2>&1 & pb=$!
    fi
    /bin/sleep 0.05; : > "$go"
    wait "$pa"; rca=$?; wait "$pb"; rcb=$?
    gen_ok=0
    [ "$(/usr/bin/plutil -extract generation raw -o - "$r/control.json" 2>/dev/null)" = 2 ] && gen_ok=1
    case $((i % 5)) in
      0) [ "$(/usr/bin/plutil -extract walk raw -o - "$r/control.json")" = false ] && [ "$(/usr/bin/plutil -extract scale raw -o - "$r/control.json")" = 2 ] ;;
      1) [ "$(/usr/bin/plutil -extract motion raw -o - "$r/control.json")" = lively ] && [ "$(/usr/bin/plutil -extract helmet raw -o - "$r/control.json")" = true ] ;;
      2) [ "$(/usr/bin/plutil -extract bubbleExcluded json -o - "$r/control.json")" = "[3,4]" ] ;;
      3) [ "$(/usr/bin/plutil -extract lookEveryHours raw -o - "$r/control.json")" = 2 ] && [ "$(/usr/bin/plutil -extract hiddenUntil raw -o - "$r/control.json")" -gt 0 ] ;;
      4) [ "$(/usr/bin/plutil -extract walk raw -o - "$r/control.json")" = false ] && [ "$(/usr/bin/plutil -extract bubble raw -o - "$r/control.json")" = false ] ;;
    esac
    if [ $? -eq 0 ] && [ "$gen_ok" = 1 ] && [ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ] && [ ! -e "$r/control.json.partial" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "lane $lane iteration $i ($a | $b): rc $rca $rcb, generation $(/usr/bin/plutil -extract generation raw -o - "$r/control.json" 2>/dev/null), $(cat "$r/control.json" 2>/dev/null)" >> "$RACE/lane$lane.res"; fi
    i=$((i + 1))
  done
  kill "$readerpid" 2>/dev/null; wait "$readerpid" 2>/dev/null
  readerbad="$(grep -c '^bad' "$RACE/lane$lane.reader")"
  echo "lane $lane: ok=$ok bad=$bad reader_failures=$readerbad reader_transient=$(grep -c '^transient' "$RACE/lane$lane.reader") lock_inode_same=$([ "$(/usr/bin/stat -f %i "$r/control.lock")" = "$(cat "$RACE/lane$lane.lockino")" ] && echo yes || echo no)" >> "$RACE/lane$lane.sum"
}
lane_pids=()
for lane in 1 2 3 4; do
  mkdir -p "$RACE/lane$lane/home/Library/Application Support/clawd-pet"; : > "$RACE/lane$lane/home/Library/Application Support/clawd-pet/control.lock"
  /usr/bin/stat -f %i "$RACE/lane$lane/home/Library/Application Support/clawd-pet/control.lock" > "$RACE/lane$lane.lockino"
  race_lane "$lane" 50 & lane_pids+=("$!"); holders+=("$!")
done
for p in "${lane_pids[@]}"; do wait "$p"; done
race_ok=0; race_bad=0; race_reader=0; race_locks=0
for lane in 1 2 3 4; do
  line="$(cat "$RACE/lane$lane.sum" 2>/dev/null)"
  race_ok=$((race_ok + $(printf '%s' "$line" | sed -n 's/.*ok=\([0-9]*\).*/\1/p')))
  race_bad=$((race_bad + $(printf '%s' "$line" | sed -n 's/.* bad=\([0-9]*\).*/\1/p')))
  race_reader=$((race_reader + $(printf '%s' "$line" | sed -n 's/.*reader_failures=\([0-9]*\).*/\1/p')))
  printf '%s' "$line" | grep -q 'lock_inode_same=yes' && race_locks=$((race_locks + 1))
  [ -s "$RACE/lane$lane.res" ] && sed 's/^/  race: /' "$RACE/lane$lane.res"
done
echo "clawd-pet-cli.test: race: $race_ok of 200 iterations kept both changes, $race_bad did not, $race_reader torn reads"
check "the race: all 200 iterations (4 lanes x 50, CLI against CLI and against a second implementation of the protocol) kept both changes" test "$race_ok" -eq 200 -a "$race_bad" -eq 0
check "the race: no reader ever saw a half-written control.json" test "$race_reader" -eq 0
check "the race: control.lock kept its inode in every lane" test "$race_locks" -eq 4

stop_here 3a
# ---- 3e. bootout is asynchronous: stop waits for the job to go, up to 10 s in steps of 100 ms ------------------------------------------
# (found on Friday: launchctl bootout returns before the job is unloaded, so the first check said "still loaded" and failed closed.)
# The stub keeps the label listed for STUB_BOOTOUT_POLLS `list` calls after the bootout.
polls_after_bootout() { /usr/bin/awk '/^launchctl bootout/ { seen = 1; next } seen && /^launchctl list / { n++ } END { print n + 0 }' "$STUB_LOG"; }
"$CLI_BASH" "$CLI" start >/dev/null 2>&1; : > "$STUB_LOG"
out="$(STUB_BOOTOUT_POLLS=3 "$CLI_BASH" "$CLI" stop 2>&1)"; rc=$?
check "stop waits for a bootout that completes after 3 polls: exit 0" test "$rc" -eq 0
check "... says stopped" contains "$out" "stopped"
check "... listed the label 4 times after the bootout (3 still loaded, then gone)" test "$(polls_after_bootout)" = 4
check "... and the label is gone at the end" test ! -e "$STUB_STATE"
"$CLI_BASH" "$CLI" start >/dev/null 2>&1; : > "$STUB_LOG"
T0="$(ms)"; out="$(STUB_BOOTOUT_POLLS=100000 "$CLI_BASH" "$CLI" stop 2>&1)"; rc=$?; T1="$(ms)"
check "stop fails closed (exit 2) when the job is still loaded after 10 s" test "$rc" -eq 2
check "... after polling for the whole 10 s (100 steps of 100 ms), not less" bash -c "[ $((T1 - T0)) -ge 10000 ] && [ $((T1 - T0)) -lt 60000 ]"
check "... with exactly 101 looks at the label after the bootout (the first, then one per step)" test "$(polls_after_bootout)" = 101
check "... and says the service is still loaded" contains "$out" "still loaded"
out="$(STUB_BOOTOUT_POLLS=0 "$CLI_BASH" "$CLI" stop 2>&1)"; rc=$?
check "a later stop that unloads at once clears it" test "$rc" -eq 0 -a ! -e "$STUB_STATE"
# Only `list` exiting 113 proves the job unloaded; any other failure proves nothing (Codex e40a50: a failed look read as "unloaded"
# let uninstall remove the files while launchd could still start the agent).
"$CLI_BASH" "$CLI" start >/dev/null 2>&1; before_blind="$(snapshot)"
out="$(STUB_LIST_RC=5 STUB_BOOTOUT_POLLS=100000 "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "uninstall refuses (exit 2) while launchctl cannot say whether the job is loaded" test "$rc" -eq 2
check "... removed nothing, the plist included" test "$(snapshot)" = "$before_blind"
check "... and says the files are retained" contains "$out" "files retained"
check "status says the service state is unknown when launchctl list fails" contains "$(STUB_LIST_RC=5 "$CLI_BASH" "$CLI" status 2>&1)" "service: unknown"
out="$(STUB_BOOTOUT_POLLS=0 "$CLI_BASH" "$CLI" stop 2>&1)"; rc=$?
check "... and a stop that launchctl can confirm clears it" test "$rc" -eq 0 -a ! -e "$STUB_STATE"

# ---- 3f. the launcher (item 1 of the Sprint 4a brief): a frozen program the LaunchAgent names; the agent's launch guard still passes ------
# launcher/launcher.c is built once by scripts/build-launcher; the binary and its sha256 record are checked in; install copies and
# verifies them and never builds. The stand-in agent (Tests/stubs/guard-agent.c) makes the launch guard's decision: XPC_SERVICE_NAME
# is the label AND `launchctl list <label>` reports a PID equal to its own pid. The stub launchd (Tests/stubs/launchctl-launch) really
# starts ProgramArguments[0], so what the plist names decides what runs.
LAUNCH_BIN="$REPO/launcher/clawd-pet-launch"; LAUNCH_REC="$REPO/launcher/clawd-pet-launch.sha256"
check "launcher.c, the launcher and its sha256 record are in the repo" bash -c "[ -f '$REPO/launcher/launcher.c' ] && [ -x '$LAUNCH_BIN' ] && [ -f '$LAUNCH_REC' ]"
check "the record is one line: <64 hex digits>, two spaces, clawd-pet-launch" bash -c "[ \"\$(grep -c '' '$LAUNCH_REC')\" = 1 ] && grep -Eqx '[0-9a-f]{64}  clawd-pet-launch' '$LAUNCH_REC'"
check "the checked-in launcher matches its record (scripts/build-launcher --verify)" sh "$REPO/scripts/build-launcher" --verify
check "the launcher is a thin arm64 Mach-O" bash -c "[ \"\$(/usr/bin/lipo -archs '$LAUNCH_BIN')\" = arm64 ]"
check "the launcher carries a valid ad-hoc signature" bash -c "/usr/bin/codesign --verify --strict '$LAUNCH_BIN' && /usr/bin/codesign -dv '$LAUNCH_BIN' 2>&1 | grep -q 'Signature=adhoc'"
check "the launcher has no network, no window and no AppKit in it (libSystem only)" bash -c "[ \"\$(/usr/bin/otool -L '$LAUNCH_BIN' | tail -n +2 | wc -l | tr -d ' ')\" = 1 ] && /usr/bin/otool -L '$LAUNCH_BIN' | grep -q libSystem"
# scripts/build-launcher is exercised in a scratch copy of the repo's scripts/ and launcher/ (it finds the files it writes from its own
# place), so no run of it, mutated or not, can touch the checked-in launcher.
BL="$STAGE/build-repo"; mkdir -p "$BL/scripts" "$BL/launcher" || exit 2
cp "$REPO/scripts/build-launcher" "$BL/scripts/build-launcher"; cp "$REPO/launcher/launcher.c" "$BL/launcher/launcher.c"
bl() { sh "$BL/scripts/build-launcher" "$@"; }
bl_digest() { (cd "$BL/launcher" && /usr/bin/shasum -a 256 launcher.c clawd-pet-launch clawd-pet-launch.sha256 2>/dev/null); }
out="$(bl 2>&1)"; rc=$?
check "build-launcher builds into an empty launcher/ and records the sha256 (exit 0)" test "$rc" -eq 0 -a -x "$BL/launcher/clawd-pet-launch" -a -f "$BL/launcher/clawd-pet-launch.sha256"
check "build-launcher records the sha256 of what it built, in the one-line format" test "$(cat "$BL/launcher/clawd-pet-launch.sha256")" = "$(/usr/bin/shasum -a 256 < "$BL/launcher/clawd-pet-launch" | cut -d' ' -f1)  clawd-pet-launch"
check "build-launcher --verify accepts what it built" bl --verify
check "what it built is a thin arm64 Mach-O with an ad-hoc signature that verifies" bash -c "[ \"\$(/usr/bin/lipo -archs '$BL/launcher/clawd-pet-launch')\" = arm64 ] && /usr/bin/codesign --verify --strict '$BL/launcher/clawd-pet-launch'"
before_bl="$(bl_digest)"
out="$(bl 2>&1)"; rc=$?
check "build-launcher refuses to build over a checked-in launcher (exit 2)" test "$rc" -eq 2
check "... says a new binary is a new background item" contains "$out" "background item"
check "... and changed nothing in launcher/" test "$(bl_digest)" = "$before_bl"
printf 'X' >> "$BL/launcher/clawd-pet-launch"
out="$(bl --verify 2>&1)"; rc=$?
check "build-launcher --verify rejects a launcher that no longer matches its record (exit 2)" test "$rc" -eq 2
printf '%s  clawd-pet-launch\n' 0000000000000000000000000000000000000000000000000000000000000000 > "$BL/launcher/clawd-pet-launch.sha256"
out="$(bl --rebuild 2>&1)"; rc=$?
check "build-launcher --rebuild replaces both on purpose (exit 0)" test "$rc" -eq 0
check "... and the record is the sha256 of what it built" bash -c "[ \"\$(cat '$BL/launcher/clawd-pet-launch.sha256')\" = \"\$(/usr/bin/shasum -a 256 < '$BL/launcher/clawd-pet-launch' | cut -d' ' -f1)  clawd-pet-launch\" ] && sh '$BL/scripts/build-launcher' --verify"
mkdir -p "$STAGE/launcher-scratch" || exit 2
before_bl="$(bl_digest)"
out="$(sh "$REPO/scripts/build-launcher" --scratch "$STAGE/launcher-scratch" 2>&1)"; rc=$?
check "scripts/build-launcher --scratch builds launcher.c into a scratch directory (exit 0)" test "$rc" -eq 0 -a -x "$STAGE/launcher-scratch/clawd-pet-launch"
check "... and leaves only the launcher in the scratch directory" test "$(ls "$STAGE/launcher-scratch")" = clawd-pet-launch
check "... and the checked-in launcher is still the recorded one" sh "$REPO/scripts/build-launcher" --verify
sh "$REPO/scripts/build-launcher" --bogus >/dev/null 2>&1; check "scripts/build-launcher refuses an unknown option (exit 2)" test "$?" -eq 2

# the probe: a native stand-in agent, compiled here (the test may compile; install may not)
GUARD="$STAGE/guard-agent"
/usr/bin/clang -O0 -Wall -Werror -o "$GUARD" "$REPO/Tests/stubs/guard-agent.c" >/dev/null 2>&1; check "the guard stand-in compiles" test -x "$GUARD"

# the launcher on its own: it runs the agent next to it, as that agent, in the same process, with the arguments and the environment
launcher_alone() { # name launcher-file: runs it in <stage>/alone-<name>/ with the probe as its neighbour
  local n="$1" bin="$2" d="$STAGE/alone-$1"
  mkdir -p "$d" || return 1
  cp "$bin" "$d/clawd-pet-launch"; cp "$GUARD" "$d/clawd-pet-agent"; chmod 755 "$d/clawd-pet-launch" "$d/clawd-pet-agent"
  ALONE="$d"
  ( cd "$d"; CLAWD_LAUNCH_CANARY=canary-7 "$d/clawd-pet-launch" first "second word" > "$d/out" 2>&1 & echo $! > "$d/pid"; wait "$(cat "$d/pid")"; echo $? > "$d/rc" )
}
launcher_alone checked-in "$LAUNCH_BIN"
check "alone: the agent next to the launcher ran (exit 0)" test "$(cat "$ALONE/rc")" = 0
check "alone: it ran as the launcher's own pid (an exec, not a fork)" test "$(sed -n 's/^pid=//p' "$ALONE/out")" = "$(cat "$ALONE/pid")"
check "alone: argv[0] is the agent's path" test "$(sed -n 's/^argv0=//p' "$ALONE/out")" = "$(cd "$ALONE" && pwd -P)/clawd-pet-agent"
check "alone: the arguments are passed on" bash -c "grep -qx 'args=2' '$ALONE/out' && grep -qx 'arg1=first' '$ALONE/out' && grep -qx 'arg2=second word' '$ALONE/out'"
check "alone: the environment is inherited" grep -qx "canary=canary-7" "$ALONE/out"
( cd "$ALONE" && ln -s clawd-pet-launch via-link && ./via-link > "$ALONE/out-link" 2>&1 ); check "alone: started through a symlink it still finds the agent beside the real file" grep -q '^argv0=' "$ALONE/out-link"
ALONE_REAL="$(cd "$ALONE" && pwd -P)"
( cd "$ALONE" && ./clawd-pet-launch > "$ALONE/out-rel" 2>&1 ); check "alone: started by a relative path it finds its neighbour" grep -qx "argv0=$ALONE_REAL/clawd-pet-agent" "$ALONE/out-rel"
( cd "$ALONE" && PATH="$ALONE:$PATH" clawd-pet-launch > "$ALONE/out-path" 2>&1 ); check "alone: started by a PATH lookup it finds its neighbour" grep -qx "argv0=$ALONE_REAL/clawd-pet-agent" "$ALONE/out-path"
mkdir -p "$STAGE/alone-bare"; cp "$LAUNCH_BIN" "$STAGE/alone-bare/clawd-pet-launch"
"$STAGE/alone-bare/clawd-pet-launch" >/dev/null 2>&1; check "with no agent beside it the launcher exits 111 and starts nothing" test "$?" -eq 111
mkdir -p "$STAGE/alone-notexec"; cp "$LAUNCH_BIN" "$STAGE/alone-notexec/clawd-pet-launch"; : > "$STAGE/alone-notexec/clawd-pet-agent"
"$STAGE/alone-notexec/clawd-pet-launch" >/dev/null 2>&1; check "with an agent that cannot be executed it exits 111" test "$?" -eq 111
mkdir -p "$STAGE/alone-dir/clawd-pet-agent"; cp "$LAUNCH_BIN" "$STAGE/alone-dir/clawd-pet-launch"
"$STAGE/alone-dir/clawd-pet-launch" >/dev/null 2>&1; check "with a directory where the agent should be it exits 111" test "$?" -eq 111
mkdir -p "$STAGE/alone-elsewhere"; cp "$GUARD" "$STAGE/alone-elsewhere/clawd-pet-agent"; cp "$LAUNCH_BIN" "$STAGE/alone-bare/other-name"
"$STAGE/alone-bare/other-name" >/dev/null 2>&1; check "it looks only beside itself, never at another agent on the machine (exit 111)" test "$?" -eq 111

# the same properties from a fresh build of launcher.c (so a change to the source is seen even though the checked-in binary is frozen)
launcher_alone scratch "$STAGE/launcher-scratch/clawd-pet-launch"
check "scratch build: the agent ran as the launcher's own pid, with argv[0] = the agent's path" bash -c "[ \"\$(sed -n 's/^pid=//p' '$ALONE/out')\" = \"\$(cat '$ALONE/pid')\" ] && grep -qx \"argv0=\$(cd '$ALONE' && pwd -P)/clawd-pet-agent\" '$ALONE/out' && grep -qx 'args=2' '$ALONE/out' && grep -qx 'canary=canary-7' '$ALONE/out'"
mkdir -p "$STAGE/alone-bare2"; cp "$STAGE/launcher-scratch/clawd-pet-launch" "$STAGE/alone-bare2/clawd-pet-launch"
"$STAGE/alone-bare2/clawd-pet-launch" >/dev/null 2>&1; check "scratch build: exits 111 with no agent beside it" test "$?" -eq 111

# the whole path: install -> plist -> stub launchd starts ProgramArguments[0] -> launcher -> stand-in agent -> launch guard
mini_repo() { # dir launcher-file [record-text]: a repo copy with the given launcher and a record for it (or the given record text)
  local d="$1" bin="$2" record="${3:-}"
  mkdir -p "$d/bin" "$d/launchd" "$d/launcher" || return 1
  cp "$CLI" "$d/bin/clawd-pet"; chmod 755 "$d/bin/clawd-pet"
  cp "$REPO/launchd/com.tomtim.clawd-pet.plist.in" "$d/launchd/"
  : > "$d/Package.swift"; ln -s "$REPO/art" "$d/art"
  if [ -n "$bin" ]; then cp "$bin" "$d/launcher/clawd-pet-launch"; fi
  if [ -z "$record" ]; then printf '%s  clawd-pet-launch\n' "$(/usr/bin/shasum -a 256 < "$bin" | cut -d' ' -f1)" > "$d/launcher/clawd-pet-launch.sha256"
  elif [ "$record" != NONE ]; then printf '%s' "$record" > "$d/launcher/clawd-pet-launch.sha256"; fi
}
fresh_home() { # dir -> the shared parents of a real HOME
  mkdir -p "$1/bin" "$1/Library/LaunchAgents" "$1/Library/Application Support" || return 1
}
launch_env() { # home -> runs the rest of the command line with the stub-launchd environment of that home (no interpreter log)
  local h="$1"; shift
  env -u STUB_SHELL_LOG HOME="$h" CLAWD_LAUNCHCTL="$STUBS/launchctl-launch" STUB_LOG="$h.launchctl.calls" STUB_STATE="$h.loaded" \
    STUB_AGENT_EXEC="$h/Library/Application Support/clawd-pet/bin/clawd-pet-agent" STUB_GUARD_LOG="$h.guard.log" CLAWD_LAUNCH_CANARY=canary-7 \
    CLAWD_BUILD_DIR="$h.build" "$@"
}
launcher_scenario() { # name launcher-file -> GH (home), GL (the stand-in's log)
  local n="$1" bin="$2" d="$STAGE/launch-$1"
  mini_repo "$d/repo" "$bin" || return 1
  GH="$d/home"; GL="$GH.guard.log"; fresh_home "$GH" || return 1
  mkdir -p "$GH.build"; cp "$GUARD" "$GH.build/clawd-pet-agent"
  launch_env "$GH" "$CLI_BASH" "$d/repo/bin/clawd-pet" install >"$d/install.out" 2>&1 || return 1
  launch_env "$GH" "$CLI_BASH" "$d/repo/bin/clawd-pet" start >"$d/start.out" 2>&1
  wait_until 300 test -s "$GL"
  return 0
}
guard_field() { sed -n "s/^$1=//p" "$GL"; }

launcher_scenario good "$LAUNCH_BIN"
GROOT="$GH/Library/Application Support/clawd-pet"
check "launcher scenario: the stub launchd started the plist's program (the stand-in answered)" test -s "$GL"
check "launcher scenario: the stand-in's launch guard passes (XPC_SERVICE_NAME is the label and launchctl's PID is its own pid)" test "$(guard_field guard)" = allowed
check "launcher scenario: launchctl's PID is the pid the stub launchd started (the launcher's pid) and is the agent's pid" bash -c "[ \"$(guard_field listed)\" = \"\$(cat '$GH.loaded.pid')\" ] && [ \"$(guard_field pid)\" = \"\$(cat '$GH.loaded.pid')\" ]"
check "launcher scenario: argv[0] of the agent is the installed agent path" test "$(guard_field argv0)" = "$GROOT/bin/clawd-pet-agent"
check "launcher scenario: no arguments reached the agent" test "$(guard_field args)" = 0
check "launcher scenario: the environment of the job reached the agent" bash -c "[ \"$(guard_field xpc)\" = com.tomtim.clawd-pet ] && [ \"$(guard_field canary)\" = canary-7 ]"
check "launcher scenario: the plist's program is the launcher and the launcher is what the stub started" bash -c "[ \"\$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - '$GH/Library/LaunchAgents/com.tomtim.clawd-pet.plist')\" = '$GROOT/bin/clawd-pet-launch' ] && grep -q 'bootstrap' '$GH.launchctl.calls'"
check "launcher scenario: --own-pids (what uninstall uses) lists the running process by the installed agent path: after the exec it IS the agent" bash -c "HOME='$GH' '$AGENT_BIN' --own-pids 2>&1 | grep -q '^PID $(guard_field pid) '"
# stop, then uninstall: the launcher goes with the rest and the tree is the one before the install
agent_pid="$(guard_field pid)"
launch_env "$GH" "$CLI_BASH" "$STAGE/launch-good/repo/bin/clawd-pet" stop >"$STAGE/launch-good/stop.out" 2>&1; check "launcher scenario: stop exits 0" test "$?" -eq 0
check "launcher scenario: the agent process is gone after stop" wait_until 100 bash -c "! kill -0 '$agent_pid' 2>/dev/null"
launch_env "$GH" CLAWD_OWN_PIDS_CHECKER="$STUBS/enumerator-installed" CLAWD_TEST_REAL_AGENT="$AGENT_BIN" "$CLI_BASH" "$STAGE/launch-good/repo/bin/clawd-pet" uninstall >"$STAGE/launch-good/uninstall.out" 2>&1
check "launcher scenario: uninstall exits 0" test "$?" -eq 0
check "launcher scenario: uninstall removed the launcher (and everything else: only the parents are left)" test -z "$(cd "$GH" && find . -mindepth 1 | grep -v -e '^./bin$' -e '^./Library$' -e '^./Library/LaunchAgents$' -e '^./Library/Application Support$')"

# negative control: a launcher that forks and waits instead of exec'ing is refused by the guard (the test can see the difference)
{ printf '#include <sys/wait.h>\n'; sed -e 's|    execv(agent, argv);|    pid_t child = fork(); if (child == 0) { execv(agent, argv); _exit(111); } int status; waitpid(child, \&status, 0); _exit(0);|' "$REPO/launcher/launcher.c"; } > "$STAGE/launcher-forking.c"
/usr/bin/clang -O0 -o "$STAGE/launcher-forking" "$STAGE/launcher-forking.c" >/dev/null 2>&1; check "the forking launcher (a negative control built from launcher.c) compiles" test -x "$STAGE/launcher-forking"
launcher_scenario forking "$STAGE/launcher-forking"
check "negative control: with a launcher that forks, the stand-in's launch guard refuses (PID is the launcher's, not the agent's)" test "$(guard_field guard)" = refused
check "negative control: ... and the pid the stand-in sees differs from launchctl's PID" test "$(guard_field pid)" != "$(guard_field listed)"
launch_env "$GH" "$CLI_BASH" "$STAGE/launch-forking/repo/bin/clawd-pet" stop >/dev/null 2>&1
launch_env "$GH" CLAWD_OWN_PIDS_CHECKER="$STUBS/enumerator-installed" CLAWD_TEST_REAL_AGENT="$AGENT_BIN" "$CLI_BASH" "$STAGE/launch-forking/repo/bin/clawd-pet" uninstall >/dev/null 2>&1
# and a scratch build of launcher.c passes the whole path too
launcher_scenario scratch "$STAGE/launcher-scratch/clawd-pet-launch"
check "a fresh build of launcher.c passes the launch guard through the whole path" test "$(guard_field guard)" = allowed
launch_env "$GH" "$CLI_BASH" "$STAGE/launch-scratch/repo/bin/clawd-pet" stop >/dev/null 2>&1
launch_env "$GH" CLAWD_OWN_PIDS_CHECKER="$STUBS/enumerator-installed" CLAWD_TEST_REAL_AGENT="$AGENT_BIN" "$CLI_BASH" "$STAGE/launch-scratch/repo/bin/clawd-pet" uninstall >/dev/null 2>&1

# install refuses a launcher that is not the recorded one, and changes nothing
refuse_install() { # name launcher-file record-text|NONE|"" ; sets RIO, RIRC; HOME tree must stay empty of install files
  local n="$1" bin="$2" rec="${3:-}" d="$STAGE/refuse-$1"
  mini_repo "$d/repo" "$bin" "$rec" || return 1
  fresh_home "$d/home" || return 1
  mkdir -p "$d/build"; cp "$GUARD" "$d/build/clawd-pet-agent"
  RIB="$(cd "$d/home" && find . | sort)"
  RIO="$(HOME="$d/home" CLAWD_BUILD_DIR="$d/build" CLAWD_LAUNCHCTL="$STUBS/launchctl" "$CLI_BASH" "$d/repo/bin/clawd-pet" install 2>&1)"; RIRC=$?
  RIA="$(cd "$d/home" && find . | sort)"
}
cp "$LAUNCH_BIN" "$STAGE/launcher-tampered"; printf 'X' | dd of="$STAGE/launcher-tampered" bs=1 seek=64 conv=notrunc 2>/dev/null
good_sha="$(cut -d' ' -f1 "$LAUNCH_REC")"
refuse_install tampered "$STAGE/launcher-tampered" "$good_sha  clawd-pet-launch
"
check "install refuses a launcher whose bytes differ from the record (exit 2)" test "$RIRC" -eq 2
check "... says the launcher does not match its record" contains "$RIO" "does not match"
check "... and created nothing (no ROOT, no marker, no plist, no CLI)" test "$RIB" = "$RIA"
refuse_install norecord "$LAUNCH_BIN" NONE
check "install refuses when the sha256 record is missing (exit 2)" test "$RIRC" -eq 2
check "... and created nothing" test "$RIB" = "$RIA"
for variant in "short:abcd  clawd-pet-launch
" "upper:$(printf '%s' "$good_sha" | tr a-f A-F)  clawd-pet-launch
" "wrongname:$good_sha  other-file
" "twolines:$good_sha  clawd-pet-launch
$good_sha  clawd-pet-launch
" "empty:" "nohash:  clawd-pet-launch
"; do
  vname="${variant%%:*}"; vtext="${variant#*:}"
  mini_repo "$STAGE/refuse-rec-$vname/repo" "$LAUNCH_BIN" "x"; printf '%s' "$vtext" > "$STAGE/refuse-rec-$vname/repo/launcher/clawd-pet-launch.sha256"
  fresh_home "$STAGE/refuse-rec-$vname/home"; mkdir -p "$STAGE/refuse-rec-$vname/build"; cp "$GUARD" "$STAGE/refuse-rec-$vname/build/clawd-pet-agent"
  before_rec="$(cd "$STAGE/refuse-rec-$vname/home" && find . | sort)"
  HOME="$STAGE/refuse-rec-$vname/home" CLAWD_BUILD_DIR="$STAGE/refuse-rec-$vname/build" "$CLI_BASH" "$STAGE/refuse-rec-$vname/repo/bin/clawd-pet" install >/dev/null 2>&1; rc=$?
  check "install refuses a malformed record ($vname): exit 2" test "$rc" -eq 2
  check "... and created nothing ($vname)" test "$(cd "$STAGE/refuse-rec-$vname/home" && find . | sort)" = "$before_rec"
done
mini_repo "$STAGE/refuse-nobin/repo" "$LAUNCH_BIN"; rm -f -- "$STAGE/refuse-nobin/repo/launcher/clawd-pet-launch"
fresh_home "$STAGE/refuse-nobin/home"; mkdir -p "$STAGE/refuse-nobin/build"; cp "$GUARD" "$STAGE/refuse-nobin/build/clawd-pet-agent"
before_nobin="$(cd "$STAGE/refuse-nobin/home" && find . | sort)"
HOME="$STAGE/refuse-nobin/home" CLAWD_BUILD_DIR="$STAGE/refuse-nobin/build" "$CLI_BASH" "$STAGE/refuse-nobin/repo/bin/clawd-pet" install >/dev/null 2>&1; rc=$?
check "install refuses when the launcher file is missing (exit 2)" test "$rc" -eq 2
check "... creating nothing" test "$(cd "$STAGE/refuse-nobin/home" && find . | sort)" = "$before_nobin"
mini_repo "$STAGE/refuse-link/repo" "$LAUNCH_BIN"; rm -f -- "$STAGE/refuse-link/repo/launcher/clawd-pet-launch"; ln -s "$LAUNCH_BIN" "$STAGE/refuse-link/repo/launcher/clawd-pet-launch"
fresh_home "$STAGE/refuse-link/home"; mkdir -p "$STAGE/refuse-link/build"; cp "$GUARD" "$STAGE/refuse-link/build/clawd-pet-agent"
before_link="$(cd "$STAGE/refuse-link/home" && find . | sort)"
HOME="$STAGE/refuse-link/home" CLAWD_BUILD_DIR="$STAGE/refuse-link/build" "$CLI_BASH" "$STAGE/refuse-link/repo/bin/clawd-pet" install >/dev/null 2>&1; rc=$?
check "install refuses a launcher that is a symlink (exit 2)" test "$rc" -eq 2
check "... creating nothing" test "$(cd "$STAGE/refuse-link/home" && find . | sort)" = "$before_link"
check "none of the install attempts above ran a compiler" test ! -s "$STUB_CC_LOG"

stop_here 3f

# ---- 3g. `clawd-pet update` (Tests/update.test.sh): a full update, when the agent restarts, the wait for the new process, refusals ------------
# It has its own fake HOMEs and repos and a stub launchctl whose pid changes on `kickstart -k`; the counts join this file's.
upd_out="$(CLAWD_TEST_REAL_AGENT="$AGENT_BIN" "$CLI_BASH" "$REPO/Tests/update.test.sh" 2>&1)"; upd_rc=$?
printf '%s\n' "$upd_out" | grep -vE '^RESULT ' | sed 's/^/  /'
upd_counts="$(printf '%s\n' "$upd_out" | sed -n 's/^RESULT pass=\([0-9][0-9]*\) fail=\([0-9][0-9]*\)$/\1 \2/p' | tail -n 1)"
if [ -n "$upd_counts" ]; then
  pass=$((pass + ${upd_counts% *})); fail=$((fail + ${upd_counts#* }))
  check "the update tests exit 0" test "$upd_rc" -eq 0
else
  fail=$((fail + 1)); echo "FAIL: the update tests printed no RESULT line (exit $upd_rc)"
fi
stop_here 3g

# ---- 4. uninstall fails closed when the process enumeration cannot be trusted -----------------------------
for stub in own-pids-fail own-pids-silent own-pids-miscount; do
  before_fail="$(snap_noplist)"
  out="$(CLAWD_OWN_PIDS_CHECKER="$STUBS/$stub" "$CLI_BASH" "$CLI" uninstall 2>&1)"
  check "uninstall refuses with $stub" test "$?" -ne 0
  check "refused uninstall ($stub) removed nothing but the LaunchAgent plist" test "$(snap_noplist)" = "$before_fail"
  check "refused uninstall ($stub) has already removed the plist" test ! -e "$PLIST"
  # only the run that removes the plist reports it; a rerun finds it gone
  if [ "$stub" = own-pids-fail ]; then check "refused uninstall ($stub) says it removed the plist" contains "$out" "already removed the LaunchAgent plist"; fi
  check "refused uninstall ($stub) kept the manifest, the agent and the CLI" bash -c "[ -f '$ROOT/manifest' ] && [ -f '$INSTALLED_AGENT' ] && [ -f '$INSTALLED_CLI' ]"
done
out="$("$CLI_BASH" "$CLI" start 2>&1)"; rc=$?
check "start after a refused uninstall fails (exit 2)" test "$rc" -eq 2
check "... and says an install or an uninstall is unfinished" contains "$out" "unfinished"
CLAWD_OWN_PIDS_CHECKER="$STAGE/does-not-exist" "$CLI_BASH" "$CLI" uninstall >/dev/null 2>&1; check "uninstall refuses without an enumerator" test "$?" -ne 0
before_flaky="$(snap_noplist)"; rm -f -- "$STAGE/flaky.count"
out="$(STUB_FLAKY_COUNT="$STAGE/flaky.count" STUB_FLAKY_FAILS=99 CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-flaky" "$CLI_BASH" "$CLI" uninstall 2>&1)"
check "an enumeration that keeps failing still refuses" test "$?" -ne 0
check "... after exactly five tries (a bounded retry)" test "$(cat "$STAGE/flaky.count")" = 5
check "... and removed nothing" test "$(snap_noplist)" = "$before_flaky"
check "... and the message says to retry after process starts and exits settle" contains "$out" "retry after process starts and exits settle"
cp "$ROOT/manifest" "$STAGE/manifest.good"
sed '$d' "$STAGE/manifest.good" > "$ROOT/manifest"; printf 'file /etc/hosts\nend\n' >> "$ROOT/manifest"
"$CLI_BASH" "$CLI" uninstall >/dev/null 2>&1; check "uninstall refuses a manifest entry outside the installation" test "$?" -ne 0
check "the outside file is untouched and the install intact" bash -c "[ -f /etc/hosts ] && [ -f '$INSTALLED_AGENT' ]"
cp "$STAGE/manifest.good" "$ROOT/manifest"

# ---- 5. uninstall selects pids only through --own-pids: exact path, our uid, SIGTERM then SIGKILL ----------
: > "$STUB_LOG"; : > "$STUB_OWN_LOG"
"$INSTALLED_AGENT" --test-hold 120 > "$STAGE/h1.out" 2>&1 & h1=$!; holders+=("$h1")
"$INSTALLED_AGENT" --test-hold 120 ignore-term > "$STAGE/h2.out" 2>&1 & h2=$!; holders+=("$h2")
/bin/sleep 120 & unrelated=$!; holders+=("$unrelated")
disown "$h1" "$h2" "$unrelated" 2>/dev/null
for _ in $(seq 1 100); do [ -s "$STAGE/h1.out" ] && [ -s "$STAGE/h2.out" ] && break; /bin/sleep 0.05; done
check "holder 1 runs under the installed path" alive "$h1"
check "holder 2 (ignores SIGTERM) runs under the installed path" alive "$h2"
listing="$("$INSTALLED_AGENT" --own-pids)"
check "own-pids lists both holders and not the unrelated sleep" bash -c "printf '%s' '$listing' | grep -q 'PID $h1 ' && printf '%s' '$listing' | grep -q 'PID $h2 ' && ! printf '%s' '$listing' | grep -q 'PID $unrelated ' && printf '%s' '$listing' | tail -n 1 | grep -qx 'OWN-PIDS 2'"
printf '#1 2026-10-22T00:00:00.000Z observers workspace=installed kvo=installed logwatch=armed kqueue=ok\n' > "$ROOT/aqua-diag.log"
printf 'v=1 origin=settings-restart pid=1 mono=1 boot=1.000000\n' > "$ROOT/open-settings"
out="$(CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-logging" "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "uninstall with running holders exits 0" test "$rc" -eq 0
check "holder 1 was terminated" bash -c "! kill -0 $h1 2>/dev/null"
check "holder 2 (SIGTERM ignored) was killed after the 2 s grace" bash -c "! kill -0 $h2 2>/dev/null"
check "an unrelated process survived" alive "$unrelated"
check "uninstall booted the label out" grep -qxF "launchctl bootout gui/$uid/com.tomtim.clawd-pet" "$STUB_LOG"
check "uninstall used --own-pids and nothing else to find pids (at least 3 enumerations)" bash -c "[ \$(wc -l < '$STUB_OWN_LOG') -ge 3 ] && ! grep -vxF -e '--own-pids' '$STUB_OWN_LOG'"
check "own-pids reports none after uninstall (independent checker)" bash -c "[ \"\$('$REPO/Tests/own-pids-check' | tail -n 1)\" = 'OWN-PIDS 0' ]"
check "listing of the install roots after uninstall equals the one before install" test "$(snapshot)" = "$before"
check "uninstall removed the Aqua diagnostics file aqua-diag.log" test ! -e "$ROOT/aqua-diag.log"
check "uninstall removed the settings reopen request open-settings, no residue" test ! -e "$ROOT/open-settings"
check "open was never called anywhere" test ! -s "$STUB_OPEN_LOG"
kill -KILL "$unrelated" 2>/dev/null

# ---- 5b. the identity is re-read right before each signal, not only before the SIGKILL ------------------------------------
# An unrelated process that the first listing wrongly names as the installed agent (it has since exited, or its pid was reused by
# another program) must not receive SIGTERM. The stub changes its answer after the first call.
/bin/sleep 120 & stranger=$!; holders+=("$stranger"); disown "$stranger" 2>/dev/null
for mode in absent restarted; do
  "$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "5b ($mode): reinstall for the race scenario" test "$?" -eq 0
  : > "$STUB_OWN_LOG"; rm -f "$STAGE/swap.count"
  out="$(STUB_SWAP_PID="$stranger" STUB_SWAP_MODE="$mode" STUB_SWAP_COUNT="$STAGE/swap.count" CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-swap" "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
  check "5b ($mode): the listed pid was never signalled (an unrelated process survives)" alive "$stranger"
  check "5b ($mode): the identity was checked again before the signal (first listing, re-check, post-grace listing, wait: at least 4 enumerations)" bash -c "[ \$(wc -l < '$STUB_OWN_LOG') -ge 4 ]"
  if [ "$mode" = absent ]; then
    check "5b (absent): uninstall completes" test "$rc" -eq 0
    check "5b (absent): the install is gone" test "$(snapshot)" = "$before"
  else
    check "5b (restarted): the process still looks present, so uninstall refuses and retains the files" test "$rc" -ne 0
    check "5b (restarted): the files were retained for a retry" test -f "$ROOT/manifest"
    CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-logging" "$CLI_BASH" "$CLI" uninstall >/dev/null 2>&1; check "5b (restarted): a later uninstall with a truthful enumeration finishes" test "$?" -eq 0
    check "5b (restarted): the install roots equal the listing before install" test "$(snapshot)" = "$before"
  fi
done
kill -KILL "$stranger" 2>/dev/null

# ---- 5c. `~/bin/clawd-pet uninstall` from the installed CLI: the live-writer check excludes it and every ancestor of it -----------
# The parent shell's own command line names the installed CLI path, which is what the check looks for; only the exclusion of this
# uninstall and its ancestors lets it through. A holder of the installed agent path is listed by --own-pids and is stopped, not refused.
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "5c: reinstall for the installed-CLI uninstall" test "$?" -eq 0
"$INSTALLED_AGENT" --test-hold 120 > "$STAGE/h3.out" 2>&1 & h3=$!; holders+=("$h3"); disown "$h3" 2>/dev/null
for _ in $(seq 1 100); do [ -s "$STAGE/h3.out" ] && break; /bin/sleep 0.05; done
check "5c: a holder runs under the installed agent path" alive "$h3"
out="$(/bin/sh -c '"$1" "$0" uninstall; exit $?' "$INSTALLED_CLI" "$CLI_BASH" 2>&1)"; rc=$?
check "5c: uninstall run from the installed CLI (and from a parent whose command line names it) exits 0" test "$rc" -eq 0
check "5c: it did not refuse itself" lacks "$out" "still using the installation"
check "5c: the holder was stopped" bash -c "! kill -0 $h3 2>/dev/null"
check "5c: the tree equals the tree before install" test "$(snapshot)" = "$before"

# ---- 5d. one enumeration that fails and then recovers (a process caught mid-exec) does not stop an uninstall ----------------------
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "5d: reinstall for the flaky enumeration" test "$?" -eq 0
rm -f -- "$STAGE/flaky.count"
STUB_FLAKY_COUNT="$STAGE/flaky.count" STUB_FLAKY_FAILS=3 CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-flaky" "$CLI_BASH" "$CLI" uninstall >/dev/null 2>&1
check "5d: uninstall exits 0 after three failed enumerations and then a good one" test "$?" -eq 0
check "5d: the enumerator was called more than three times" bash -c "[ \$(cat '$STAGE/flaky.count') -gt 3 ]"
check "5d: the tree equals the tree before install" test "$(snapshot)" = "$before"

# ---- 5e. uninstall waits for an asynchronous bootout, like stop ---------------------------------------------------------------------
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "5e: reinstall for the asynchronous bootout" test "$?" -eq 0
after_install="$(snapshot)"
"$CLI_BASH" "$CLI" start >/dev/null 2>&1
out="$(STUB_BOOTOUT_POLLS=3 "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "5e: uninstall succeeds when the label stays listed for 3 polls after bootout" test "$rc" -eq 0
check "5e: the tree equals the tree before install" test "$(snapshot)" = "$before"
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; "$CLI_BASH" "$CLI" start >/dev/null 2>&1
T0="$(ms)"; out="$(STUB_BOOTOUT_POLLS=100000 "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?; T1="$(ms)"
check "5e: a label that stays loaded for 10 s makes uninstall refuse (exit 2)" test "$rc" -eq 2
check "5e: ... after waiting the 10 s" bash -c "[ $((T1 - T0)) -ge 10000 ] && [ $((T1 - T0)) -lt 60000 ]"
check "5e: ... saying it is still loaded and the files are retained" bash -c "printf '%s' \"\$1\" | grep -q 'still loaded' && printf '%s' \"\$1\" | grep -q 'files retained'" _ "$out"
check "5e: ... and nothing was removed, the LaunchAgent plist included (it died before the plist step)" test "$(snapshot)" = "$after_install"
out="$(STUB_BOOTOUT_POLLS=0 "$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "5e: the retry once the label unloads at once finishes (exit 0)" test "$rc" -eq 0
check "5e: ... and the tree equals the tree before install" test "$(snapshot)" = "$before"

stop_here 5e
# ---- 6. second round: the log is kept and reported ----------------------------------------------------------
"$CLI_BASH" "$CLI" install >/dev/null 2>&1; check "reinstall after uninstall works" test "$?" -eq 0
printf 'STATE scene=idle\n' > "$ROOT/agent.log"
out="$("$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "uninstall with a log exits 0" test "$rc" -eq 0
check "uninstall reports the retained log path" contains "$out" "Retained log: $ROOT/agent.log"
check "the log is kept" test -f "$ROOT/agent.log"
check "after uninstall only the reported log differs from the listing before install" test "$(snapshot)" = "$(printf '%s\n%s' "Library/Application Support/clawd-pet" "Library/Application Support/clawd-pet/agent.log")"
"$CLI_BASH" "$CLI" uninstall >/dev/null 2>&1; rc=$?
check "uninstall without a manifest is an error" test "$rc" -ne 0
tree_with_log="$(snapshot)"
out="$("$CLI_BASH" "$CLI" install 2>&1)"; rc=$?
check "a second install over the retained log succeeds" test "$rc" -eq 0
check "the second install did not create \$ROOT (root-created no)" test "$(cat "$MARKER")" = "root-created no"
check "the second install kept the retained log" test "$(cat "$ROOT/agent.log")" = "STATE scene=idle"
sha_idle="$(printf 'STATE scene=idle\n' | /usr/bin/shasum -a 256 | cut -d' ' -f1)"
check "the second install records the retained log's size and sha256 (logbase <path> <bytes> <sha256>) and agent.log.1 as absent" bash -c "[ \"\$(tail -n 3 '$ROOT/manifest')\" = \"\$(printf '%s\n%s\n%s' 'logbase $ROOT/agent.log 17 $sha_idle' 'logbase $ROOT/agent.log.1 absent' end)\" ]"
out="$("$CLI_BASH" "$CLI" uninstall 2>&1)"; rc=$?
check "a second uninstall exits 0" test "$rc" -eq 0
check "the second uninstall restores the same tree (\$ROOT with the retained log only)" test "$(snapshot)" = "$tree_with_log"
check "the second uninstall reports the retained log" contains "$out" "Retained log: $ROOT/agent.log"
# logbase with both logs retained, and an install that cannot read a retained log
printf 'older generation\n' > "$ROOT/agent.log.1"
sha_older="$(printf 'older generation\n' | /usr/bin/shasum -a 256 | cut -d' ' -f1)"
tree_two_logs="$(snapshot)"
out="$("$CLI_BASH" "$CLI" install 2>&1)"; rc=$?
check "a third install over both retained logs succeeds" test "$rc" -eq 0
check "the third install records both logs by size and sha256" bash -c "[ \"\$(tail -n 3 '$ROOT/manifest')\" = \"\$(printf '%s\n%s\n%s' 'logbase $ROOT/agent.log 17 $sha_idle' 'logbase $ROOT/agent.log.1 17 $sha_older' end)\" ]"
check "uninstall accepts the logbase lines and ignores them (exit 0)" "$CLI_BASH" "$CLI" uninstall
check "the third uninstall restores the tree with both retained logs" test "$(snapshot)" = "$tree_two_logs"
chmod 000 "$ROOT/agent.log"
out="$("$CLI_BASH" "$CLI" install 2>&1)"; rc=$?
chmod 644 "$ROOT/agent.log"
check "an unreadable retained log refuses the install before anything is created (exit 2)" test "$rc" -eq 2
check "... and says which log it could not read" contains "$out" "cannot read $ROOT/agent.log to record its state"
check "... and changed nothing (no marker, no manifest)" test "$(snapshot)" = "$tree_two_logs"

# ---- 6a. interrupted installs and uninstalls: Tests/install-interrupt.test.sh (cut at every operation, orphan writer, injected states) ----
int_out="$(CLAWD_TEST_REAL_AGENT="$AGENT_BIN" "$CLI_BASH" "$REPO/Tests/install-interrupt.test.sh" 2>&1)"; int_rc=$?
printf '%s\n' "$int_out" | grep -vE '^RESULT ' | grep -v ': interpreters seen by the stubs' | sed 's/^/  /'
int_counts="$(printf '%s\n' "$int_out" | sed -n 's/^RESULT pass=\([0-9][0-9]*\) fail=\([0-9][0-9]*\)$/\1 \2/p' | tail -n 1)"
if [ -n "$int_counts" ]; then
  pass=$((pass + ${int_counts% *})); fail=$((fail + ${int_counts#* }))
  check "the interrupt tests exit 0" test "$int_rc" -eq 0
else
  fail=$((fail + 1)); echo "FAIL: the interrupt tests printed no RESULT line (exit $int_rc)"
fi

# ---- 6b. which interpreter ran every CLI process the stubs saw ---------------------------------------------------------------
shells="$(sort "$STUB_SHELL_LOG" | uniq -c | sed 's/^ *//' | tr '\n' ';')"
echo "clawd-pet-cli.test: interpreters seen by the stubs: $shells"
check "the stubs recorded the interpreter of many CLI processes" bash -c "[ \$(wc -l < '$STUB_SHELL_LOG') -ge 20 ]"
if [ "${CLAWD_TEST_BASH:-}" = /bin/bash ]; then
  check "pinned: /bin/bash is bash 3.2" bash -c "/bin/bash -c 'echo \$BASH_VERSION' | grep -q '^3\\.2'"
  check "pinned: every CLI process the stubs saw was /bin/bash" bash -c "! grep -vxF /bin/bash '$STUB_SHELL_LOG'"
else
  check "unpinned: the CLI processes ran under the bash found on PATH, never a path-less guess" bash -c "! grep -vxF '$CLI_BASH' '$STUB_SHELL_LOG'"
fi
check "no test line starts the CLI with a bare bash that bypasses CLI_BASH" bash -c "! grep -nE '(^|[^_A-Za-z\"/])bash +\"?\\\$(INSTALLED_)?CLI\"?( |\$)' '$0'"

# ---- 7. source hygiene of the CLI itself -------------------------------------------------------------------
grep -vE '^[[:space:]]*#' "$CLI" > "$STAGE/cli.code"
check "CLI never calls pgrep or pkill" bash -c "! grep -qE '(^|[^a-z])(pgrep|pkill)( |\$)' '$STAGE/cli.code'"
check "CLI never removes a tree" bash -c "! grep -qE 'rm +-[a-zA-Z]*[rR]|rm +--recursive' '$STAGE/cli.code'"
check "CLI has no Trash or holding area" bash -c "! grep -qE 'Trash|noindex' '$STAGE/cli.code'"
check "CLI never runs open" bash -c "! grep -qE '(^|[;&|( ])open +|/usr/bin/open' '$STAGE/cli.code'"
check "CLI removes files one at a time with rm and directories with rmdir" bash -c "grep -qE 'rm -- ' '$STAGE/cli.code' && grep -qE 'rmdir -- ' '$STAGE/cli.code'"
check "settings: every writer locks through one place, lock_control, and the lock is the dedicated control.lock descriptor" bash -c "[ \"\$(grep -c '\"\\\$LOCKF\" ' '$STAGE/cli.code')\" = 1 ] && grep -q 'exec 9<\"\\\$CONTROL_LOCK\"' '$STAGE/cli.code' && ! grep -E 'LOCKF.*CONTROL\"' '$STAGE/cli.code'"
check "settings: control.json is replaced in one place, by a rename of control.json.partial, and plutil only ever edits the partial" bash -c "[ \"\$(grep -c 'mv -f \"\\\$CONTROL_PARTIAL\" \"\\\$CONTROL\"' '$STAGE/cli.code')\" = 1 ] && ! grep -E 'plutil -(replace|insert|remove)[^|;]*\"\\\$CONTROL\"( |\$)' '$STAGE/cli.code'"
check "settings: control.lock is created in one place only, by install (no writer creates it)" bash -c "[ \"\$(grep -c ': > \"\\\$CONTROL_LOCK\"' '$STAGE/cli.code')\" = 1 ] && awk '/^cmd_install\\(\\)/ { inside = 1 } inside && /: > \"\\\$CONTROL_LOCK\"/ { found = 1 } /^# --- uninstall/ { inside = 0 } END { exit found ? 0 : 1 }' '$STAGE/cli.code'"
# `status` prints the value; only applied_at_least decides anything with it.
awk '/^cmd_status\(\) \{/ { inside = 1 } !inside { print } inside && /^\}/ { inside = 0 }' "$STAGE/cli.code" > "$STAGE/cli.code.nostatus"
check "settings: the CLI waits for the agent in one place, on status.json's appliedGeneration (status only prints it)" bash -c "[ \"\$(grep -c 'appliedGeneration' '$STAGE/cli.code.nostatus')\" = 1 ]"
check "CLI signals a process in exactly one place" test "$(grep -cE '(^|[^a-z_])kill +"?-' "$STAGE/cli.code")" = 1
check "... and that place is signal_if_same, which re-reads the identity before it signals" grep -qF 'kill "-$sig" "$pid"' "$STAGE/cli.code"
check "CLI lists processes with ps in one place, to look for a live writer and never to pick a target" test "$(grep -cF '/bin/ps ' "$STAGE/cli.code")" = 1
check "... and the listing goes into the table the live-writer check reads" grep -qE '^ +table="\$\(.*/bin/ps ' "$STAGE/cli.code"

echo "clawd-pet-cli.test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
