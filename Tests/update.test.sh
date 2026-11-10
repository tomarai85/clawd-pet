#!/bin/bash
# `clawd-pet update` tests (Sprint 4c). Run by Tests/cli.test.sh, or alone. The last line is "RESULT pass=N fail=M".
# Everything happens in fake HOME directories under .build/update-test, with a stub launchctl whose pid changes on `kickstart -k` and a
# stand-in for the restarted agent (Tests/stubs/launchctl-update). The CLI under test is a copy of bin/clawd-pet inside small fake repos
# (versions of one pet). Nothing touches the real HOME or the real launchd, nothing signals a process, nothing opens a window.
#
# Sections: 1 a full update of an installed pet (what changes, what must not), 2 when the agent is restarted and when it is not,
# 3 the wait for the restarted agent (a new process, not the old one's status), 4 refusals (each leaves every file as it was, and each
# is followed by a repair that lets the same update through), 5 repeated updates and the uninstall afterwards, 5b a setting that only a
# restart applies, 5c the restart marker (a cut between the last copy and the restart is finished by a plain re-run), 5d a stale
# manifest.partial (discarded when provably a cut update's, refused otherwise), 5e one update at a time (a second one is refused while the
# first holds the lock; the lock goes with its holder), 6 source hygiene.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BASH="${CLAWD_TEST_BASH:-bash}"
STUBS="$REPO/Tests/stubs"
SHIM_SRC="$REPO/Tests/interrupt-shims/op-shim"
REAL_AGENT="${CLAWD_TEST_REAL_AGENT:-}"
if [ -z "$REAL_AGENT" ]; then
  for candidate in "$REPO/.build/release/clawd-pet-agent" "$REPO/.build/debug/clawd-pet-agent"; do
    if [ -x "$candidate" ]; then REAL_AGENT="$candidate"; break; fi
  done
fi
[ -x "$REAL_AGENT" ] || { echo "FAIL: no built agent for --own-pids (swift build)"; echo "RESULT pass=0 fail=1"; exit 2; }
unset CLAWD_OWN_PIDS_CHECKER STUB_OWN_LOG STUB_OPEN_LOG STUB_SHELL_LOG CLAWD_FLUSH_PERL CLAWD_FLUSH_CHUNK STUB_FLUSH_FAIL STUB_FLUSH_FAIL_EXACT 2>/dev/null
export CLAWD_TEST_REAL_AGENT="$REAL_AGENT"
LAUNCHCTL_STUB="$STUBS/launchctl-update"

STAGE="$REPO/.build/update-test/$(date +%s)-$$"
mkdir -p "$STAGE" || { echo "FAIL: cannot create $STAGE"; echo "RESULT pass=0 fail=1"; exit 2; }
pass=0; fail=0
check() { # name, then a command whose success is the check
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)'; }
wait_until() { # tries, then a command (a poll of a real condition with a generous bound; the test fails when the bound is hit)
  local tries="$1" n=0; shift
  while [ "$n" -lt "$tries" ]; do "$@" && return 0; sleep 0.05; n=$((n + 1)); done
  return 1
}
holders=()
cleanup() { local p; for p in ${holders[@]+"${holders[@]}"}; do kill -KILL "$p" 2>/dev/null; done; }
trap cleanup EXIT

SHIMS="$STAGE/shims"; mkdir -p "$SHIMS" || exit 2
# The PATH shims are symlinks to a compiled trampoline that runs op-shim through /bin/sh (Tests/interrupt-shims/op-shim-trampoline.c:
# a #! shim exec'd by the bash CLI leaks kernel memory on macOS 26). /usr/bin/cc by path: run from cli.test.sh, PATH starts with
# Tests/stubs, whose cc must never run (install never builds) and exits 99.
/usr/bin/cc -O1 -DOPSHIM_SCRIPT="\"$SHIM_SRC\"" -o "$SHIMS/op-shim-trampoline" "$REPO/Tests/interrupt-shims/op-shim-trampoline.c" || { echo "cannot compile the op-shim trampoline"; exit 2; }
for c in mkdir cp mv chmod sed rm rmdir; do ln -s "$SHIMS/op-shim-trampoline" "$SHIMS/$c"; done

# ---- the fake repos: versions of one pet ------------------------------------------------------------------------------------------
# make_repo DIR agent=N cli=N pic=N cat=N
#   agent=N  the build's agent file says "agent vN"            cli=N  bin/clawd-pet is the real CLI (N=1) or the real CLI plus a line (N>1)
#   pic=N    motions/M1/001.png says "picture vN"              cat=N  the catalog: 1 names the base pictures; 2 also names frames/f4.png,
#            looks/L2 and 30 frames of motions/M2; 3 also names motions/M3/000.png.
#            The catalogs (clawd-atlas.json and claude-code-elements.json) say which cat they are.
#   page=N   the repo has a chat-page/ directory of the 8 files of the chat page; index.html says "page vN" (no page=: no chat-page/ at all)
make_repo() {
  local d="$1" agent=1 cli=1 pic=1 cat=1 page="" kv rel n names=""; shift
  for kv in "$@"; do
    case "$kv" in agent=*) agent="${kv#agent=}" ;; cli=*) cli="${kv#cli=}" ;; pic=*) pic="${kv#pic=}" ;; cat=*) cat="${kv#cat=}" ;; page=*) page="${kv#page=}" ;; esac
  done
  mkdir -p "$d/bin" "$d/launchd" "$d/launcher" "$d/art/frames" "$d/art/motions/M1" "$d/art/looks/L1" "$d/build" || return 1
  cp "$REPO/bin/clawd-pet" "$d/bin/clawd-pet" && chmod 755 "$d/bin/clawd-pet" || return 1
  [ "$cli" = 1 ] || printf '# cli v%s\n' "$cli" >> "$d/bin/clawd-pet"
  cp "$REPO/launchd/com.tomtim.clawd-pet.plist.in" "$d/launchd/"
  cp "$REPO/launcher/clawd-pet-launch" "$REPO/launcher/clawd-pet-launch.sha256" "$d/launcher/"
  : > "$d/Package.swift"
  cp "$STUBS/enumerator-installed" "$d/build/clawd-pet-agent" && chmod 755 "$d/build/clawd-pet-agent" || return 1
  printf '# agent v%s\n' "$agent" >> "$d/build/clawd-pet-agent"
  for n in 1 2 3; do printf 'frame %s\n' "$n" > "$d/art/frames/f$n.png"; done
  printf 'picture v1\n' > "$d/art/motions/M1/000.png"; printf 'picture v%s\n' "$pic" > "$d/art/motions/M1/001.png"
  printf 'picture look L1\n' > "$d/art/looks/L1/layer.png"
  names='"frames/f1.png","frames/f2.png","frames/f3.png","motions/M1/000.png","motions/M1/001.png","looks/L1/layer.png"'
  if [ "$cat" -ge 2 ]; then
    mkdir -p "$d/art/motions/M2" "$d/art/looks/L2" || return 1
    printf 'frame 4\n' > "$d/art/frames/f4.png"; printf 'picture look L2\n' > "$d/art/looks/L2/layer.png"
    names="$names"',"frames/f4.png","looks/L2/layer.png"'
    n=0; while [ "$n" -lt 30 ]; do rel="$(printf 'motions/M2/%03d.png' "$n")"; printf 'picture %s\n' "$rel" > "$d/art/$rel"; names="$names,\"$rel\""; n=$((n + 1)); done
  fi
  if [ "$cat" -ge 3 ]; then
    mkdir -p "$d/art/motions/M3" || return 1
    printf 'picture M3\n' > "$d/art/motions/M3/000.png"; names="$names"',"motions/M3/000.png"'
  fi
  printf '{"schema":2,"cat":%s,"files":[%s]}\n' "$cat" "$names" > "$d/art/clawd-atlas.json"
  printf '{"cat":%s}\n' "$cat" > "$d/art/claude-code-elements.json"
  if [ -n "$page" ]; then
    mkdir -p "$d/chat-page" || return 1
    for rel in "${PAGE_FILES[@]}"; do printf 'page file %s\n' "$rel" > "$d/chat-page/$rel"; done
    printf 'page v%s\n' "$page" > "$d/chat-page/index.html"
  fi
}
PAGE_FILES=(index.html page.css page.js marked.min.js Geist-Variable.woff2 OFL.txt LICENSE-marked.txt LICENSE-lucide.txt)
R_BASE="$STAGE/repo-base";   make_repo "$R_BASE"
R_V2="$STAGE/repo-v2";       make_repo "$R_V2" agent=2 cli=2 pic=2 cat=2
R_V3="$STAGE/repo-v3";       make_repo "$R_V3" agent=3 cli=3 pic=3 cat=3
R_AGENT="$STAGE/repo-agent"; make_repo "$R_AGENT" agent=2
R_CLI="$STAGE/repo-cli";     make_repo "$R_CLI" cli=2
R_PIC="$STAGE/repo-pic";     make_repo "$R_PIC" pic=2
R_CAT="$STAGE/repo-cat";     make_repo "$R_CAT" cat=2
check "the fake repos exist and the versions differ" bash -c "! cmp -s '$R_BASE/build/clawd-pet-agent' '$R_V2/build/clawd-pet-agent' && ! cmp -s '$R_BASE/bin/clawd-pet' '$R_V2/bin/clawd-pet' && ! cmp -s '$R_BASE/art/clawd-atlas.json' '$R_V2/art/clawd-atlas.json'"

# ---- helpers ---------------------------------------------------------------------------------------------------------------------
# A tree: every path, then a checksum of every regular file.
tree() { (cd "$1" && LC_ALL=C find . -print | LC_ALL=C sort && LC_ALL=C find . -type f -exec /usr/bin/cksum {} + | LC_ALL=C sort -k3); }
# What update must never touch: the plist, the launcher, control.json, control.lock (inode, modification time, bytes).
keep_digest() {
  local f
  for f in "$1/Library/LaunchAgents/com.tomtim.clawd-pet.plist" "$1/Library/Application Support/clawd-pet/bin/clawd-pet-launch" \
           "$1/Library/Application Support/clawd-pet/control.json" "$1/Library/Application Support/clawd-pet/control.lock"; do
    printf '%s %s %s\n' "$(/usr/bin/stat -f '%i %m %z' "$f")" "$(/usr/bin/cksum < "$f")" "${f##*/}"
  done
}
install_home() { # name repo -> H, R. A loaded job (pid 4242) and the old agent's status.json
  H="$STAGE/h-$1"; R="$H/Library/Application Support/clawd-pet"
  mkdir -p "$H/bin" "$H/Library/LaunchAgents" "$H/Library/Application Support" || exit 2
  tree "$H" > "$H.pre.tree"
  env HOME="$H" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" CLAWD_BUILD_DIR="$2/build" \
    "$CLI_BASH" "$2/bin/clawd-pet" install > "$H.install.out" 2>&1 || { echo "FAIL: install of $2 for $1 failed: $(cat "$H.install.out")"; exit 2; }
  : > "$H.loaded"; echo 4242 > "$H.loaded.pid"
  printf '{"focusViolations":0,"pid":4242,"appliedGeneration":0}\n' > "$R/status.json"
}
set_generation() { /usr/bin/plutil -replace generation -integer "$1" "$R/control.json" && printf '{"focusViolations":0,"pid":4242,"appliedGeneration":%s}\n' "$1" > "$R/status.json"; }
run_update() { # home repo [args...] -> OUT, RC, ELAPSED; the verbs sent to launchd in <home>.calls, the operations in <home>.upd.ops
  local h="$1" repo="$2" t0; shift 2
  echo 0 > "$h.upd.count"; : > "$h.upd.ops"; : > "$h.calls"
  t0="$(ms)"
  OUT="$(env HOME="$h" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$h.calls" STUB_STATE="$h.loaded" STUB_ROOT="$h/Library/Application Support/clawd-pet" \
    STUB_KICK_MODE="${KICK_MODE:-ok}" STUB_KICK_DELAY="${KICK_DELAY:-1}" CLAWD_BUILD_DIR="$repo/build" CLAWD_RESTART_WAIT_S="${WAIT_S:-4}" CLAWD_CONTROL_LOCK_WAIT_S="${SETTINGS_LOCK_WAIT_S:-10}" \
    CLAWD_FLUSH_PERL="${FLUSH_STUB_PATH:-}" CLAWD_FLUSH_CHUNK="${FLUSH_CHUNK_T:-}" STUB_FLUSH_FAIL="${FLUSH_FAIL:-}" STUB_FLUSH_FAIL_EXACT="${FLUSH_FAIL_EXACT:-}" \
    OPSHIM_COUNT="$h.upd.count" OPSHIM_LOG="$h.upd.ops" OPSHIM_CORRUPT_AT="${CORRUPT_AT:-0}" "$CLI_BASH" "$repo/bin/clawd-pet" update "$@" 2>&1)"; RC=$?
  ELAPSED=$(( $(ms) - t0 ))
}
uninstall_home() { # home repo -> OUT, RC
  OUT="$(env HOME="$1" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$1.calls" STUB_STATE="$1.loaded" STUB_ROOT="$1/Library/Application Support/clawd-pet" "$CLI_BASH" "$2/bin/clawd-pet" uninstall 2>&1)"; RC=$?
}
kicks() { grep -c '^launchctl kickstart -k ' "$1.calls"; }
verbs_other_than_list() { grep -vc '^launchctl list ' "$1.calls"; }
ops_naming() { grep -cE "$2" "$1.upd.ops"; }
NEVER_TOUCHED='LaunchAgents|clawd-pet-launch|control\.(json|lock)'
same_art() { # repo home: every file the repo's art tree holds is installed byte for byte
  local rel ok=0
  while IFS= read -r rel; do cmp -s "$1/art/$rel" "$2/Library/Application Support/clawd-pet/art/$rel" || { ok=1; echo "differs: $rel"; }; done < <(cd "$1/art" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  return $ok
}
UID_NUM="$(id -u)"

# ---- 1. a full update of an installed pet ----------------------------------------------------------------------------------------
install_home full "$R_BASE"; HF="$H"; RF="$R"
set_generation 4
before_keep="$(keep_digest "$HF")"; lock_ino="$(/usr/bin/stat -f %i "$RF/control.lock")"
run_update "$HF" "$R_V2"
check "1: update from the repo exits 0" test "$RC" -eq 0
check "1: it says what it brought: agent and CLI replaced, 32 pictures added, 3 files replaced" contains "$OUT" "agent replaced, CLI replaced, art 32 added and 3 replaced"
check "1: it says the plist and the launcher were not touched" contains "$OUT" "the plist and the launcher were not touched"
check "1: it restarted the agent and names the old and the new pid" contains "$OUT" "restarted the agent (pid 4242 -> 4243)"
check "1: the plist, the launcher, control.json and control.lock are the same files (inode, mtime, bytes)" test "$(keep_digest "$HF")" = "$before_keep"
check "1: control.lock is the same inode" test "$(/usr/bin/stat -f %i "$RF/control.lock")" = "$lock_ino"
check "1: no operation of the update names the plist, the launcher, control.json or control.lock" test "$(ops_naming "$HF" "$NEVER_TOUCHED")" = 0
check "1: the only verbs sent to launchd besides list: exactly one kickstart -k of the label" bash -c "[ \"\$(grep -vc '^launchctl list ' '$HF.calls')\" = 1 ] && grep -qxF 'launchctl kickstart -k gui/$UID_NUM/com.tomtim.clawd-pet' '$HF.calls'"
check "1: no bootout, bootstrap or unload was ever sent" bash -c "! grep -E 'bootout|bootstrap|unload|remove' '$HF.calls'"
check "1: every file of the new art tree is installed byte for byte (32 new, 1 replaced, both catalogs)" same_art "$R_V2" "$HF"
check "1: the agent is the new build, byte for byte, and executable" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$RF/bin/clawd-pet-agent' && [ -x '$RF/bin/clawd-pet-agent' ]"
check "1: the CLI is the repo's, byte for byte, and executable" bash -c "cmp -s '$R_V2/bin/clawd-pet' '$HF/bin/clawd-pet' && [ -x '$HF/bin/clawd-pet' ]"
check "1: no .partial name is left in the install" bash -c "! find '$HF' -name '*.partial' | grep -q ."
check "1: the manifest still starts with schema 1 and ends with end" bash -c "[ \"\$(sed -n 1p '$RF/manifest')\" = 'schema 1' ] && [ \"\$(tail -n 1 '$RF/manifest')\" = end ]"
check "1: the logbase records are untouched and still the last lines before end" bash -c "[ \"\$(tail -n 3 '$RF/manifest')\" = \"\$(printf '%s\n%s\n%s' 'logbase $RF/agent.log absent' 'logbase $RF/agent.log.1 absent' end)\" ]"
check "1: the manifest holds no file or directory line twice" bash -c "[ -z \"\$(grep '^file ' '$RF/manifest' | sort | uniq -d)\" ] && [ -z \"\$(grep '^dir ' '$RF/manifest' | sort | uniq -d)\" ]"
check "1: every installed art file is in the manifest" bash -c "cd '$RF' && find art -type f | while read -r f; do grep -qxF \"file $RF/\$f\" manifest || { echo \"unlisted: \$f\"; exit 1; }; done"
check "1: the new directories are listed (motions/M2, looks/L2), parents before children" bash -c "grep -qxF 'dir $RF/art/motions/M2' '$RF/manifest' && grep -qxF 'dir $RF/art/looks/L2' '$RF/manifest'"
check "1: the new file lines sit before the log lines" bash -c "[ \$(grep -nxF 'file $RF/art/motions/M2/029.png' '$RF/manifest' | cut -d: -f1) -lt \$(grep -n '^log ' '$RF/manifest' | head -n 1 | cut -d: -f1) ]"
check "1: the replaced picture is listed with its .partial name (so an interrupted update leaves nothing unrecorded)" grep -qxF "file $RF/art/motions/M1/001.png.partial" "$RF/manifest"
check "1: ... and so is every new picture (30 in motions/M2, one in looks/L2, one in frames)" bash -c "[ \"\$(grep -cE '^file $RF/art/motions/M2/[0-9]+\.png\.partial\$' '$RF/manifest')\" = 30 ] && grep -qxF 'file $RF/art/looks/L2/layer.png.partial' '$RF/manifest' && grep -qxF 'file $RF/art/frames/f4.png.partial' '$RF/manifest'"
check "1: the installed status.json was not rewritten by update (the stub agent wrote it)" bash -c "grep -q '\"pid\":4243' '$RF/status.json'"
# The art goes in before the agent, and the catalogs after the pictures they name.
n_agent="$(awk '$2 == "mv" && index($0, "bin/clawd-pet-agent.partial") { print $1; exit }' "$HF.upd.ops")"
n_m2="$(awk '$2 == "mv" && index($0, "motions/M2/") { print $1 }' "$HF.upd.ops" | tail -n 1)"
n_atlas="$(awk '$2 == "mv" && index($0, "art/clawd-atlas.json.partial") { print $1; exit }' "$HF.upd.ops")"
n_manifest="$(awk '$2 == "mv" && index($0, "manifest.partial") { print $1; exit }' "$HF.upd.ops")"
n_mkdir="$(awk '$2 == "mkdir" { print $1; exit }' "$HF.upd.ops")"
check "1: the manifest is published (renamed) before any directory is made or any file is copied" bash -c "[ -n '$n_manifest' ] && [ -n '$n_mkdir' ] && [ '$n_manifest' -lt '$n_mkdir' ]"
check "1: the 30 new pictures of one directory are copied one by one, each to its .partial name, and renamed one by one (30 cp calls, 30 mv calls)" bash -c "[ \"\$(awk '\$2 == \"cp\" && index(\$0, \"motions/M2/\") && /\\.png\\.partial\$/' '$HF.upd.ops' | wc -l | tr -d ' ')\" = 30 ] && [ \"\$(awk '\$2 == \"mv\" && index(\$0, \"motions/M2/\")' '$HF.upd.ops' | wc -l | tr -d ' ')\" = 30 ]"
check "1: the catalog is replaced after the last picture it names" bash -c "[ -n '$n_atlas' ] && [ -n '$n_m2' ] && [ '$n_m2' -lt '$n_atlas' ]"
check "1: the agent is swapped after the catalog" bash -c "[ -n '$n_agent' ] && [ '$n_atlas' -lt '$n_agent' ]"
check "1: a replaced picture is never copied straight to its final name (it goes through .partial)" bash -c "! awk '\$2 == \"cp\"' '$HF.upd.ops' | grep -E ' [^ ]*/art/motions/M1/001.png\$'"
check "1: a new picture is never copied straight to its final name, nor into its directory (it goes through .partial, flushed, then renamed)" bash -c "! awk '\$2 == \"cp\"' '$HF.upd.ops' | grep -E ' [^ ]*/art/(motions/M2|looks/L2|frames)(/[^ ]*\\.png|/)?\$'"
check "1: no copy into the art tree names anything but a .partial file" bash -c "! awk '\$2 == \"cp\" && index(\$0, \"clawd-pet/art/\") && !/\\.partial\$/' '$HF.upd.ops' | grep -q ."
check "1: the agent and the CLI are never copied straight to their final names" bash -c "! awk '\$2 == \"cp\"' '$HF.upd.ops' | grep -E ' [^ ]*/(clawd-pet-agent|bin/clawd-pet)\$'"
uninstall_home "$HF" "$R_V2"
check "1: one uninstall removes everything the install and the update made (exit 0)" test "$RC" -eq 0
check "1: ... and the home holds no trace of the pet" bash -c "[ ! -e '$RF' ] && [ ! -e '$HF/Library/Application Support/clawd-pet.installing' ] && [ ! -e '$HF/bin/clawd-pet' ] && [ ! -e '$HF/Library/LaunchAgents/com.tomtim.clawd-pet.plist' ]"
check "1: ... the tree equals the tree before the install (every path and every checksum)" test "$(tree "$HF")" = "$(cat "$HF.pre.tree")"

# ---- 1b. durable publication (spec 9b item 9) -----------------------------------------------------------------------------------
# A rename is atomic, but the data of the file it renames can still be in the disk's cache: after a kernel panic or a dead battery the new
# name can stand on an empty file, and update and uninstall then refuse a truncated manifest. So every file the CLI publishes by rename is
# flushed to the disk (fcntl F_FULLFSYNC, through one line of perl) before its rename and the directory after it. The tests below read the
# order of the flushes and the renames from one log: Tests/stubs/perl-flush (CLAWD_FLUSH_PERL) writes "flush <path>" into the log the PATH
# shims write "<n> mv <a> <b>" into, and then runs the real perl, so the real flush happens in every run.
# flush_audit LOG: "mv=<renames> bad=<violations>". Four rules over the one log (a set of files is flushed and renamed together, so the rules are
# about order, not about pairs):
#   1. a rename "mv X.partial X" needs a flush of X.partial before it, and no copy onto X.partial since that flush (the copy renamed is the copy flushed);
#   2. every directory a rename leaves behind is flushed after it (at the end of the log, none may be pending);
#   3. a rename that follows anything but another rename (the start of the next set, the next executable, the next step) finds no directory pending:
#      what depends on a set is renamed after the set is on the disk;
#   4. a catalog is renamed only when no directory but its own (art/) is pending: the pictures it names are on the disk before it.
flush_audit() {
  awk '
    function dirname(p) { sub(/\/[^\/]*$/, "", p); return p }
    /^flush-call / { next }
    /^flush / { p = substr($0, 7); seen[p] = 1; if (p in pend) { delete pend[p]; npend-- } prev = "flush"; next }
    $2 == "mv" {
      if (index($0, "/status.json.new ")) next          # the stub launchctl publishing the stand-in agent status file, not the CLI
      rest = substr($0, index($0, " mv ") + 4); n = length(rest) - 9
      if (n <= 0 || n % 2 != 0) { bad++; print "unparsed rename: " rest; prev = "mv"; next }
      n = n / 2; src = substr(rest, 1, n + 8); dst = substr(rest, n + 10); mv++
      if (src != dst ".partial") { bad++; print "not a .partial rename: " rest; prev = "mv"; next }
      if (!(src in seen)) { bad++; print "no flush of " src " before its rename" }
      d = dirname(dst)
      if (npend > 0 && prev != "mv") { bad++; print "renamed " dst " before the directory of an earlier rename was flushed" }
      if (dst ~ /\/art\/(clawd-atlas|claude-code-elements)\.json$/) { for (q in pend) if (q != d) { bad++; print "catalog " dst " renamed while " q " was not flushed"; break } }
      delete seen[src]
      if (!(d in pend)) { pend[d] = 1; npend++ }
      prev = "mv"; next
    }
    { if ($2 == "cp") { for (s in seen) if (substr($0, length($0) - length(s)) == " " s) delete seen[s] } prev = $2 }
    END { for (q in pend) { bad++; print "no flush of " q " after the renames" } printf "mv=%d bad=%d\n", mv, bad }' "$1"
}
audit_is() { local got; got="$(flush_audit "$2")"; [ "$(printf '%s\n' "$got" | tail -n 1)" = "$1" ] || { printf '%s\n' "$got" >&2; return 1; }; }
logged_install() { # name repo -> H, R, OUT, RC: the install runs under the shims and the flush stub, its log in <home>.inst.ops
  H="$STAGE/h-$1"; R="$H/Library/Application Support/clawd-pet"
  mkdir -p "$H/bin" "$H/Library/LaunchAgents" "$H/Library/Application Support" || exit 2
  tree "$H" > "$H.pre.tree"; echo 0 > "$H.inst.count"; : > "$H.inst.ops"
  OUT="$(env HOME="$H" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" CLAWD_BUILD_DIR="$2/build" \
    CLAWD_FLUSH_PERL="$STUBS/perl-flush" STUB_FLUSH_FAIL="${FLUSH_FAIL:-}" STUB_FLUSH_FAIL_EXACT="${FLUSH_FAIL_EXACT:-}" \
    OPSHIM_COUNT="$H.inst.count" OPSHIM_LOG="$H.inst.ops" "$CLI_BASH" "$2/bin/clawd-pet" install 2>&1)"; RC=$?
}
renames_of() { awk '$2 == "mv" { n++ } END { print n + 0 }' "$1"; }

logged_install durable-install "$R_BASE"
check "1b: an install under the flush stub exits 0" test "$RC" -eq 0
check "1b: the install publishes six files by rename (the marker, the manifest, the focus-violation ledger, the agent, the CLI, the launcher), each flushed before and its directory after" audit_is "mv=6 bad=0" "$H.inst.ops"
has_line() { grep -qxF -- "$2" "$1"; }
for f in "$H/Library/Application Support/clawd-pet.installing.partial" "$R/manifest.partial" "$R/focus-violations.log.partial" "$R/bin/clawd-pet-agent.partial" "$H/bin/clawd-pet.partial" "$R/bin/clawd-pet-launch.partial" \
         "$H/Library/Application Support" "$R" "$R/bin" "$H/bin"; do
  check "1b: install flushes ${f#"$H"/}" has_line "$H.inst.ops" "flush $f"
done
check "1b: the install's manifest and its directory are on the disk before any directory below it is made or file copied" bash -c "awk '\$2 == \"mv\" && index(\$0, \"manifest.partial\") { m = NR } /^flush / && m && !f && \$0 == \"flush $R\" { f = NR } m && (\$2 == \"mkdir\" || \$2 == \"cp\") && !c { c = NR } END { exit (m && f && c && m < f && f < c) ? 0 : 1 }' '$H.inst.ops'"

install_home durable "$R_BASE"; HD="$H"; RD="$R"; set_generation 4
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HD" "$R_V2"
check "1b: a full update under the flush stub exits 0" test "$RC" -eq 0
check "1b: it makes 38 renames (the manifest, the 32 new pictures and the one it replaces, the two catalogs, the agent, the CLI), each flushed before and its directory after" audit_is "mv=38 bad=0" "$HD.upd.ops"
for f in "$RD/manifest.partial" "$RD/bin/clawd-pet-agent.partial" "$HD/bin/clawd-pet.partial" "$RD/art/motions/M1/001.png.partial" "$RD/art/clawd-atlas.json.partial" \
         "$RD" "$RD/bin" "$HD/bin" "$RD/art/motions/M1" "$RD/art"; do
  check "1b: update flushes ${f#"$HD"/}" has_line "$HD.upd.ops" "flush $f"
done
check "1b: the files published are still complete and current (the flush changed nothing)" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$RD/bin/clawd-pet-agent' && cmp -s '$R_V2/bin/clawd-pet' '$HD/bin/clawd-pet' && [ \"\$(tail -n 1 '$RD/manifest')\" = end ]"
check "1b: it flushes 54 paths in 11 perl starts (the manifest, the 33 pictures and their 4 directories, the 8 directories of the art tree, the catalogs and art/, the agent, the CLI: a call for the files and a call for the directories of each step but the art tree, which has the one)" bash -c "[ \"\$(grep -c '^flush ' '$HD.upd.ops')\" = 54 ] && [ \"\$(grep -c '^flush-call ' '$HD.upd.ops')\" = 11 ]"
check "1b: the 33 pictures, new and replaced, are flushed in one call and their 4 directories in one" bash -c "grep -qxF 'flush-call 33' '$HD.upd.ops' && grep -qxF 'flush-call 4' '$HD.upd.ops'"
check "1b: every new picture is flushed under its .partial name before it is renamed (the first and the last of motions/M2)" bash -c "grep -qxF 'flush $RD/art/motions/M2/000.png.partial' '$HD.upd.ops' && grep -qxF 'flush $RD/art/motions/M2/029.png.partial' '$HD.upd.ops'"
check "1b: the whole art tree (8 directories, in one call) is flushed, looks/L1 and motions/ among them, which no picture of this update sits in" bash -c "grep -qxF 'flush-call 8' '$HD.upd.ops' && grep -qxF 'flush $RD/art/looks/L1' '$HD.upd.ops' && grep -qxF 'flush $RD/art/motions' '$HD.upd.ops' && grep -qxF 'flush $RD/art' '$HD.upd.ops'"
check "1b: ... and that call comes after the last picture is renamed and before the first catalog is" bash -c "awk '\$2 == \"mv\" && index(\$0, \".png.partial\") { p = NR } /^flush \/.*\/art\/looks\/L1\$/ { t = NR } \$2 == \"mv\" && index(\$0, \"art/clawd-atlas.json.partial\") && !c { c = NR } END { exit (p && t && c && p < t && t < c) ? 0 : 1 }' '$HD.upd.ops'"
check "1b: the manifest and its directory are on the disk before the first directory is made or file copied (the write-ahead record of what the update writes)" bash -c "awk '\$2 == \"mv\" && index(\$0, \"manifest.partial\") { m = NR } /^flush / && m && !f && \$0 == \"flush $RD\" { f = NR } (\$2 == \"mkdir\" || \$2 == \"cp\") && !c { c = NR } END { exit (m && f && c && m < f && f < c) ? 0 : 1 }' '$HD.upd.ops'"
check "1b: the catalogs are renamed after the directory of the pictures they name is flushed" bash -c "awk '/^flush / && \$0 == \"flush $RD/art/motions/M1\" { d = NR } \$2 == \"mv\" && index(\$0, \"art/clawd-atlas.json.partial\") && !c { c = NR } END { exit (d && c && d < c) ? 0 : 1 }' '$HD.upd.ops'"
uninstall_home "$HD" "$R_V2"
check "1b: ... one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HD")" "$(cat "$HD.pre.tree")"

# a flush that fails stops the rename it guards: nothing is published unflushed
install_home flushfail-manifest "$R_BASE"; HM="$H"; RMN="$R"; set_generation 2; before_manifest_fail="$(tree "$HM")"
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL="manifest.partial" run_update "$HM" "$R_V2"
check "1b: the manifest's flush fails: the update exits 2 and says which file it could not flush" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'could not flush .*manifest.partial'" _ "$OUT"
check "1b: ... the manifest was never renamed, and not one file changed (the partial it owned is gone)" bash -c "! awk '\$2 == \"mv\"' '$HM.upd.ops' | grep -q manifest.partial && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HM")" "$before_manifest_fail"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HM" "$R_V2"
check "1b: ... and once the flush works the same update goes through (exit 0)" test "$RC" -eq 0
install_home flushfail-agent "$R_BASE"; HA="$H"; RA="$R"; set_generation 2
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL="bin/clawd-pet-agent.partial" run_update "$HA" "$R_V2"
check "1b: the agent's flush fails: exit 2, the agent was not renamed (the installed one is still the old build), and the update says it stopped partway" bash -c "[ '$RC' -eq 2 ] && ! awk '\$2 == \"mv\"' '$HA.upd.ops' | grep -q 'clawd-pet-agent.partial' && cmp -s '$R_BASE/build/clawd-pet-agent' '$RA/bin/clawd-pet-agent' && printf '%s' \"\$1\" | grep -q 'update stopped partway'" _ "$OUT"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HA" "$R_V2"
check "1b: ... update again finishes it: the agent is the new build (exit 0)" bash -c "[ '$RC' -eq 0 ] && cmp -s '$R_V2/build/clawd-pet-agent' '$RA/bin/clawd-pet-agent'"
install_home flushfail-dir "$R_BASE"; HY="$H"; RY="$R"; set_generation 2
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$HY/bin" run_update "$HY" "$R_V2"
check "1b: the flush of the directory after a rename fails: exit 2 and it says so (the rename is done, the update can be repeated)" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'could not flush .*/bin to the disk after moving' && printf '%s' \"\$1\" | grep -q 'update stopped partway'" _ "$OUT"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HY" "$R_V2"
check "1b: ... update again finishes it (exit 0)" test "$RC" -eq 0
FLUSH_FAIL="clawd-pet.installing.partial" logged_install flushfail-install "$R_BASE"
check "1b: an install whose first flush fails exits 2, publishes nothing, and tells the user to run uninstall" bash -c "[ '$RC' -eq 2 ] && ! awk '\$2 == \"mv\"' '$H.inst.ops' | grep -q . && printf '%s' \"\$1\" | grep -q 'could not flush' && printf '%s' \"\$1\" | grep -q 'run scripts/uninstall'" _ "$OUT"
OUT="$(env HOME="$H" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" CLAWD_OWN_PIDS_CHECKER="$R_BASE/build/clawd-pet-agent" "$CLI_BASH" "$R_BASE/bin/clawd-pet" uninstall 2>&1)"; RC=$?
check "1b: ... and uninstall clears what it left (exit 0, the tree is as it was before the install)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"

# ---- 1c. a set of art files: one call for its files, one for its directories (the cost of a perl start was the whole cost) ---------------------------------
# update replaces the pictures it finds changed as ONE set: every copy is written to its .partial name, all of them are flushed in one perl call, they
# are renamed, and the distinct directories they sit in are flushed in one call; the catalogs follow as a set of their own. A set is cut into
# CLAWD_FLUSH_CHUNK files (400 by default) so the argument list stays short. The flush_audit rules hold for every set, and no set is flushed file by file.
install_home sets "$R_V2"; HS="$H"; RS="$R"; set_generation 4
set_rels=(frames/f4.png looks/L2/layer.png)
n=0; while [ "$n" -lt 30 ]; do set_rels+=("$(printf 'motions/M2/%03d.png' "$n")"); n=$((n + 1)); done
for rel in "${set_rels[@]}"; do printf 'x' >> "$RS/art/$rel"; done
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HS" "$R_V2"
check "1c: an update that replaces 32 pictures in three directories exits 0 and says so" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'art 0 added and 32 replaced'" _ "$OUT"
check "1c: ... the 32 pictures are the repo's again, byte for byte" same_art "$R_V2" "$HS"
check "1c: ... 33 renames (the manifest and the 32 pictures), every one flushed before it, every directory flushed after, nothing out of order" audit_is "mv=33 bad=0" "$HS.upd.ops"
check "1c: ... 45 paths flushed (the manifest and its directory, the 32 copies, the 3 distinct directories, the 8 directories of the art tree) in 5 perl starts" bash -c "[ \"\$(grep -c '^flush ' '$HS.upd.ops')\" = 45 ] && [ \"\$(grep -c '^flush-call ' '$HS.upd.ops')\" = 5 ]"
check "1c: ... the copies go in one call of 32 paths, the directories in one call of 3, the art tree in one call of 8" bash -c "grep -qxF 'flush-call 32' '$HS.upd.ops' && grep -qxF 'flush-call 3' '$HS.upd.ops' && grep -qxF 'flush-call 8' '$HS.upd.ops'"
check "1c: ... each directory is flushed once by its set and once by the art tree, not once per file" bash -c "[ \"\$(grep -cxF 'flush $RS/art/motions/M2' '$HS.upd.ops')\" = 2 ] && [ \"\$(grep -cxF 'flush $RS/art/looks/L2' '$HS.upd.ops')\" = 2 ] && [ \"\$(grep -cxF 'flush $RS/art/frames' '$HS.upd.ops')\" = 2 ]"
check "1c: ... all 32 copies are made before the first of them is renamed" bash -c "awk '\$2 == \"cp\" && index(\$0, \".png.partial\") { c = NR } \$2 == \"mv\" && index(\$0, \".png.partial\") && !m { m = NR } END { exit (c && m && c < m) ? 0 : 1 }' '$HS.upd.ops'"
uninstall_home "$HS" "$R_V2"
check "1c: ... one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HS")" "$(cat "$HS.pre.tree")"

# a set larger than the chunk is several sets, each complete (flushed, renamed, its directories flushed) before the next begins
install_home chunks "$R_V2"; HK="$H"; RK="$R"; set_generation 4
for rel in "${set_rels[@]}"; do printf 'x' >> "$RK/art/$rel"; done
FLUSH_CHUNK_T=13 FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HK" "$R_V2"
check "1c: a chunk of 13: the same update exits 0" test "$RC" -eq 0
check "1c: ... the pictures are the repo's, byte for byte" same_art "$R_V2" "$HK"
check "1c: ... three sets (13, 13, 6 files) are 6 perl starts, 9 with the manifest and the art tree, and the audit still holds for each" bash -c "[ \"\$(grep -c '^flush-call ' '$HK.upd.ops')\" = 9 ] && grep -qxF 'flush-call 13' '$HK.upd.ops' && grep -qxF 'flush-call 6' '$HK.upd.ops'"
check "1c: ... 33 renames, in order" audit_is "mv=33 bad=0" "$HK.upd.ops"
check "1c: ... a directory a later set shares with an earlier one is flushed again after the later set (motions/M2: three sets, then the art tree)" test "$(grep -cxF "flush $RK/art/motions/M2" "$HK.upd.ops")" = 4
chunk_of() { # CLAWD_FLUSH_CHUNK value -> the chunk size the CLI settles on (the CLI's own two lines, evaluated in a subshell; the CLI is not run)
  ( CLAWD_FLUSH_CHUNK="$1"; eval "$(awk '/^FLUSH_CHUNK=/ { print; getline; print; exit }' "$REPO/bin/clawd-pet")"; printf '%s' "$FLUSH_CHUNK" )
}
check "1c: the chunk size is 400 by default (CLAWD_FLUSH_CHUNK unset or empty)" bash -c "[ \"\$1\" = 400 ] && [ \"\$2\" = 400 ]" _ "$(chunk_of '')" "$(chunk_of 400)"
check "1c: ... a usable CLAWD_FLUSH_CHUNK is taken (100 is 100)" test "$(chunk_of 100)" = 100
check "1c: ... zero, a negative number and text are not usable: the default (0 would make the loop take no file and never end)" bash -c "[ \"\$1\" = 400 ] && [ \"\$2\" = 400 ] && [ \"\$3\" = 400 ]" _ "$(chunk_of 0)" "$(chunk_of -5)" "$(chunk_of abc)"
check "1c: ... 1 and 399 are taken as they are; 400 is the cap" bash -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 399 ] && [ \"\$3\" = 400 ]" _ "$(chunk_of 1)" "$(chunk_of 399)" "$(chunk_of 400)"
check "1c: ... above the cap is the cap, so the argument list can never grow past 400 files (401, 1000, 5000 and a number too long for the shell's integers are 400)" bash -c "[ \"\$1\" = 400 ] && [ \"\$2\" = 400 ] && [ \"\$3\" = 400 ] && [ \"\$4\" = 400 ]" _ "$(chunk_of 401)" "$(chunk_of 1000)" "$(chunk_of 5000)" "$(chunk_of 99999999999999999999)"

# a flush that fails stops the set it guards: nothing of the set is renamed unflushed, and the same update goes through afterwards
install_home setfail-file "$R_V2"; HF2="$H"; RF2="$R"; set_generation 4
for rel in "${set_rels[@]}"; do printf 'x' >> "$RF2/art/$rel"; done
FLUSH_CHUNK_T=13 FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$RF2/art/motions/M2/017.png.partial" run_update "$HF2" "$R_V2"
check "1c: the flush of the second set's copies fails: exit 2, it names the set and says none of it was moved, and the update stopped partway" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'could not flush the 13-copy set starting at .*motions/M2/011.png.partial to the disk; none of it was moved into place' && printf '%s' \"\$1\" | grep -q 'update stopped partway'" _ "$OUT"
check "1c: ... the first set (13 pictures) was renamed, and not one picture of the failed set (11 to 23) was" bash -c "[ \"\$(awk '\$2 == \"mv\" && index(\$0, \".png.partial\")' '$HF2.upd.ops' | wc -l | tr -d ' ')\" = 13 ] && ! awk '\$2 == \"mv\"' '$HF2.upd.ops' | grep -qE 'motions/M2/(01[1-9]|02[0-3]).png.partial'"
FLUSH_CHUNK_T=13 FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HF2" "$R_V2"
check "1c: ... update again finishes it (exit 0, the pictures are the repo's, no .partial left)" bash -c "[ '$RC' -eq 0 ] && ! find '$HF2' -name '*.partial' | grep -q ." 
check "1c: ... and the art equals the source" same_art "$R_V2" "$HF2"
install_home setfail-dir "$R_V2"; HG2="$H"; RG2="$R"; set_generation 4
for rel in "${set_rels[@]}"; do printf 'x' >> "$RG2/art/$rel"; done
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$RG2/art/looks/L2" run_update "$HG2" "$R_V2"
check "1c: the flush of a set's directories fails: exit 2 and it says so (all 32 renames are done, the update can be repeated)" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'could not flush the directories of the 32-file set' && printf '%s' \"\$1\" | grep -q 'update stopped partway' && [ \"\$(awk '\$2 == \"mv\" && index(\$0, \".png.partial\")' '$HG2.upd.ops' | wc -l | tr -d ' ')\" = 32 ]" _ "$OUT"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HG2" "$R_V2"
check "1c: ... update again finishes it (exit 0, the art equals the source)" bash -c "[ '$RC' -eq 0 ]"
check "1c: ... and the art equals the source" same_art "$R_V2" "$HG2"
check "1c: ... the re-run finds every picture renamed and matching, renames none, and still flushes the directory whose flush had failed (looks/L2): a rename that was not flushed is not left to a power cut" bash -c "! awk '\$2 == \"mv\"' '$HG2.upd.ops' | grep -q '.png.partial' && grep -qxF 'flush $RG2/art/looks/L2' '$HG2.upd.ops'"
# what depends on a set waits for it: the catalogs name pictures, so a picture directory that cannot be flushed stops the update before any catalog is renamed
install_home catalogwait "$R_BASE"; HW="$H"; RW="$R"; set_generation 2
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$RW/art/motions/M1" run_update "$HW" "$R_V2"
check "1c: the picture directory cannot be flushed: exit 2, the picture was renamed, no catalog and no executable was" bash -c "[ '$RC' -eq 2 ] && awk '\$2 == \"mv\"' '$HW.upd.ops' | grep -q 'motions/M1/001.png.partial' && ! awk '\$2 == \"mv\"' '$HW.upd.ops' | grep -qE 'clawd-atlas.json.partial|claude-code-elements.json.partial|clawd-pet-agent.partial|bin/clawd-pet.partial'"
check "1c: ... the installed catalogs are still the old ones (the pictures they name are all there either way)" bash -c "cmp -s '$R_BASE/art/clawd-atlas.json' '$RW/art/clawd-atlas.json' && cmp -s '$R_BASE/art/claude-code-elements.json' '$RW/art/claude-code-elements.json'"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HW" "$R_V2"
check "1c: ... update again finishes it (exit 0, the art equals the source)" bash -c "[ '$RC' -eq 0 ]"
check "1c: ... the art is the new version's" same_art "$R_V2" "$HW"
check "1c: ... the re-run finds every picture renamed and matching, so it renames none (the premise of the next check)" bash -c "! awk '\$2 == \"mv\"' '$HW.upd.ops' | grep -q '.png.partial' && awk '\$2 == \"mv\"' '$HW.upd.ops' | grep -q 'art/clawd-atlas.json.partial'"
check "1c: ... and it flushes the picture directory whose flush had failed BEFORE it renames the first catalog (a catalog never goes in on a picture whose rename may be lost)" bash -c "awk '/^flush / && \$0 == \"flush $RW/art/motions/M1\" && !d { d = NR } \$2 == \"mv\" && index(\$0, \"art/clawd-atlas.json.partial\") && !c { c = NR } END { exit (d && c && d < c) ? 0 : 1 }' '$HW.upd.ops'"
check "1c: ... by then every directory of the art tree is flushed (art/frames, art/motions, motions/M1, motions/M2, looks/L2)" bash -c "awk '\$2 == \"mv\" && index(\$0, \"art/clawd-atlas.json.partial\") && !c { c = NR } /^flush / && !c { before[\$0] = 1 } END { exit (before[\"flush $RW/art/motions/M1\"] && before[\"flush $RW/art/looks/L2\"] && before[\"flush $RW/art/motions/M2\"] && before[\"flush $RW/art/frames\"] && before[\"flush $RW/art/motions\"]) ? 0 : 1 }' '$HW.upd.ops'"
# the art tree's own flush fails: nothing that names the pictures, and no executable, is put in place; the re-run finishes
install_home arttree "$R_BASE"; HT="$H"; RT="$R"; set_generation 2
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$RT/art/looks/L1" run_update "$HT" "$R_V2"
check "1c: the flush of the art tree's directories fails: exit 2, it says so, every picture is renamed, no catalog and no executable is" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'could not flush the directories of .*/art to the disk; the catalogs, the agent and the CLI were not moved into place' && printf '%s' \"\$1\" | grep -q 'update stopped partway' && [ \"\$(awk '\$2 == \"mv\" && index(\$0, \".png.partial\")' '$HT.upd.ops' | wc -l | tr -d ' ')\" = 33 ] && ! awk '\$2 == \"mv\"' '$HT.upd.ops' | grep -qE 'clawd-atlas.json.partial|claude-code-elements.json.partial|clawd-pet-agent.partial|bin/clawd-pet.partial'" _ "$OUT"
check "1c: ... the installed catalogs, agent and CLI are still the old ones" bash -c "cmp -s '$R_BASE/art/clawd-atlas.json' '$RT/art/clawd-atlas.json' && cmp -s '$R_BASE/build/clawd-pet-agent' '$RT/bin/clawd-pet-agent' && cmp -s '$R_BASE/bin/clawd-pet' '$HT/bin/clawd-pet'"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HT" "$R_V2"
check "1c: ... update again finishes it (exit 0, the art, the agent and the CLI are the new version's, no .partial is left)" bash -c "[ '$RC' -eq 0 ] && ! find '$HT' -name '*.partial' | grep -q . && cmp -s '$R_V2/build/clawd-pet-agent' '$RT/bin/clawd-pet-agent' && cmp -s '$R_V2/bin/clawd-pet' '$HT/bin/clawd-pet'"
check "1c: ... and the art is the new version's" same_art "$R_V2" "$HT"

# the helper itself: the real text of flush_durable, taken out of the CLI
eval "$(awk '/^FLUSH_PERL=/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO/bin/clawd-pet")"
bounded() { # seconds, then a command: its status, or 124 when it did not end in time (it is then killed)
  local limit="$1" pid n=0; shift
  "$@" > /dev/null 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    [ "$n" -lt $((limit * 20)) ] || { kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 0.05; n=$((n + 1))
  done
  wait "$pid"
}
FD="$STAGE/flush-unit"; mkdir -p "$FD/dir" || exit 2
printf 'data\n' > "$FD/file"; ln -s "$FD/file" "$FD/link"; mkfifo "$FD/fifo"
check "1b: flush_durable was found in the CLI, and it uses the system perl unless a test says otherwise" bash -c "[ '$FLUSH_PERL' = /usr/bin/perl ]"
check "1b: ... as a function" type flush_durable
flush_out="$(flush_durable "$FD/file" 2>&1)"; flush_rc=$?
check "1b: helper: a regular file is flushed (exit 0, no output)" bash -c "[ '$flush_rc' -eq 0 ] && [ -z \"\$1\" ]" _ "$flush_out"
flush_out="$(flush_durable "$FD/dir" 2>&1)"; flush_rc=$?
check "1b: helper: a directory is flushed (exit 0)" test "$flush_rc" -eq 0
flush_out="$(flush_durable "$FD/file" "$FD/dir" 2>&1)"; flush_rc=$?
check "1b: helper: several paths at once are flushed (exit 0)" test "$flush_rc" -eq 0
flush_out="$(flush_durable 2>&1)"; flush_rc=$?
check "1b: helper: no path at all is nothing to flush (exit 0)" test "$flush_rc" -eq 0
flush_out="$(flush_durable "$FD/missing" 2>&1)"; flush_rc=$?
check "1b: helper: a missing path fails (exit 1) and names it" bash -c "[ '$flush_rc' -eq 1 ] && printf '%s' \"\$1\" | grep -qF '$FD/missing'" _ "$flush_out"
flush_out="$(flush_durable "$FD/link" 2>&1)"; flush_rc=$?
check "1b: helper: a symlink is refused, not followed (exit 1)" test "$flush_rc" -eq 1
flush_out="$(flush_durable /dev/null 2>&1)"; flush_rc=$?
check "1b: helper: a device is refused (exit 1, 'not a regular file or a directory')" bash -c "[ '$flush_rc' -eq 1 ] && printf '%s' \"\$1\" | grep -q 'not a regular file or a directory'" _ "$flush_out"
bounded 5 flush_durable "$FD/fifo"; flush_rc=$?
: <> "$FD/fifo"          # a helper that did block on the FIFO (a broken one) is let go: opening it read-write never blocks and counts as the writer it waits for
check "1b: helper: a FIFO is refused at once, it never blocks the CLI waiting for a writer (exit 1 within 5 s)" test "$flush_rc" -eq 1
flush_out="$(flush_durable "$FD/file" "$FD/missing" "$FD/dir" 2>&1)"; flush_rc=$?
check "1b: helper: one bad path among good ones fails the call (exit 1) and only that path is named" bash -c "[ '$flush_rc' -eq 1 ] && printf '%s' \"\$1\" | grep -qF '$FD/missing' && ! printf '%s' \"\$1\" | grep -qF '$FD/file' && ! printf '%s' \"\$1\" | grep -qF '$FD/dir'" _ "$flush_out"
# the command it sends is the kernel's F_FULLFSYNC: the SDK's header gives the number, and the kernel accepts it on a regular file where it refuses an unknown one
sdk_header=""
for h in /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/fcntl.h /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/sys/fcntl.h /usr/include/sys/fcntl.h; do
  [ -f "$h" ] && { sdk_header="$h"; break; }
done
if [ -n "$sdk_header" ]; then
  header_n="$(sed -n 's/^#define[[:space:]]*F_FULLFSYNC[[:space:]]*\([0-9]*\).*/\1/p' "$sdk_header")"
  script_n="$(sed -n 's/.*fcntl(\$fh, \([0-9]*\), 0).*/\1/p' "$REPO/bin/clawd-pet" | head -n 1)"
  check "1b: helper: the number it passes to fcntl ($script_n) is the SDK's F_FULLFSYNC ($header_n)" test -n "$header_n" -a "$header_n" = "$script_n"
else
  echo "NOTE: no SDK header found; the number of F_FULLFSYNC was not compared with <sys/fcntl.h>"
fi
bad_command_out="$(eval "$(awk '/^FLUSH_PERL=/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO/bin/clawd-pet" | sed 's/fcntl(\$fh, 51, 0)/fcntl($fh, 9999, 0)/')"; flush_durable "$FD/file" 2>&1)"; bad_command_rc=$?
check "1b: helper: when the kernel refuses the flush command the call fails (exit 1) and says F_FULLFSYNC failed" bash -c "[ '$bad_command_rc' -eq 1 ] && printf '%s' \"\$1\" | grep -q 'F_FULLFSYNC failed'" _ "$bad_command_out"
kernel="$(/usr/bin/perl -e 'open(F, "<", $ARGV[0]) or die; print((defined(fcntl(F, 51, 0)) ? "F_FULLFSYNC accepted" : "refused"), "; ", (defined(fcntl(F, 9999, 0)) ? "an unknown command accepted" : "an unknown command refused"))' "$FD/file")"
check "1b: helper: the kernel accepts command 51 on a regular file and refuses an unknown command number (so the call is not a no-op that always succeeds)" test "$kernel" = "F_FULLFSYNC accepted; an unknown command refused"

# ---- 1d. the chat page (Stage 2): chat-page/ of the repo goes to $ROOT/chat-page, and a changed page file needs no restart ------------------------------
R_P1="$STAGE/repo-page1"; make_repo "$R_P1" page=1
R_P2="$STAGE/repo-page2"; make_repo "$R_P2" page=2
same_page() { # repo home: every file of the repo's chat-page/ is installed byte for byte, and nothing else is in the installed directory
  local rel ok=0 count
  for rel in "${PAGE_FILES[@]}"; do cmp -s "$1/chat-page/$rel" "$2/Library/Application Support/clawd-pet/chat-page/$rel" || { ok=1; echo "differs: $rel"; }; done
  count="$(find "$2/Library/Application Support/clawd-pet/chat-page" -type f | wc -l | tr -d ' ')"
  [ "$count" = "${#PAGE_FILES[@]}" ] || { ok=1; echo "holds $count files"; }
  return $ok
}
install_home page "$R_P1"; HG="$H"; RG="$R"; set_generation 2
check "1d: an install from a repo with a chat-page/ puts its 8 files in chat-page/ byte for byte and nothing else there" same_page "$R_P1" "$HG"
check "1d: ... the manifest lists the directory and every file once" bash -c "grep -qxF 'dir $RG/chat-page' '$RG/manifest' && [ \"\$(grep -c '^file $RG/chat-page/' '$RG/manifest')\" = 8 ] && [ -z \"\$(grep '^file ' '$RG/manifest' | sort | uniq -d)\" ]"
run_update "$HG" "$R_P1"
check "1d: an update with nothing changed says it is up to date, restarts nothing, and leaves the page alone" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date' && [ \"\$(grep -c '^launchctl kickstart -k ' '$HG.calls')\" = 0 ]" _ "$OUT"
run_update "$HG" "$R_P2"
check "1d: an update whose page differs by one file exits 0 and says 0 added and 1 replaced" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'chat page 0 added and 1 replaced'" _ "$OUT"
check "1d: ... the page is the repo's again, byte for byte" same_page "$R_P2" "$HG"
check "1d: ... the agent was not restarted (the page is read at every open): no kickstart, and it says so" bash -c "[ \"\$(grep -c '^launchctl kickstart -k ' '$HG.calls')\" = 0 ] && printf '%s' \"\$1\" | grep -q 'was not restarted'" _ "$OUT"
check "1d: ... the replaced file went through its .partial name, and no .partial is left" bash -c "awk '\$2 == \"cp\"' '$HG.upd.ops' | grep -q 'chat-page/index.html.partial' && ! find '$HG' -name '*.partial' | grep -q ."
check "1d: ... the update renamed nothing outside chat-page/ and the manifest: no art file, agent or CLI" bash -c "! awk '\$2 == \"mv\"' '$HG.upd.ops' | grep -vE 'chat-page/|manifest' | grep -q ."
rm -- "$RG/chat-page/page.css"
run_update "$HG" "$R_P2"
check "1d: a page file that was deleted from the install is added again (1 added, 0 replaced)" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'chat page 1 added and 0 replaced'" _ "$OUT"
check "1d: ... and the page is complete again" same_page "$R_P2" "$HG"
uninstall_home "$HG" "$R_P2"
check "1d: one uninstall removes the page with the rest (exit 0) and the tree is as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HG")" "$(cat "$HG.pre.tree")"
# an install made before the page existed adopts it at the next update: the directory and files are added to the manifest first
install_home nopage "$R_BASE"; HN="$H"; RN="$R"; set_generation 2
check "1d: a repo without chat-page/ installs without one" test ! -e "$RN/chat-page"
run_update "$HN" "$R_P1"
check "1d: update from a repo that has a page adds it to an install that has none (8 added) without a restart" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'chat page 8 added and 0 replaced' && [ \"\$(grep -c '^launchctl kickstart -k ' '$HN.calls')\" = 0 ]" _ "$OUT"
check "1d: ... the page is installed" same_page "$R_P1" "$HN"
check "1d: ... and the manifest names the directory and its 8 files" bash -c "grep -qxF 'dir $RN/chat-page' '$RN/manifest' && [ \"\$(grep -c '^file $RN/chat-page/' '$RN/manifest')\" -ge 8 ]"
uninstall_home "$HN" "$R_P1"
check "1d: ... and one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HN")" "$(cat "$HN.pre.tree")"
# a source whose chat-page/ lacks a file is refused, before anything is changed
R_P3="$STAGE/repo-page3"; make_repo "$R_P3" page=3; rm -- "$R_P3/chat-page/marked.min.js"
install_home pagerefuse "$R_P1"; HR="$H"; RR="$R"; set_generation 2; before_page_refuse="$(tree "$HR")"
run_update "$HR" "$R_P3"
check "1d: a source chat-page/ with a file missing is refused: exit 2, it names the file, and nothing was changed" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'chat page incomplete: chat-page/marked.min.js' && [ \"\$2\" = \"\$3\" ]" _ "$OUT" "$(tree "$HR")" "$before_page_refuse"
uninstall_home "$HR" "$R_P1"
check "1d: ... the install is still removable (exit 0)" test "$RC" -eq 0

# ---- 2. when the agent is restarted ----------------------------------------------------------------------------------------------
# nothing changed
install_home same "$R_BASE"; t0="$(tree "$H")"
run_update "$H" "$R_BASE"
check "2: nothing changed: exit 0 and 'already up to date'" bash -c "[ '$RC' -eq 0 ]; printf '%s' '$OUT' | grep -q 'already up to date'"
check "2: ... no file anywhere changed" test "$(tree "$H")" = "$t0"
check "2: ... not one cp, mv, mkdir or chmod was run" test "$(cat "$H.upd.count")" = 0
check "2: ... nothing was restarted (only list)" test "$(verbs_other_than_list "$H")" = 0
# pictures the install lacks (item 0's case): added, and the agent is NOT restarted
install_home missing "$R_BASE"; full_tree="$(tree "$H" | grep -v '/clawd-pet/manifest$')"; full_manifest="$(LC_ALL=C sort "$R/manifest")"
rm -f -- "$R/art/motions/M1/000.png" "$R/art/looks/L1/layer.png" "$R/art/frames/f2.png"
run_update "$H" "$R_BASE"
check "2: three pictures missing from the install: update restores them (exit 0)" test "$RC" -eq 0
check "2: ... the tree equals the tree of the intact install (the manifest apart)" test "$(tree "$H" | grep -v '/clawd-pet/manifest$')" = "$full_tree"
check "2: ... the manifest is the intact install's plus the three .partial names the restored pictures went through, and nothing else" test "$(LC_ALL=C sort "$R/manifest" | LC_ALL=C comm -3 <(printf '%s\n' "$full_manifest") - | tr -d '\t')" = "$(printf 'file %s/art/%s.partial\n' "$R" frames/f2.png "$R" looks/L1/layer.png "$R" motions/M1/000.png)"
check "2: ... the agent was not restarted (a picture it never read needs no restart)" bash -c "[ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
check "2: ... and it says why" contains "$OUT" "nothing the running agent has read changed"
# the same restore, its directory flush failing after the rename: it needed no restart, so it left no marker, and the re-run finds the
# picture in place and has nothing to place; it must still flush that directory before it says "already up to date"
install_home fillcut "$R_BASE"; HX="$H"; RX="$R"
rm -f -- "$RX/art/motions/M1/000.png"
FLUSH_STUB_PATH="$STUBS/perl-flush" FLUSH_FAIL_EXACT="$RX/art/motions/M1" run_update "$HX" "$R_BASE"
check "2: a restore whose directory flush fails: exit 2, the picture is renamed into place, no restart marker is left" bash -c "[ '$RC' -eq 2 ] && [ -f '$RX/art/motions/M1/000.png' ] && [ ! -e '$RX/restart-pending' ]"
FLUSH_STUB_PATH="$STUBS/perl-flush" run_update "$HX" "$R_BASE"
check "2: ... the re-run has nothing to place and says already up to date (the premise of the next check)" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date'" _ "$OUT"
check "2: ... and it still flushes the directory whose flush had failed (motions/M1) before it says so" grep -qxF "flush $RX/art/motions/M1" "$HX.upd.ops"
# one thing at a time
restart_case() { # name repo expect(restart|stay)
  install_home "$1" "$R_BASE"; set_generation 2
  run_update "$H" "$2"
  if [ "$3" = restart ]; then
    check "2: $1: a restart was sent (exactly one kickstart -k) and confirmed" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && printf '%s' '$OUT' | grep -q 'restarted the agent'"
  else
    check "2: $1: no restart (exit 0, no kickstart)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
  fi
}
restart_case agent-only "$R_AGENT" restart
check "2: agent-only: the agent is replaced and the CLI and the art are not" bash -c "cmp -s '$R_AGENT/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && cmp -s '$R_BASE/bin/clawd-pet' '$H/bin/clawd-pet' && cmp -s '$R_BASE/art/motions/M1/001.png' '$R/art/motions/M1/001.png'"
restart_case picture-only "$R_PIC" restart
check "2: picture-only: the picture is replaced through a .partial name and a rename" bash -c "awk '\$2 == \"cp\"' '$H.upd.ops' | grep -qE 'art/motions/M1/001.png.partial\$' && awk '\$2 == \"mv\"' '$H.upd.ops' | grep -qE 'art/motions/M1/001.png.partial .*art/motions/M1/001.png\$' && cmp -s '$R_PIC/art/motions/M1/001.png' '$R/art/motions/M1/001.png'"
restart_case catalog-only "$R_CAT" restart
check "2: catalog-only: the new pictures it names are installed and both catalogs replaced" same_art "$R_CAT" "$H"
restart_case cli-only "$R_CLI" stay
check "2: cli-only: the CLI is replaced and the agent is not" bash -c "cmp -s '$R_CLI/bin/clawd-pet' '$H/bin/clawd-pet' && cmp -s '$R_BASE/build/clawd-pet-agent' '$R/bin/clawd-pet-agent'"
# --restart
install_home forced "$R_BASE"; set_generation 3
run_update "$H" "$R_BASE" --restart
check "2: --restart with nothing changed restarts the loaded agent (exit 0, one kickstart -k)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"
run_update "$H" "$R_BASE" --bogus
check "2: an unknown option is refused (exit 2)" test "$RC" -eq 2
run_update "$H" "$R_BASE" now
check "2: an extra word is refused (exit 2)" test "$RC" -eq 2
# not loaded
install_home idle "$R_BASE"; rm -f -- "$H.loaded" "$H.loaded.pid"
run_update "$H" "$R_V2"
check "2: the agent is not running: exit 0, files updated, nothing sent to launchd but list" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
check "2: ... and it says the next start runs the new build" contains "$OUT" "'clawd-pet start' runs the new build"
check "2: ... the new agent and art are in place" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent'"

# ---- 3. the wait for the restarted agent -----------------------------------------------------------------------------------------
# The old agent's status.json stays in the file until the new process replaces it, with the old pid and an appliedGeneration that is already
# high enough: a wait on the generation alone would confirm at once. Update waits for a NEW pid whose status.json names it.
wait_case() { # name mode expect_rc expected_text
  install_home "wait-$1" "$R_BASE"; set_generation 5
  KICK_MODE="$2" WAIT_S=2 run_update "$H" "$R_V2"
  check "3: $1: exit $3" test "$RC" -eq "$3"
  if [ -n "$4" ]; then check "3: $1: says $4" contains "$OUT" "$4"; fi
  check "3: $1: the files are in place whatever the restart did (agent, CLI, art)" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && cmp -s '$R_V2/bin/clawd-pet' '$H/bin/clawd-pet' && [ -f '$R/art/motions/M2/029.png' ]"
  check "3: $1: the plist and the launcher were still not touched" test "$(ops_naming "$H" "$NEVER_TOUCHED")" = 0
}
wait_case ok ok 0 "restarted the agent (pid 4242 -> 4243); it applied settings generation 5"
install_home wait-delayed "$R_BASE"; set_generation 5
KICK_MODE=delayed KICK_DELAY=1 WAIT_S=6 run_update "$H" "$R_AGENT"
holders+=("$(cat "$H.loaded.bg" 2>/dev/null | tail -n 1)")
check "3: delayed: exit 0, and it waited for the new agent (about 1 s)" bash -c "[ '$RC' -eq 0 ] && [ '$ELAPSED' -ge 900 ] && [ '$ELAPSED' -lt 5500 ]"
wait_case no-new-process nopid 3 "launchd shows no new agent process"
wait_case old-status-only silent 3 "has not yet written its pid"
wait_case status-without-a-pid nopidfield 3 "has not yet written its pid"
wait_case stale-generation stale 3 "has not applied generation 5"
wait_case kickstart-fails fail 2 "launchctl kickstart -k failed"
check "3: kickstart-fails: the message gives the way out ('clawd-pet stop' and 'clawd-pet start')" contains "$OUT" "clawd-pet stop"
check "3: kickstart-fails: it does not say that running update again finishes the job (every file is in place; update would find nothing)" lacks "$OUT" "running update again finishes it"
install_home wait-message "$R_BASE"; set_generation 5
KICK_MODE=silent WAIT_S=1 run_update "$H" "$R_V2"
check "3: a failed wait says the files are updated, names the seconds it waited, and points at 'clawd-pet status'" bash -c "printf '%s' \"\$1\" | grep -q 'the files are updated' && printf '%s' \"\$1\" | grep -q 'within 1 s' && printf '%s' \"\$1\" | grep -q 'clawd-pet status'" _ "$OUT"

# A signal while it waits for the restarted agent: the files are all in place, so the message is about the restart, not about running update again.
install_home wait-signal "$R_BASE"; set_generation 5
echo 0 > "$H.upd.count"; : > "$H.upd.ops"; : > "$H.calls"
( env HOME="$H" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" STUB_KICK_MODE=delayed STUB_KICK_DELAY=30 \
    CLAWD_BUILD_DIR="$R_V2/build" CLAWD_RESTART_WAIT_S=40 "$CLI_BASH" -c 'echo $$ > "$1"; shift; exec "$@"' sh "$H.sig.pid" "$CLI_BASH" "$R_V2/bin/clawd-pet" update ) > "$H.sig.out" 2>&1 &
sig_bg=$!; holders+=("$sig_bg")
wait_until 600 grep -q '^launchctl kickstart -k ' "$H.calls"
sig_pid="$(cat "$H.sig.pid" 2>/dev/null)"
check "3: a signal while it waits: the update is waiting (the restart was sent, the new agent has not answered)" bash -c "[ -n '$sig_pid' ] && kill -0 '$sig_pid' 2>/dev/null && grep -q '^launchctl kickstart -k ' '$H.calls'"
kill -TERM "$sig_pid" 2>/dev/null
wait "$sig_bg" 2>/dev/null; sig_rc=$?
check "3: ... TERM stops it with 143" test "$sig_rc" -eq 143
check "3: ... and says the files are in place and 'clawd-pet update --restart' restarts the agent (not that update finishes the job)" bash -c "grep -q 'every file was already in place' '$H.sig.out' && grep -q 'update --restart' '$H.sig.out' && ! grep -q 'running update again finishes it' '$H.sig.out'"
check "3: ... the new files are in place" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && [ -f '$R/art/motions/M2/029.png' ]"
for p in $(cat "$H.loaded.bg" 2>/dev/null); do holders+=("$p"); done

# A copy that "succeeds" and is wrong (the shim appends one byte after a cp): update proves what it installed, and does not restart onto it.
n_pic_cp="$(awk '$2 == "cp" && index($0, "motions/M2/") { print $1; exit }' "$HF.upd.ops")"
n_agent_cp="$(awk '$2 == "cp" && substr($0, length($0) - 28) ~ /clawd-pet-agent.partial$/ { print $1; exit }' "$HF.upd.ops")"
check "3: the operation numbers of the picture copy and the agent copy were found in the full update's log" bash -c "[ -n '$n_pic_cp' ] && [ -n '$n_agent_cp' ]"
install_home spoiled-picture "$R_BASE"; set_generation 2
CORRUPT_AT="$n_pic_cp" run_update "$H" "$R_V2"
check "3: a picture copy spoiled after a successful cp: exit 2, says the installed art differs from the source" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'differs from the source after the copy'" _ "$OUT"
check "3: ... nothing was restarted onto it" test "$(verbs_other_than_list "$H")" = 0
run_update "$H" "$R_V2"
check "3: ... running update again repairs it (exit 0, the art equals the source, the agent is restarted)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"
check "3: ... the art equals the source" same_art "$R_V2" "$H"
install_home spoiled-agent "$R_BASE"; set_generation 2
CORRUPT_AT="$n_agent_cp" run_update "$H" "$R_V2"
check "3: an agent copy spoiled after a successful cp: exit 2, says the copy does not match the sha256 of its source" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'does not match the recorded sha256 of its source'" _ "$OUT"
check "3: ... the spoiled copy never got the agent's name (the installed agent is still the old build)" bash -c "cmp -s '$R_BASE/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && [ -f '$R/bin/clawd-pet-agent.partial' ]"
check "3: ... and nothing was restarted" test "$(verbs_other_than_list "$H")" = 0
run_update "$H" "$R_V2"
check "3: ... running update again finishes (exit 0, new agent in place, no .partial left, one restart)" bash -c "[ '$RC' -eq 0 ] && cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && ! find '$H' -name '*.partial' | grep -q . && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"

# ---- 4. refusals: each leaves every file as it was, and the same update goes through once the cause is repaired -------------------------
refusal() { # name expected-text damage-function repair-function [repo]
  local name="$1" text="$2" damage="$3" repair="$4" repo="${5:-$R_V2}" before
  install_home "ref-$name" "$R_BASE"
  "$damage"
  before="$(tree "$H")"
  run_update "$H" "$repo"
  check "4: $name: refused with exit 2" test "$RC" -eq 2
  check "4: $name: says why ($text)" contains "$OUT" "$text"
  check "4: $name: not one file changed" test "$(tree "$H")" = "$before"
  check "4: $name: not one copy, move or directory (the update changed nothing)" bash -c "! awk '\$2 == \"cp\" || \$2 == \"mv\" || \$2 == \"mkdir\" || \$2 == \"chmod\"' '$H.upd.ops' | grep -q ."
  check "4: $name: nothing was sent to launchd but list" test "$(verbs_other_than_list "$H")" = 0
  "$repair"
  run_update "$H" "$repo"
  check "4: $name: after the repair the same update succeeds (the refusal was about that cause)" test "$RC" -eq 0
}
noop() { :; }
# the launcher
damage_launcher_bytes() { printf 'X' >> "$R/bin/clawd-pet-launch"; }
repair_launcher_bytes() { cp "$R_BASE/launcher/clawd-pet-launch" "$R/bin/clawd-pet-launch.fix" && mv "$R/bin/clawd-pet-launch.fix" "$R/bin/clawd-pet-launch"; }
refusal launcher-bytes-differ "is not the one recorded in launcher/clawd-pet-launch.sha256" damage_launcher_bytes repair_launcher_bytes
damage_launcher_symlink() { mv "$R/bin/clawd-pet-launch" "$R/bin/launch.real" && ln -s launch.real "$R/bin/clawd-pet-launch"; }
repair_launcher_symlink() { rm -f -- "$R/bin/clawd-pet-launch" && mv "$R/bin/launch.real" "$R/bin/clawd-pet-launch"; }
refusal launcher-is-a-symlink "symlink" damage_launcher_symlink repair_launcher_symlink
# a repo whose launcher was rebuilt: its record (and its binary) differ from the installed launcher
R_NEWLAUNCH="$STAGE/repo-newlaunch"; make_repo "$R_NEWLAUNCH" agent=2 cli=2 pic=2 cat=2
printf 'rebuilt launcher\n' >> "$R_NEWLAUNCH/launcher/clawd-pet-launch"; chmod 755 "$R_NEWLAUNCH/launcher/clawd-pet-launch"
printf '%s  clawd-pet-launch\n' "$(/usr/bin/shasum -a 256 < "$R_NEWLAUNCH/launcher/clawd-pet-launch" | cut -d' ' -f1)" > "$R_NEWLAUNCH/launcher/clawd-pet-launch.sha256"
install_home newlauncher "$R_BASE"; before="$(tree "$H")"
run_update "$H" "$R_NEWLAUNCH"
check "4: a repo with a rebuilt launcher (a different recorded sha256): refused with exit 2" test "$RC" -eq 2
check "4: ... says the installed launcher is not the recorded one and that this is a different background item" bash -c "printf '%s' \"\$1\" | grep -q 'is not the one recorded' && printf '%s' \"\$1\" | grep -q 'background item'" _ "$OUT"
check "4: ... the tree is exactly what it was" test "$(tree "$H")" = "$before"
check "4: ... nothing was changed in the install and nothing was restarted" test "$(verbs_other_than_list "$H")" = 0
# a repo whose launcher binary does not match its own record
R_BADREC="$STAGE/repo-badrecord"; make_repo "$R_BADREC" agent=2
printf '%s  clawd-pet-launch\n' 0000000000000000000000000000000000000000000000000000000000000000 > "$R_BADREC/launcher/clawd-pet-launch.sha256"
install_home badrecord "$R_BASE"; before="$(tree "$H")"
run_update "$H" "$R_BADREC"
check "4: a repo launcher that does not match its own record: refused (exit 2) with the install's message" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'does not match launcher/clawd-pet-launch.sha256; nothing was changed'" _ "$OUT"
check "4: ... and nothing changed" test "$(tree "$H")" = "$before"
# the plist
damage_plist_names_agent() { sed "s|clawd-pet-launch|clawd-pet-agent|" "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist" > "$H.plist.new" && cp "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist" "$H.plist.good" && cp "$H.plist.new" "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist"; }
repair_plist_names_agent() { cp "$H.plist.good" "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist"; }
refusal plist-names-the-agent "does not name the installed launcher" damage_plist_names_agent repair_plist_names_agent
damage_plist_missing() { cp "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist" "$H.plist.good" && rm -f -- "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist"; }
repair_plist_missing() { cp "$H.plist.good" "$H/Library/LaunchAgents/com.tomtim.clawd-pet.plist"; }
refusal plist-missing "the LaunchAgent plist is missing" damage_plist_missing repair_plist_missing
# the manifest and the marker
damage_manifest_partial() { printf 'x\n' > "$R/manifest.partial"; }
repair_manifest_partial() { rm -f -- "$R/manifest.partial"; }
refusal manifest-partial-present "manifest.partial exists" damage_manifest_partial repair_manifest_partial
damage_marker_partial() { printf 'x\n' > "$H/Library/Application Support/clawd-pet.installing.partial"; }
repair_marker_partial() { rm -f -- "$H/Library/Application Support/clawd-pet.installing.partial"; }
refusal marker-partial-present "clawd-pet.installing.partial exists" damage_marker_partial repair_marker_partial
damage_manifest_no_end() { cp "$R/manifest" "$H.manifest.good"; sed '$d' "$H.manifest.good" > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"; }
repair_manifest_no_end() { cp "$H.manifest.good" "$R/manifest"; }
refusal manifest-without-its-end "the manifest is incomplete" damage_manifest_no_end repair_manifest_no_end
damage_manifest_unknown_line() { cp "$R/manifest" "$H.manifest.good"; { sed '$d' "$H.manifest.good"; echo 'frobnicate x'; echo end; } > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"; }
repair_manifest_unknown_line() { cp "$H.manifest.good" "$R/manifest"; }
refusal manifest-with-an-unknown-line "unknown manifest line" damage_manifest_unknown_line repair_manifest_unknown_line
damage_manifest_foreign_path() { cp "$R/manifest" "$H.manifest.good"; { sed '$d' "$H.manifest.good"; echo 'file /etc/passwd'; echo end; } > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"; }
repair_manifest_foreign_path() { cp "$H.manifest.good" "$R/manifest"; }
refusal manifest-names-a-path-outside-the-install "manifest path outside the installation" damage_manifest_foreign_path repair_manifest_foreign_path
damage_manifest_no_agent() { cp "$R/manifest" "$H.manifest.good"; grep -vxF "file $R/bin/clawd-pet-agent" "$H.manifest.good" > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"; }
repair_manifest_no_agent() { cp "$H.manifest.good" "$R/manifest"; }
refusal manifest-without-the-agent "does not list $STAGE/h-ref-manifest-without-the-agent/Library/Application Support/clawd-pet/bin/clawd-pet-agent" damage_manifest_no_agent repair_manifest_no_agent
damage_marker_missing() { cp "$H/Library/Application Support/clawd-pet.installing" "$H.marker.good" && rm -f -- "$H/Library/Application Support/clawd-pet.installing"; }
repair_marker_missing() { cp "$H.marker.good" "$H/Library/Application Support/clawd-pet.installing"; }
refusal install-marker-missing "install marker" damage_marker_missing repair_marker_missing
# the settings files
damage_control_missing() { cp "$R/control.json" "$H.control.good" && rm -f -- "$R/control.json"; }
repair_control_missing() { cp "$H.control.good" "$R/control.json"; }
refusal control-json-missing "control.json or control.lock is missing" damage_control_missing repair_control_missing
damage_lock_missing() { rm -f -- "$R/control.lock"; }
repair_lock_missing() { : > "$R/control.lock"; }
refusal control-lock-missing "control.json or control.lock is missing" damage_lock_missing repair_lock_missing
# the installed art
damage_art_symlink() { mv "$R/art/frames/f1.png" "$H.f1.real" && ln -s "$H.f1.real" "$R/art/frames/f1.png"; }
repair_art_symlink() { rm -f -- "$R/art/frames/f1.png" && mv "$H.f1.real" "$R/art/frames/f1.png"; }
refusal art-file-is-a-symlink "symlink" damage_art_symlink repair_art_symlink
damage_art_dir_is_file() { mv "$R/art/looks/L1/layer.png" "$H.layer.real" && mkdir "$R/art/looks/L1/layer.png"; }
repair_art_dir_is_file() { rmdir "$R/art/looks/L1/layer.png" && mv "$H.layer.real" "$R/art/looks/L1/layer.png"; }
refusal art-file-is-a-directory "is not a regular file" damage_art_dir_is_file repair_art_dir_is_file
damage_art_dir_symlink() { mv "$R/art/frames" "$H.frames.real" && ln -s "$H.frames.real" "$R/art/frames"; }
repair_art_dir_symlink() { rm -f -- "$R/art/frames" && mv "$H.frames.real" "$R/art/frames"; }
refusal art-directory-is-a-symlink "symlink" damage_art_dir_symlink repair_art_dir_symlink
damage_unlisted_symlink() { ln -s "$H.elsewhere" "$R/art/frames/f4.png"; }
repair_unlisted_symlink() { rm -f -- "$R/art/frames/f4.png"; }
refusal unlisted-art-path-is-a-symlink "symlink where an art file belongs" damage_unlisted_symlink repair_unlisted_symlink
# the source
install_home source "$R_BASE"; before="$(tree "$H")"
R_NOBUILD="$STAGE/repo-nobuild"; make_repo "$R_NOBUILD" agent=2; mv "$R_NOBUILD/build/clawd-pet-agent" "$R_NOBUILD/build/aside"
run_update "$H" "$R_NOBUILD"
check "4: the build is missing: refused (exit 2) naming it" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'build first'" _ "$OUT"
check "4: ... the tree is as it was" test "$(tree "$H")" = "$before"
R_MISSINGART="$STAGE/repo-missingart"; make_repo "$R_MISSINGART" agent=2 cat=2; rm -f -- "$R_MISSINGART/art/motions/M2/017.png"
run_update "$H" "$R_MISSINGART"
check "4: an atlas that names a picture the source lacks: refused (exit 2), naming it" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'art/motions/M2/017.png' && printf '%s' \"\$1\" | grep -q 'nothing was changed'" _ "$OUT"
check "4: ... and nothing changed" test "$(tree "$H")" = "$before"
R_BADPATH="$STAGE/repo-badpath"; make_repo "$R_BADPATH" agent=2 cat=2
mkdir -p "$R_BADPATH/art/motions/a b"; printf 'x\n' > "$R_BADPATH/art/motions/a b/000.png"
sed 's|"frames/f1.png"|"frames/f1.png","motions/a b/000.png"|' "$R_BADPATH/art/clawd-atlas.json" > "$R_BADPATH/atlas.new" && mv "$R_BADPATH/atlas.new" "$R_BADPATH/art/clawd-atlas.json"
run_update "$H" "$R_BADPATH"
check "4: an atlas path with a space: refused (exit 2) as unusable" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'unusable path'" _ "$OUT"
check "4: ... the tree is as it was" test "$(tree "$H")" = "$before"
# not installed, and not from the repo
mkdir -p "$STAGE/h-empty/bin" "$STAGE/h-empty/Library/LaunchAgents" "$STAGE/h-empty/Library/Application Support"
t0="$(tree "$STAGE/h-empty")"
run_update "$STAGE/h-empty" "$R_V2"
check "4: nothing installed: refused (exit 2) and nothing created" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'not installed'" _ "$OUT"
check "4: ... the empty home is still empty" test "$(tree "$STAGE/h-empty")" = "$t0"
install_home copy "$R_BASE"; before="$(tree "$H")"
OUT="$(env HOME="$H" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" "$CLI_BASH" "$H/bin/clawd-pet" update 2>&1)"; RC=$?
check "4: the installed copy of the CLI cannot update (it has no sources): exit 2" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'runs from the repo'" _ "$OUT"
check "4: ... and nothing changed" test "$(tree "$H")" = "$before"

# ---- 5. repeated updates, and the uninstall after them ----------------------------------------------------------------------------
install_home seq "$R_BASE"; HS="$H"; RS="$R"
set_generation 7
run_update "$HS" "$R_V2"; rc1=$RC
run_update "$HS" "$R_V3"; rc2=$RC; out2="$OUT"
check "5: base -> v2 -> v3: both updates exit 0" bash -c "[ '$rc1' -eq 0 ] && [ '$rc2' -eq 0 ]"
check "5: the second update says what it brought (the picture it added and the ones it replaced)" contains "$out2" "art 1 added and 3 replaced"
check "5: the installed art is the v3 tree, byte for byte" same_art "$R_V3" "$HS"
check "5: the manifest holds no line twice" bash -c "[ -z \"\$(grep -v '^logbase\|^schema\|^end' '$RS/manifest' | sort | uniq -d)\" ]"
check "5: every installed file is in the manifest" bash -c "cd '$RS' && find art -type f | while read -r f; do grep -qxF \"file $RS/\$f\" manifest || { echo \"unlisted: \$f\"; exit 1; }; done"
run_update "$HS" "$R_V3"
check "5: a third update with nothing to bring: 'already up to date', no operation, no restart" bash -c "[ '$RC' -eq 0 ] && printf '%s' '$OUT' | grep -q 'already up to date' && [ \"\$(cat '$HS.upd.count')\" = 0 ] && [ \"\$(grep -vc '^launchctl list ' '$HS.calls')\" = 0 ]"
uninstall_home "$HS" "$R_V3"
check "5: one uninstall after two updates exits 0" test "$RC" -eq 0
check "5: ... and the home equals the home before the install (every path and every checksum)" test "$(tree "$HS")" = "$(cat "$HS.pre.tree")"

# ---- 5b. a setting whose key only a restart applies -----------------------------------------------------------------------------
# The running agent (a stand-in with the agent's rule: Tests/stubs/status-writer-restart) compares the four restart-only keys of
# control.json (overFullScreen, releaseHintsEnabled, selectedInputKeyPath, idleBudgetMode) with the values it started with. When one
# differs it writes `restartRequired` and `restartGeneration` to status.json instead of confirming the generation. The CLI, waiting for its
# generation, sees that, restarts the agent once (kickstart -k, as v1 did for every setting) and waits for the NEW process to confirm.
start_applier() { # pid: the stand-in applier for $R, reporting that pid (it has taken its boot snapshot once status.json shows it)
  rm -f -- "$R/status.json"
  "$STUBS/status-writer-restart" "$R" "$1" >/dev/null 2>&1 & APPLIER=$!; holders+=("$APPLIER"); disown "$APPLIER" 2>/dev/null
  wait_until 200 grep -qs "\"pid\":$1" "$R/status.json"
}
stop_applier() { kill "$APPLIER" 2>/dev/null; /bin/sleep 0.1; }
settings_cli() { # home args... -> OUT, RC: a settings command of the base repo's CLI against the home
  local h="$1"; shift
  OUT="$(env HOME="$h" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$h.calls" STUB_STATE="$h.loaded" STUB_ROOT="$h/Library/Application Support/clawd-pet" \
    STUB_KICK_MODE="${KICK_MODE:-ok}" CLAWD_RESTART_WAIT_S="${WAIT_S:-4}" CLAWD_CONTROL_LOCK_WAIT_S="${SETTINGS_LOCK_WAIT_S:-10}" "$CLI_BASH" "$R_BASE/bin/clawd-pet" "$@" 2>&1)"; RC=$?
}
restart_key_case() { # key value-after plutil-type
  install_home "restart-$1" "$R_BASE"
  start_applier 4242
  : > "$H.calls"
  /usr/bin/plutil -replace "$1" "-$3" "$2" "$R/control.json"          # a hand edit: no generation, so the running agent has not seen it
  settings_cli "$H" walk off
  check "5b: $1 changed in control.json, then a setting: exit 0" test "$RC" -eq 0
  check "5b: $1: it says the agent was restarted and why" contains "$OUT" "applied (generation 1) after restarting the agent, because $1 is read only when the agent starts"
  check "5b: $1: exactly one restart was sent, with kickstart -k" bash -c "[ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 1 ]"
  check "5b: $1: status.json is the new process's: its pid and the generation applied" bash -c "grep -q '\"pid\":4243' '$R/status.json' && grep -q '\"appliedGeneration\":1' '$R/status.json' && ! grep -q restartRequired '$R/status.json'"
  stop_applier
}
restart_key_case overFullScreen true bool
restart_key_case releaseHintsEnabled true bool
restart_key_case selectedInputKeyPath other.input.id string
restart_key_case idleBudgetMode true bool
restart_key_case aquaReact false bool

# SA6: `aqua follow|ignore|auto` restarts the agent like any restart-only key. With aquaReact false in control.json (and at the agent's
# start) the new agent resolves the mode to ignore whatever is saved, and the line says what is in effect instead of "applied".
install_home restart-aqua-react-on "$R_BASE"; start_applier 4242; : > "$H.calls"
settings_cli "$H" aqua follow
check "5b: aqua follow restarts the agent once and says it was applied (React on): exit 0" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && printf '%s' '$OUT' | grep -q 'aqua follow: applied (generation 1) after restarting the agent, because aqua is read only when the agent starts'"
check "5b: ... and does not claim React is off" lacks "$OUT" "React is off"
stop_applier
install_home restart-aqua-react-off "$R_BASE"
/usr/bin/plutil -replace aquaReact -bool false "$R/control.json"
start_applier 4242; : > "$H.calls"
settings_cli "$H" aqua follow
check "5b: aqua follow with aquaReact false restarts the agent once: exit 0" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"
check "5b: ... and says saved; in effect: ignore (React is off)" contains "$OUT" "aqua follow: saved; in effect: ignore (React is off)"
check "5b: ... in place of the line that says it was applied" lacks "$OUT" "after restarting the agent"
check "5b: ... and aqua follow is what was saved" test "$(/usr/bin/plutil -extract aqua raw -o - "$R/control.json")" = follow
stop_applier

install_home restart-none "$R_BASE"; start_applier 4242; : > "$H.calls"
settings_cli "$H" walk off
check "5b: a live setting needs no restart: exit 0, applied, nothing sent but list" bash -c "[ '$RC' -eq 0 ] && printf '%s' '$OUT' | grep -q 'applied (generation 1)' && ! printf '%s' '$OUT' | grep -q 'restarting' && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
stop_applier

install_home restart-kick-fails "$R_BASE"; start_applier 4242; : > "$H.calls"
/usr/bin/plutil -replace overFullScreen -bool true "$R/control.json"
KICK_MODE=fail settings_cli "$H" walk off
check "5b: the restart cannot be sent: exit 3, saved, and the way out is named" bash -c "[ '$RC' -eq 3 ] && printf '%s' \"\$1\" | grep -q 'saved as generation 1' && printf '%s' \"\$1\" | grep -q 'overFullScreen only applies after a restart' && printf '%s' \"\$1\" | grep -q 'clawd-pet stop'" _ "$OUT"
stop_applier

install_home restart-unconfirmed "$R_BASE"; start_applier 4242; : > "$H.calls"
/usr/bin/plutil -replace overFullScreen -bool true "$R/control.json"
KICK_MODE=silent WAIT_S=1 settings_cli "$H" walk off
check "5b: the restarted agent does not confirm: exit 3 with the reason" bash -c "[ '$RC' -eq 3 ] && printf '%s' '$OUT' | grep -q 'restarted for overFullScreen but did not confirm within 1 s' && printf '%s' '$OUT' | grep -q 'has not yet written its pid'"
stop_applier

# A restart report for an OLDER generation is not about this write: the CLI keeps waiting for its own generation and restarts nothing.
install_home restart-older "$R_BASE"; set_generation 4
printf '{"focusViolations":0,"pid":4242,"appliedGeneration":4,"restartRequired":["overFullScreen"],"restartGeneration":3}\n' > "$R/status.json"
: > "$H.calls"
settings_cli "$H" walk off
check "5b: a report for generation 3 does not make a write of generation 5 restart the agent (exit 3 after 2 s, nothing sent but list)" bash -c "[ '$RC' -eq 3 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ] && printf '%s' '$OUT' | grep -q 'did not confirm it within 2 s'"
# ... and a report for the CLI's own generation (the next write is generation 6) does.
printf '{"focusViolations":0,"pid":4242,"appliedGeneration":4,"restartRequired":["overFullScreen"],"restartGeneration":6}\n' > "$R/status.json"
: > "$H.calls"
settings_cli "$H" walk on
check "5b: a report for the CLI's own generation restarts the agent once and the new process confirms it (exit 0)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && printf '%s' '$OUT' | grep -q 'applied (generation 6) after restarting the agent'"

# clawd-pet status shows what the agent reports
install_home status-lines "$R_BASE"
printf '{"focusViolations":0,"pid":4242,"appliedGeneration":3,"look":"plain","walk":true,"motion":"quiet","bubble":false,"restartRequired":["overFullScreen","idleBudgetMode"],"restartGeneration":4}\n' > "$R/status.json"
OUT="$(env HOME="$H" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" "$CLI_BASH" "$R_BASE/bin/clawd-pet" status 2>&1)"
check "5b: status prints the applied generation and the settings in effect" bash -c "printf '%s\n' \"\$1\" | grep -qx 'applied generation: 3' && printf '%s\n' \"\$1\" | grep -qx 'walk: true' && printf '%s\n' \"\$1\" | grep -qx 'motion: quiet' && printf '%s\n' \"\$1\" | grep -qx 'bubble: false' && printf '%s\n' \"\$1\" | grep -qx 'look: plain'" _ "$OUT"
check "5b: ... and the keys that wait for a restart, with their generation" contains "$OUT" "restart required: overFullScreen,idleBudgetMode (generation 4)"

# ---- 5c. the restart marker -----------------------------------------------------------------------------------------------------
# An update that must restart the agent creates $R/restart-pending (the manifest lists it first) before it copies its first file, and
# removes it once the restart is confirmed, or when the agent is not running. A cut anywhere in between leaves it, and a plain re-run
# restarts the agent even when every file is already current. (The cut-at-every-operation matrix is in Tests/install-interrupt.test.sh.)
# hold_update HOME REPO N: starts `update` in the background with the shim holding the call numbered N until <home>.hold.release exists, so
# the update stays inside its run for as long as the test wants; HOLD_PID is the update's own process, HOLD_BG the job to wait for.
hold_update() {
  local h="$1" repo="$2" at="$3"
  rm -f -- "$h.hold.ready" "$h.hold.release" "$h.hold.pid"; echo 0 > "$h.hold.count"; : > "$h.hold.ops"
  ( env HOME="$h" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$h.calls" STUB_STATE="$h.loaded" STUB_ROOT="$h/Library/Application Support/clawd-pet" \
      STUB_KICK_MODE=ok CLAWD_BUILD_DIR="$repo/build" CLAWD_RESTART_WAIT_S=20 OPSHIM_COUNT="$h.hold.count" OPSHIM_LOG="$h.hold.ops" \
      OPSHIM_WAIT_AT="$at" OPSHIM_WAIT_READY="$h.hold.ready" OPSHIM_WAIT_RELEASE="$h.hold.release" OPSHIM_WAIT_MAX=60 \
      "$CLI_BASH" -c 'echo $$ > "$1"; shift; exec "$@"' sh "$h.hold.pid" "$CLI_BASH" "$repo/bin/clawd-pet" update ) > "$h.hold.out" 2>&1 &
  HOLD_BG=$!; holders+=("$HOLD_BG")
  wait_until 1200 test -e "$h.hold.ready"
  HOLD_PID="$(cat "$h.hold.pid" 2>/dev/null)"; holders+=("$HOLD_PID")
}
release_update() { : > "$1.hold.release"; wait "$HOLD_BG" 2>/dev/null; HOLD_RC=$?; }

install_home pending-before-copy "$R_BASE"; set_generation 2
hold_update "$H" "$R_V2" "$n_mkdir"
check "5c: the update is held at its first mkdir (the manifest is published, no directory made yet)" bash -c "[ -n '$HOLD_PID' ] && kill -0 '$HOLD_PID' && [ -e '$H.hold.ready' ] && [ ! -d '$R/art/motions/M2' ]"
check "5c: ... the restart marker exists before the first copy" test -f "$R/restart-pending"
check "5c: ... and the manifest already lists it" grep -qxF "file $R/restart-pending" "$R/manifest"
release_update "$H"
check "5c: released, the update finishes (exit 0) and the confirmed restart removes the marker" bash -c "[ '$HOLD_RC' -eq 0 ] && [ ! -e '$R/restart-pending' ] && grep -q 'restarted the agent' '$H.hold.out'"
uninstall_home "$H" "$R_V2"
check "5c: ... and one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"

# a marker, every file current, the agent running: a plain update restarts it once, says why, removes the marker; then nothing is left to do
tree_but_marker_and_status() { tree "$1" | grep -v -e restart-pending -e status.json; }
install_home pending-rerun "$R_BASE"; set_generation 4
: > "$R/restart-pending"; before_files="$(tree_but_marker_and_status "$H")"
run_update "$H" "$R_BASE"; OUT_RERUN="$OUT"
check "5c: a marker with every file current: a plain update exits 0 and restarts the agent once (one kickstart -k, nothing else but list)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 1 ]"
check "5c: ... it says an earlier update was cut and names the pids" bash -c "printf '%s' \"\$1\" | grep -q 'an earlier update was cut before its restart was confirmed' && printf '%s' \"\$1\" | grep -q 'restarted the agent (pid 4242 -> 4243)'" _ "$OUT"
check "5c: ... the marker is gone, and no file but the marker and status.json changed" bash -c "[ ! -e '$R/restart-pending' ] && [ \"\$1\" = \"\$2\" ]" _ "$before_files" "$(tree_but_marker_and_status "$H")"
run_update "$H" "$R_BASE"
check "5c: ... and the next update has nothing to do: 'already up to date', no operation, no restart" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date' && [ \"\$(cat '$H.upd.count')\" = 0 ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]" _ "$OUT"

# the wording follows the facts: "restarted onto the installed files" only after the restart is confirmed, "restart pending" otherwise
check "5c: the confirmed re-run says 'restart pending' before it sends the restart and 'restarted onto the installed files' only after the confirmed restart" bash -c "
  out=\$1; pend=\$(printf '%s' \"\$out\" | grep -n 'restart pending' | head -n 1 | cut -d: -f1)
  done=\$(printf '%s' \"\$out\" | grep -n 'the agent is restarted onto the installed files' | head -n 1 | cut -d: -f1)
  conf=\$(printf '%s' \"\$out\" | grep -n 'restarted the agent (pid' | head -n 1 | cut -d: -f1)
  [ -n \"\$pend\" ] && [ -n \"\$done\" ] && [ -n \"\$conf\" ] && [ \"\$pend\" -lt \"\$conf\" ] && [ \"\$conf\" -lt \"\$done\" ]" _ "$OUT_RERUN"
install_home pending-rerun-unconfirmed "$R_BASE"; set_generation 4; : > "$R/restart-pending"
KICK_MODE=silent WAIT_S=1 run_update "$H" "$R_BASE"
check "5c: a re-run whose restart is not confirmed: exit 3, 'restart pending', and it never says the agent is restarted onto the installed files" bash -c "[ '$RC' -eq 3 ] && printf '%s' \"\$1\" | grep -q 'restart pending' && ! printf '%s' \"\$1\" | grep -q 'restarted onto the installed files'" _ "$OUT"
check "5c: ... the marker stays for the next update" test -f "$R/restart-pending"
install_home pending-rerun-kickfail "$R_BASE"; set_generation 4; : > "$R/restart-pending"
KICK_MODE=fail run_update "$H" "$R_BASE"
check "5c: a re-run whose restart cannot be sent: exit 2, 'restart pending', and it never says the agent is restarted onto the installed files" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'restart is still pending' && ! printf '%s' \"\$1\" | grep -q 'restarted onto the installed files'" _ "$OUT"

# a marker and an agent that is not running: nothing runs on the old files, so the marker goes without a restart
install_home pending-idle "$R_BASE"; rm -f -- "$H.loaded" "$H.loaded.pid"; : > "$R/restart-pending"
run_update "$H" "$R_BASE"
check "5c: a marker and no running agent: exit 0, the marker is removed, nothing sent to launchd but list" bash -c "[ '$RC' -eq 0 ] && [ ! -e '$R/restart-pending' ] && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
check "5c: ... and it says the next start runs the new build" contains "$OUT" "'clawd-pet start' runs the new build"

# a restart that is not confirmed keeps the marker; the next plain update restarts again and confirms
install_home pending-unconfirmed "$R_BASE"; set_generation 3
KICK_MODE=silent WAIT_S=1 run_update "$H" "$R_V2"
check "5c: a restart that is not confirmed: exit 3, the marker stays, and the message says another update restarts it again" bash -c "[ '$RC' -eq 3 ] && [ -f '$R/restart-pending' ] && printf '%s' \"\$1\" | grep -q 'running update again restarts the agent once more'" _ "$OUT"
check "5c: ... and it says the restart is pending (it never says the agent is restarted onto the installed files)" bash -c "printf '%s' \"\$1\" | grep -q 'restart pending' && ! printf '%s' \"\$1\" | grep -q 'restarted onto the installed files'" _ "$OUT"
run_update "$H" "$R_V2"
check "5c: ... the next plain update restarts the agent again and confirms it (exit 0, one kickstart -k, marker gone)" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && [ ! -e '$R/restart-pending' ] && printf '%s' \"\$1\" | grep -q 'restarted the agent (pid 4243 -> 4244)'" _ "$OUT"
install_home pending-kickfail "$R_BASE"; set_generation 3
KICK_MODE=fail run_update "$H" "$R_V2"
check "5c: a restart that cannot be sent: exit 2 and the marker stays" bash -c "[ '$RC' -eq 2 ] && [ -f '$R/restart-pending' ]"
run_update "$H" "$R_V2"
check "5c: ... and the next plain update sends it (exit 0, marker gone)" bash -c "[ '$RC' -eq 0 ] && [ ! -e '$R/restart-pending' ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"

# an update that needs no restart never creates the marker
install_home pending-none "$R_BASE"; set_generation 2
run_update "$H" "$R_CLI"
check "5c: a CLI-only update (no restart) leaves no marker" bash -c "[ '$RC' -eq 0 ] && [ ! -e '$R/restart-pending' ]"

# an install whose manifest does not list the marker yet: the update adds the line before it creates the file, so an uninstall removes it
drop_marker_line() { cp "$R/manifest" "$H.manifest.good" && grep -vxF "file $R/restart-pending" "$H.manifest.good" > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"; }
install_home pending-oldmanifest "$R_BASE"; set_generation 3; drop_marker_line
check "5c: (the old manifest lacks the marker line)" bash -c "! grep -qxF 'file $R/restart-pending' '$R/manifest'"
KICK_MODE=silent WAIT_S=1 run_update "$H" "$R_V2"
check "5c: an old manifest, an update that restarts: the line is added, the marker exists, exit 3 (unconfirmed)" bash -c "[ '$RC' -eq 3 ] && grep -qxF 'file $R/restart-pending' '$R/manifest' && [ -f '$R/restart-pending' ] && [ \"\$(grep -cxF 'file $R/restart-pending' '$R/manifest')\" = 1 ]"
uninstall_home "$H" "$R_V2"
check "5c: ... and one uninstall removes the marker too (the tree equals the tree before the install)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"
install_home pending-oldmanifest-idle "$R_BASE"; drop_marker_line
run_update "$H" "$R_BASE"
check "5c: an old manifest and nothing to restart: the line is added once (exit 0, no restart), then 'already up to date'" bash -c "[ '$RC' -eq 0 ] && grep -qxF 'file $R/restart-pending' '$R/manifest' && [ \"\$(grep -vc '^launchctl list ' '$H.calls')\" = 0 ]"
run_update "$H" "$R_BASE"
check "5c: ... the second run has nothing to do" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date' && [ \"\$(cat '$H.upd.count')\" = 0 ]" _ "$OUT"

damage_marker_directory() { mkdir "$R/restart-pending"; }
repair_marker_directory() { rmdir "$R/restart-pending"; }
refusal restart-marker-is-a-directory "restart-pending is not a regular file" damage_marker_directory repair_marker_directory
damage_marker_symlink() { ln -s "$H.elsewhere" "$R/restart-pending"; }
repair_marker_symlink() { rm -f -- "$R/restart-pending"; }
refusal restart-marker-is-a-symlink "symlink" damage_marker_symlink repair_marker_symlink

# ---- 5d. a stale manifest.partial -------------------------------------------------------------------------------------------------
# A cut after manifest.partial is created and before it is renamed leaves it beside the manifest. The update that finds it holds the lock,
# so no other update is writing it: when it is provably an update's leftover (the live manifest's lines in their order with only file and
# directory lines inside the install added just before the first log line, or any prefix of that) it is discarded, in one line, and the
# update goes on. Anything else is refused as before.
make_partial() { # kind: the file a cut update leaves, or something that merely has its name
  local live="$R/manifest" d="dir $R/art/motions/M9" f="file $R/art/motions/M9/000.png" out="$R/manifest.partial"
  case "$1" in
    complete) awk -v a="$d" -v b="$f" '!done && /^log / { print a; print b; done = 1 } { print }' "$live" > "$out" ;;
    empty) : > "$out" ;;
    prefix) head -n 7 "$live" > "$out" ;;
    prefix-into-the-added-lines) awk -v a="$d" '!done && /^log / { print a; done = 1; exit } { print }' "$live" > "$out" ;;
    outside-the-install) awk -v b="file /etc/passwd" '!done && /^log / { print b; done = 1 } { print }' "$live" > "$out" ;;
    after-the-end) { cat "$live"; echo "file $R/art/motions/M9/000.png"; } > "$out" ;;
    before-the-log-lines-of-another-position) awk -v b="$f" 'NR == 3 { print b } { print }' "$live" > "$out" ;;
    unknown-kind) awk '!done && /^log / { print "frobnicate x"; done = 1 } { print }' "$live" > "$out" ;;
    repeats-a-line) awk -v l="file $R/bin/clawd-pet-agent" '!done && /^log / { print l; done = 1 } { print }' "$live" > "$out" ;;
    reordered) awk 'NR == 2 { held = $0; next } NR == 3 { print; print held; next } { print }' "$live" > "$out" ;;
    another-install) /usr/bin/sed "s|$R|/Users/somebody/Library/Application Support/clawd-pet|g" "$live" > "$out" ;;
    foreign) printf 'not a manifest\n' > "$out" ;;
    symlink) cp "$live" "$H.partial.real" && ln -s "$H.partial.real" "$out" ;;
    directory) mkdir "$out" ;;
  esac
}
discard_case() { # name kind
  install_home "stale-$1" "$R_BASE"; set_generation 2
  make_partial "$2"
  run_update "$H" "$R_V2"
  check "5d: $1: the update exits 0 and says in one line that it discarded a stale manifest.partial" bash -c "[ '$RC' -eq 0 ] && [ \"\$(printf '%s\n' \"\$1\" | grep -c 'discarded a stale manifest.partial')\" = 1 ]" _ "$OUT"
  check "5d: $1: no manifest.partial is left, the pictures are the new ones, the agent was restarted once" bash -c "[ ! -e '$R/manifest.partial' ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"
  check "5d: $1: ... every file is the new build's" same_art "$R_V2" "$H"
  check "5d: $1: ... the manifest still ends with end and lists the new directories" bash -c "[ \"\$(tail -n 1 '$R/manifest')\" = end ] && grep -qxF 'dir $R/art/motions/M2' '$R/manifest' && ! grep -q 'motions/M9' '$R/manifest'"
  uninstall_home "$H" "$R_V2"
  check "5d: $1: one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"
}
discard_case a-complete-leftover complete
discard_case an-empty-file empty
discard_case a-prefix-of-the-live-lines prefix
discard_case a-cut-inside-the-added-lines prefix-into-the-added-lines

install_home stale-uptodate "$R_BASE"; make_partial complete
run_update "$H" "$R_BASE"
check "5d: a leftover and nothing else to do: it is discarded (one line) and the update says it is up to date" bash -c "[ '$RC' -eq 0 ] && [ ! -e '$R/manifest.partial' ] && printf '%s' \"\$1\" | grep -q 'discarded a stale manifest.partial' && printf '%s' \"\$1\" | grep -q 'already up to date'" _ "$OUT"

damage_not_stale() { make_partial "$NS_KIND"; }
repair_not_stale() { rmdir -- "$R/manifest.partial" 2>/dev/null; rm -f -- "$R/manifest.partial" "$H.partial.real"; return 0; }
# A leftover is discarded only when nothing else stops the update: a refused update changes nothing, the leftover included.
damage_stale_and_launcher() { make_partial complete; printf 'X' >> "$R/bin/clawd-pet-launch"; }
repair_stale_and_launcher() { cp "$R_BASE/launcher/clawd-pet-launch" "$R/bin/clawd-pet-launch.fix" && mv "$R/bin/clawd-pet-launch.fix" "$R/bin/clawd-pet-launch"; }
refusal stale-partial-and-another-cause "is not the one recorded in launcher/clawd-pet-launch.sha256" damage_stale_and_launcher repair_stale_and_launcher
not_stale() { # name kind: refused as before; the same update goes through once the file is gone
  NS_KIND="$2"
  refusal "not-stale-$1" "manifest.partial exists" damage_not_stale repair_not_stale
}
not_stale symlink symlink
not_stale directory directory
not_stale outside-the-install outside-the-install
not_stale after-the-end after-the-end
not_stale in-the-wrong-place before-the-log-lines-of-another-position
not_stale unknown-kind unknown-kind
not_stale repeats-a-line repeats-a-line
not_stale reordered reordered
not_stale another-install another-install

# ---- 5e. one update at a time ---------------------------------------------------------------------------------------------------
# Every run shares the same .partial names, so two runs at once could truncate a file the other had just proved. The whole run holds an
# exclusive lock on the install directory (descriptor 8); the kernel releases it when its holder dies; a second update stops at once.
install_home overlap "$R_BASE"; HO="$H"; RO="$R"; set_generation 3
hold_update "$HO" "$R_V2" "$n_agent"
check "5e: the first update is held just before it renames the verified agent into place" bash -c "[ -n '$HOLD_PID' ] && kill -0 '$HOLD_PID' && [ -f '$RO/bin/clawd-pet-agent.partial' ] && ! cmp -s '$R_V2/build/clawd-pet-agent' '$RO/bin/clawd-pet-agent'"
held_tree="$(tree "$HO")"
run_update "$HO" "$R_V2"
check "5e: a second update is refused (exit 2) and names the reason" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'another update is already running' && printf '%s' \"\$1\" | grep -q 'nothing was changed'" _ "$OUT"
check "5e: ... at once: it did not wait for the first (under 5 s)" test "$ELAPSED" -lt 5000
check "5e: ... not one cp, mv, mkdir, chmod, sed or rm ran for it" test "$(cat "$HO.upd.count")" = 0
check "5e: ... nothing was sent to launchd but list" test "$(verbs_other_than_list "$HO")" = 0
check "5e: ... not one file changed, the first update's .partial files included (every path and checksum)" test "$(tree "$HO")" = "$held_tree"
run_update "$HO" "$R_V2" --restart
check "5e: ... --restart is refused too" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'another update is already running'" _ "$OUT"
release_update "$HO"
check "5e: released, the first update finishes (exit 0)" test "$HOLD_RC" -eq 0
check "5e: ... the installed agent is the whole new build, byte for byte, and no .partial is left" bash -c "cmp -s '$R_V2/build/clawd-pet-agent' '$RO/bin/clawd-pet-agent' && ! find '$HO' -name '*.partial' | grep -q ."
check "5e: ... the lock is a kernel lock on the install directory: the install holds no lock file but control.lock" bash -c "[ \"\$(ls '$RO' | grep -c lock)\" = 1 ] && [ -f '$RO/control.lock' ]"
uninstall_home "$HO" "$R_V2"
check "5e: ... one uninstall leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HO")" "$(cat "$HO.pre.tree")"

# The holder dies (SIGKILL) while it waits for the restarted agent: the lock goes with it, and a third update takes it. The stub's new
# agent (answers after 30 s) is a background job of launchctl: it must not keep the lock either.
lock_free() { ( exec 8<"$1" && /usr/bin/lockf -s -t 0 8 ) >/dev/null 2>&1; }
lock_held() { ! lock_free "$1"; }
freed_while_the_stubs_job_lives() { wait_until 100 lock_free "$R" && kill -0 "$(tail -n 1 "$H.loaded.bg")"; }
install_home killed "$R_BASE"; set_generation 5; : > "$H.calls"
( env HOME="$H" PATH="$SHIMS:$PATH" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" STUB_KICK_MODE=delayed STUB_KICK_DELAY=30 \
    CLAWD_BUILD_DIR="$R_V2/build" CLAWD_RESTART_WAIT_S=40 "$CLI_BASH" -c 'echo $$ > "$1"; shift; exec "$@"' sh "$H.kill.pid" "$CLI_BASH" "$R_V2/bin/clawd-pet" update ) > "$H.kill.out" 2>&1 &
kill_bg=$!; holders+=("$kill_bg")
wait_until 1200 grep -q '^launchctl kickstart -k ' "$H.calls"
kill_pid="$(cat "$H.kill.pid" 2>/dev/null)"; holders+=("$kill_pid")
check "5e: an update is waiting for its restarted agent (the restart was sent, the new agent has not answered)" bash -c "[ -n '$kill_pid' ] && kill -0 '$kill_pid' && grep -q '^launchctl kickstart -k ' '$H.calls'"
check "5e: ... it holds the lock (nobody else can take it)" lock_held "$R"
run_update "$H" "$R_V2"
check "5e: ... a second update is refused (exit 2) even though every file is already current" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'another update is already running'" _ "$OUT"
# Settings commands use their own lock (control.lock): they neither wait for the update nor does the update wait for them.
SETTINGS_LOCK_WAIT_S=1 WAIT_S=1 settings_cli "$H" walk off
check "5e: ... a settings command meanwhile does not wait for the update (no settings-lock message; it saved generation 6)" bash -c "! printf '%s' \"\$1\" | grep -q 'holds' && printf '%s' \"\$1\" | grep -q 'generation 6'" _ "$OUT"
kill -KILL "$kill_pid" 2>/dev/null; wait "$kill_bg" 2>/dev/null
check "5e: the holder was killed: the lock is free again within seconds, though the stub's background job still runs" freed_while_the_stubs_job_lives
KICK_MODE=ok run_update "$H" "$R_V2"
check "5e: ... a third update takes the lock and finishes the cut one's job: marker found, restarted, confirmed (exit 0)" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'an earlier update was cut before its restart was confirmed' && printf '%s' \"\$1\" | grep -q 'restarted the agent (pid 4243 -> 4244)' && [ ! -e '$R/restart-pending' ]" _ "$OUT"
for p in $(cat "$H.loaded.bg" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done

# The settings lock held by someone else does not stop an update (it never asks for it).
install_home settings-lock "$R_BASE"; set_generation 2
# The holder says so when it has the lock: a probe that polled for it could itself hold the lock at the instant the holder asks, and make it fail.
rm -f -- "$H.settings-lock.ready"
( exec 9<"$R/control.lock" && /usr/bin/lockf -s -t 0 9 && : > "$H.settings-lock.ready" && exec /bin/sleep 30 ) > /dev/null 2>&1 &
settings_holder=$!; holders+=("$settings_holder"); disown "$settings_holder" 2>/dev/null
wait_until 1200 test -e "$H.settings-lock.ready"
check "5e: (someone holds the settings lock control.lock)" lock_held "$R/control.lock"
SETTINGS_LOCK_WAIT_S=1 run_update "$H" "$R_V2"
check "5e: ... an update still runs to the end (exit 0): it never asks for control.lock" bash -c "[ '$RC' -eq 0 ] && cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent'"
kill -KILL "$settings_holder" 2>/dev/null

# ---- 5f. uninstall after a cut update --------------------------------------------------------------------------------------------
# uninstall takes the update lock for its whole run, so no update is writing while it judges a manifest.partial, and applies the rule
# update uses: a partial that provably is a cut update's leftover is discarded (one line, after the last refusal) and the uninstall goes on;
# anything else is refused by name, as before, and nothing is removed. (The cut-at-every-operation matrix is in install-interrupt.test.sh.)
uninstall_discard_case() { # name kind
  install_home "un-$1" "$R_BASE"; set_generation 2
  make_partial "$2"
  uninstall_home "$H" "$R_V2"
  check "5f: $1: uninstall exits 0 and says in one line that it discarded a stale manifest.partial" bash -c "[ '$RC' -eq 0 ] && [ \"\$(printf '%s\n' \"\$1\" | grep -c 'discarded a stale manifest.partial')\" = 1 ] && printf '%s' \"\$1\" | grep -q 'uninstalled'" _ "$OUT"
  check "5f: $1: ... the tree is as it was before the install (no manifest.partial, nothing left)" bash -c "[ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"
}
uninstall_discard_case a-complete-leftover complete
uninstall_discard_case an-empty-file empty
uninstall_discard_case a-prefix-of-the-live-lines prefix
uninstall_discard_case a-cut-inside-the-added-lines prefix-into-the-added-lines

uninstall_refuse_case() { # name kind
  install_home "un-ns-$1" "$R_BASE"; set_generation 2
  make_partial "$2"
  local before; before="$(tree "$H")"
  uninstall_home "$H" "$R_V2"
  check "5f: not stale ($1): uninstall refuses (exit 2) and names the file" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -qF '$R/manifest.partial'" _ "$OUT"
  check "5f: ... it says it removed nothing, and not one file changed" bash -c "printf '%s' \"\$1\" | grep -q 'nothing was removed' && [ \"\$2\" = \"\$3\" ]" _ "$OUT" "$(tree "$H")" "$before"
  rmdir -- "$R/manifest.partial" 2>/dev/null; rm -f -- "$R/manifest.partial" "$H.partial.real"
  uninstall_home "$H" "$R_V2"
  check "5f: ... once the file is gone the same uninstall finishes (exit 0, the tree is as it was before the install)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"
}
uninstall_refuse_case a-foreign-file-with-its-name foreign
uninstall_refuse_case a-symlink symlink
uninstall_refuse_case a-directory directory
uninstall_refuse_case outside-the-install outside-the-install
uninstall_refuse_case lines-after-the-end after-the-end
uninstall_refuse_case lines-in-the-wrong-place before-the-log-lines-of-another-position
uninstall_refuse_case an-unknown-kind unknown-kind
uninstall_refuse_case a-repeated-line repeats-a-line
uninstall_refuse_case reordered-lines reordered
uninstall_refuse_case another-installs-manifest another-install

# the discard comes after the last refusal: an uninstall that is stopped later (here: the process listing cannot be read) leaves the partial
install_home un-late "$R_BASE"; set_generation 2; make_partial complete
OUT="$(env HOME="$H" CLAWD_LAUNCHCTL="$LAUNCHCTL_STUB" STUB_LOG="$H.calls" STUB_STATE="$H.loaded" STUB_ROOT="$R" CLAWD_OWN_PIDS_CHECKER="$STUBS/own-pids-fail" "$CLI_BASH" "$R_V2/bin/clawd-pet" uninstall 2>&1)"; RC=$?
check "5f: an uninstall refused after it judged the partial (the process listing fails): exit 2 and the partial is still there" bash -c "[ '$RC' -eq 2 ] && [ -f '$R/manifest.partial' ] && ! printf '%s' \"\$1\" | grep -q 'discarded'" _ "$OUT"
uninstall_home "$H" "$R_V2"
check "5f: ... the retry discards it and finishes (exit 0, the tree is as it was before the install)" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'discarded a stale manifest.partial' && [ \"\$2\" = \"\$3\" ]" _ "$OUT" "$(tree "$H")" "$(cat "$H.pre.tree")"

# under the same lock: while an update holds it, uninstall is refused and removes nothing (an update writes the files uninstall removes)
install_home un-locked "$R_BASE"; HU="$H"; RU="$R"; set_generation 3
hold_update "$HU" "$R_V2" "$n_agent"
held_tree="$(tree "$HU")"
uninstall_home "$HU" "$R_V2"
check "5f: an uninstall while an update holds the lock: exit 2, 'another update is already running', nothing removed" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'another update is already running' && printf '%s' \"\$1\" | grep -q 'nothing was removed'" _ "$OUT"
check "5f: ... not one file changed (the update's .partial files included)" test "$(tree "$HU")" = "$held_tree"
check "5f: ... and the job was not stopped (nothing sent to launchd but list)" bash -c "[ \"\$(cat '$HU.calls' 2>/dev/null | grep -vc '^launchctl list ')\" = 0 ]"
release_update "$HU"
check "5f: ... the update finishes (exit 0)" test "$HOLD_RC" -eq 0
uninstall_home "$HU" "$R_V2"
check "5f: ... and the uninstall after it finishes (exit 0, the tree is as it was before the install)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$HU")" "$(cat "$HU.pre.tree")"

# ---- 5g. the focus-violation ledger ---------------------------------------------------------------------------------------------
# The ledger $R/focus-violations.log is created by install (header how=install), adopted by an update of an install that does not list it
# (how=adopt-update, after the manifest names it and the restart marker exists, before the first copy and the agent swap), never touched by
# an ordinary update, and recreated (how=recreate) only to let an interrupted update finish: while the restart marker exists, or while the
# installed agent is not yet this build. The check's reading of it is in Tests/attended-check.test.sh.
ledger_how() { sed -n '1s/^LEDGER 1 born=[0-9][0-9]* how=\([a-z-]*\)$/\1/p' "$1"; }
old_style_ledger() { # remove the ledger file and its two manifest lines: an install made before the ledger existed
  grep -vxF -e "file $R/focus-violations.log" -e "file $R/focus-violations.log.partial" "$R/manifest" > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest" && rm -f -- "$R/focus-violations.log"
}

install_home ledger-adopt "$R_BASE"; set_generation 2; old_style_ledger
run_update "$H" "$R_V2"
check "5g: adoption: update of an install that does not list the ledger exits 0 and creates it with how=adopt-update" bash -c "[ '$RC' -eq 0 ] && [ -f '$R/focus-violations.log' ] && [ \"\$1\" = adopt-update ] && [ \$(grep -c '' '$R/focus-violations.log') = 1 ]" _ "$(ledger_how "$R/focus-violations.log")"
check "5g: adoption: the ledger has mode 600 and no .partial of it is left" bash -c "[ \"\$(/usr/bin/stat -f %Lp '$R/focus-violations.log')\" = 600 ] && [ ! -e '$R/focus-violations.log.partial' ]"
check "5g: adoption: the manifest gains the ledger and its .partial name before the first log line" bash -c "l=\$(grep -nxF 'file $R/focus-violations.log' '$R/manifest' | cut -d: -f1); p=\$(grep -nxF 'file $R/focus-violations.log.partial' '$R/manifest' | cut -d: -f1); f=\$(grep -n '^log ' '$R/manifest' | head -n 1 | cut -d: -f1); [ -n \"\$l\" ] && [ -n \"\$p\" ] && [ \"\$l\" -lt \"\$f\" ] && [ \"\$p\" -lt \"\$f\" ]"
check "5g: adoption: the agent is restarted (the first BOOT line comes from the restart)" bash -c "[ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]"
n_ledger="$(awk '$2 == "mv" && index($0, "focus-violations.log.partial") { print $1; exit }' "$H.upd.ops")"
n_agent_a="$(awk '$2 == "mv" && index($0, "bin/clawd-pet-agent.partial") { print $1; exit }' "$H.upd.ops")"
n_first_cp="$(awk '$2 == "cp" { print $1; exit }' "$H.upd.ops")"
check "5g: adoption: the ledger is born (renamed into place) before the first file copy and before the agent swap" bash -c "[ -n '$n_ledger' ] && [ -n '$n_agent_a' ] && [ -n '$n_first_cp' ] && [ '$n_ledger' -lt '$n_agent_a' ] && [ '$n_ledger' -lt '$n_first_cp' ]"
install_home ledger-adopt-held "$R_BASE"; set_generation 2; old_style_ledger
hold_update "$H" "$R_V2" "$n_ledger"
check "5g: adoption, held at the ledger's rename: the manifest names it, the restart marker exists, the header is written to the .partial, and the old agent is still in place" bash -c "[ -e '$H.hold.ready' ] && grep -qxF 'file $R/focus-violations.log' '$R/manifest' && [ -f '$R/restart-pending' ] && [ -f '$R/focus-violations.log.partial' ] && [ ! -e '$R/focus-violations.log' ] && cmp -s '$R_BASE/build/clawd-pet-agent' '$R/bin/clawd-pet-agent'"
release_update "$H"
check "5g: ... released, the adoption finishes (exit 0)" test "$HOLD_RC" -eq 0
uninstall_home "$H" "$R_V2"
check "5g: ... and one uninstall of an adopted install leaves the tree as it was before the install" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"

install_home ledger-adopt-same-build "$R_BASE"; set_generation 2; old_style_ledger
run_update "$H" "$R_BASE"
check "5g: adoption with an unchanged build still restarts the agent (a BOOT line must follow) and creates the ledger" bash -c "[ '$RC' -eq 0 ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ] && [ \"\$1\" = adopt-update ] && [ ! -e '$R/restart-pending' ]" _ "$(ledger_how "$R/focus-violations.log")"
install_home ledger-unlisted-present "$R_BASE"; set_generation 2; cp "$R/focus-violations.log" "$H.ledger.keep"; old_style_ledger; cp "$H.ledger.keep" "$R/focus-violations.log"
before_tree="$(tree "$H")"
run_update "$H" "$R_V2"
check "5g: a ledger that exists but is not in the manifest is refused (exit 2, nothing changed)" bash -c "[ '$RC' -eq 2 ] && printf '%s' \"\$1\" | grep -q 'the manifest does not list it' && [ \"\$2\" = \"\$3\" ]" _ "$OUT" "$(tree "$H")" "$before_tree"

install_home ledger-ordinary "$R_BASE"; set_generation 2
printf '%s\n' 'BOOT 1792000000.000001 pid=4242 counter=0 violations=0' >> "$R/focus-violations.log"
ledger_before="$(printf '%s %s' "$(/usr/bin/stat -f '%i %m %z' "$R/focus-violations.log")" "$(/usr/bin/cksum < "$R/focus-violations.log")")"
run_update "$H" "$R_V2"
check "5g: an ordinary update leaves an existing ledger byte-identical (same inode, mtime, size and bytes)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$ledger_before" "$(printf '%s %s' "$(/usr/bin/stat -f '%i %m %z' "$R/focus-violations.log")" "$(/usr/bin/cksum < "$R/focus-violations.log")")"

install_home ledger-missing "$R_BASE"; set_generation 2; rm -f -- "$R/focus-violations.log"
run_update "$H" "$R_BASE"
check "5g: a listed ledger that is absent is not recreated by an ordinary update (nothing to do: exit 0, 'already up to date')" bash -c "[ '$RC' -eq 0 ] && [ ! -e '$R/focus-violations.log' ] && printf '%s' \"\$1\" | grep -q 'already up to date'" _ "$OUT"
check "5g: ... and update says the ledger is missing" contains "$OUT" "focus-violation ledger"
check "5g: ... and no ledger .partial was made" test ! -e "$R/focus-violations.log.partial"

install_home ledger-missing-marker "$R_BASE"; set_generation 2; rm -f -- "$R/focus-violations.log"; : > "$R/restart-pending"
run_update "$H" "$R_BASE"
check "5g: a listed ledger that is absent is recreated while the restart marker exists, with how=recreate (never adopt-update)" bash -c "[ '$RC' -eq 0 ] && [ -f '$R/focus-violations.log' ] && [ \"\$1\" = recreate ] && [ ! -e '$R/restart-pending' ]" _ "$(ledger_how "$R/focus-violations.log")"

install_home ledger-missing-oldagent "$R_BASE"; set_generation 2; rm -f -- "$R/focus-violations.log"
run_update "$H" "$R_V2"
check "5g: a listed ledger that is absent is recreated when the installed agent is not yet the new build, with how=recreate" bash -c "[ '$RC' -eq 0 ] && [ -f '$R/focus-violations.log' ] && [ \"\$1\" = recreate ]" _ "$(ledger_how "$R/focus-violations.log")"

# the named recovery fixture: an adoption cut between the manifest's publication and the restart marker
install_home ledger-cut-adoption "$R_BASE"; set_generation 2; old_style_ledger
awk -v l="file $R/focus-violations.log" -v p="file $R/focus-violations.log.partial" '/^log / && !done { print l; print p; done = 1 } { print }' "$R/manifest" > "$R/manifest.new" && mv "$R/manifest.new" "$R/manifest"
check "5g: adoption cut between manifest publish and restart marker: the fixture has the manifest naming the ledger, no marker, no ledger, the old agent" bash -c "grep -qxF 'file $R/focus-violations.log' '$R/manifest' && [ ! -e '$R/restart-pending' ] && [ ! -e '$R/focus-violations.log' ] && cmp -s '$R_BASE/build/clawd-pet-agent' '$R/bin/clawd-pet-agent'"
run_update "$H" "$R_V2"
check "5g: ... rerunning update recreates the ledger with how=recreate and finishes the adoption (agent replaced and restarted, marker gone)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = recreate ] && cmp -s '$R_V2/build/clawd-pet-agent' '$R/bin/clawd-pet-agent' && [ ! -e '$R/restart-pending' ] && [ \"\$(grep -c '^launchctl kickstart -k ' '$H.calls')\" = 1 ]" _ "$(ledger_how "$R/focus-violations.log")"
run_update "$H" "$R_V2"
check "5g: ... and the next update has nothing to do" bash -c "[ '$RC' -eq 0 ] && printf '%s' \"\$1\" | grep -q 'already up to date'" _ "$OUT"
uninstall_home "$H" "$R_V2"
check "5g: ... one uninstall clears it (the tree equals the tree before the install)" bash -c "[ '$RC' -eq 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$(tree "$H")" "$(cat "$H.pre.tree")"

# ---- 6. source hygiene of the update code ----------------------------------------------------------------------------------------
awk '/^cmd_update\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' "$REPO/bin/clawd-pet" | grep -vE '^[[:space:]]*#' > "$STAGE/update.code"
check "6: the update function was found" test "$(wc -l < "$STAGE/update.code" | tr -d ' ')" -gt 100
check "6: update never boots the job out or in, and never unloads it" bash -c "! grep -qE 'bootout|bootstrap|unload|launchctl.* remove' '$STAGE/update.code'"
check "6: update sends kickstart -k in exactly one place" test "$(grep -c 'kickstart -k' "$STAGE/update.code")" = 1
grep -vE '^[[:space:]]*#' "$REPO/bin/clawd-pet" > "$STAGE/cli.code"
check "6: the CLI sends kickstart -k in exactly two places: update, and the restart a setting asks for" test "$(grep -c 'kickstart -k "\$DOMAIN/\$LABEL"' "$STAGE/cli.code")" = 2
check "6: update never signals a process" bash -c "! grep -qE '(^|[^a-z_])kill ' '$STAGE/update.code'"
check "6: update never writes, copies over, moves or removes the plist, the launcher, control.json or control.lock" bash -c "! grep -qE '(cp|mv|rm|ln|sed|tee|copy_executable|>) +[^|;]*\"\\\$(PLIST|LAUNCHER|CONTROL|CONTROL_LOCK|CONTROL_PARTIAL)\"' '$STAGE/update.code'"
check "6: update never removes a tree" bash -c "! grep -qE 'rm +-[a-zA-Z]*[rR]|rm +--recursive|rmdir' '$STAGE/update.code'"
check "6: update runs under bash 3.2 (syntax)" /bin/bash -n "$REPO/bin/clawd-pet"
awk '/^wait_restarted\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' "$REPO/bin/clawd-pet" | grep -vE '^[[:space:]]*#' > "$STAGE/wait.code"
check "6: the wait for the restarted agent asks launchd for the pid, reads the pid status.json holds, and reads the generation through the one function" bash -c "grep -q 'service_pid' '$STAGE/wait.code' && grep -q 'json_value pid' '$STAGE/wait.code' && grep -q 'applied_at_least' '$STAGE/wait.code' && ! grep -q 'appliedGeneration' '$STAGE/wait.code'"

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
