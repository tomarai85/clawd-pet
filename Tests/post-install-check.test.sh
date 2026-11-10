#!/bin/bash
# Test of scripts/post-install-check.sh, scripts/direct-exec-check.sh, scripts/post-install-settings-step.sh and scripts/pre-install-snapshot.sh (spec section 6 item 6; round brief
# r4 B.3 and B.4; round 4 carry-over, findings 3 and 4: post-install-check is strictly read-only, and "no window" needs continuous observation).
# The scripts only ever run in their sandbox mode, where EVERY external effect comes from a stub in Tests/attended-stubs: a launchctl
# that answers `list` from numbered files, a window lister whose lists come from numbered files (and from files a stand-in agent writes
# for its own pid), an lsappinfo, and a stand-in for the installed Mach-O that exits, lingers or registers a window as a file says.
# No real launchctl, no real window list, no real process of the pet, no window, no event. Real mode needs --real, which no line of
# this file ever passes to a script run outside a stubbed sandbox.
#
# One scenario per FAIL / NOT RUN row of post-install-check.sh, one per behaviour of pre-install-snapshot.sh. Every scenario asserts the
# verdict, the exit code and the EXACT set of reason codes. Scenarios run in parallel under .build/post-install-check-test/.
# The last line, "post-install-check.test: pass=N fail=M", is printed only from executed assertions.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
POST="$REPO/scripts/post-install-check.sh"
DX="$REPO/scripts/direct-exec-check.sh"
SS="$REPO/scripts/post-install-settings-step.sh"
SNAP="$REPO/scripts/pre-install-snapshot.sh"
STUBS="$REPO/Tests/attended-stubs"
CHECK_BASH="$(command -v "${CLAWD_TEST_BASH:-bash}")"
JOBS="${CLAWD_TEST_JOBS:-6}"
[ "$(id -u)" -ne 0 ] || { echo "post-install-check.test: refuses to run as root"; exit 2; }
[ -x "$CHECK_BASH" ] || { echo "post-install-check.test: no interpreter: ${CLAWD_TEST_BASH:-bash}"; exit 2; }
STAGE="$REPO/.build/post-install-check-test/$(date +%s)-$$"
RESDIR="$STAGE/res"
mkdir -p "$RESDIR" || { echo "cannot create $STAGE"; exit 2; }
echo "post-install-check.test: interpreter = $CHECK_BASH $("$CHECK_BASH" -c 'echo "$BASH_VERSION"')"
LABEL="com.tomtim.clawd-pet"
. "$REPO/Tests/check-harness.sh"

# ---- post-install-check.sh ------------------------------------------------------------------------------------------------------------
# new_sandbox NAME: an installed, started pet whose panel is in the window list, Aqua Voice running, the plist naming the installed launcher
# (a copy of the checked-in one) and a stand-in agent that records every time it is run (post-install-check must never run it).
new_sandbox() {
  SB="$STAGE/$1"
  ROOT_="$SB/home/Library/Application Support/clawd-pet"
  STUB="$SB/stub"
  mkdir -p "$ROOT_/bin" "$SB/home/Library/LaunchAgents" "$STUB" "$SB/evidence" || return 1
  : > "$SB/.postinstall-sandbox"; : > "$SB/.directexec-sandbox"; : > "$SB/.settings-sandbox"
  PLIST_FILE="$SB/home/Library/LaunchAgents/$LABEL.plist"
  sed "s|@INSTALL_ROOT@|$ROOT_|g" "$REPO/launchd/$LABEL.plist.in" > "$PLIST_FILE"
  printf 'schema 1\nend\n' > "$ROOT_/manifest"
  cp "$STUBS/agent" "$ROOT_/bin/clawd-pet-agent" && chmod 755 "$ROOT_/bin/clawd-pet-agent"
  cp "$REPO/launcher/clawd-pet-launch" "$ROOT_/bin/clawd-pet-launch" && chmod 755 "$ROOT_/bin/clawd-pet-launch"
  # The installed art: a small schema-2 catalog whose pictures sit in nested directories, as the real one does (frames/, motions/<id>/,
  # looks/<id>/). Every file it names is present.
  mkdir -p "$ROOT_/art/frames" "$ROOT_/art/motions/A1-thinking" "$ROOT_/art/motions/A2-looking" "$ROOT_/art/looks/helmet" || return 1
  printf '%s\n' '{"schema":2,"poses":{"idle":{"frames":["frames/idle_0.png"],"ms":[1000],"loop":true}},"motions":[{"id":"A1-thinking","frames":["motions/A1-thinking/000.png","motions/A1-thinking/001.png"]},{"id":"A2-looking","frames":["motions/A2-looking/000.png"]}],"looks":[{"id":"helmet","layers":[{"name":"dome","png":"looks/helmet/layer.png"}]}]}' > "$ROOT_/art/clawd-atlas.json"
  for f in frames/idle_0.png motions/A1-thinking/000.png motions/A1-thinking/001.png motions/A2-looking/000.png looks/helmet/layer.png; do printf 'png\n' > "$ROOT_/art/$f"; done
  echo 4242 > "$STUB/launchctl.1"; echo 4242 > "$STUB/launchctl.2"
  { echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10'; echo 'WINDOW 4242 3 1 100.0 200.0 48.0 48.0 51'; } > "$STUB/windows.1"
  : > "$STUB/aqua.running"
  echo exit0 > "$STUB/agent.mode"
  EXTRA_ENV=""; SETTLE=0.3
}
run_post() { # extra arguments -> OUT (stdout), RC, JSON (the evidence file)
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_POSTINSTALL_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
    CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S="$SETTLE" \
    STUB_DIR="$STUB" $EXTRA_ENV "$CHECK_BASH" "$POST" "$@" 2>"$SB/stderr")"
  RC=$?
  JSON="$(ls "$SB"/evidence/post-install-check-*.json 2>/dev/null | head -n 1)"
}
jget() { /usr/bin/plutil -extract "$1" raw -o - "$JSON" 2>/dev/null; }
codes() { /usr/bin/plutil -extract "$1" json -o - "$JSON" 2>/dev/null | tr -d '[]" ' | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort | paste -sd, -; }
last_line() { printf '%s\n' "$OUT" | tail -n 1; }
expect() { # LABEL VERDICT EXIT FAIL-CODES NOTRUN-CODES
  local label="$1" verdict="$2" rc="$3" fc="$4" nc="$5"
  check "$label: verdict $verdict" equals "$(jget verdict)" "$verdict"
  check "$label: exit $rc" equals "$RC" "$rc"
  check "$label: fail codes [$fc]" equals "$(codes fail_codes)" "$fc"
  check "$label: not-run codes [$nc]" equals "$(codes notrun_codes)" "$nc"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "post-install-check: $verdict"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: launchctl was only ever asked to list" bash -c "[ ! -s '$STUB/launchctl.violations' ] && ! grep -v '^launchctl list ' '$STUB/launchctl.calls'"
}

home_digest() { (cd "$SB/home" && LC_ALL=C find . -print | LC_ALL=C sort && LC_ALL=C find . -type f -exec /usr/bin/cksum {} + | LC_ALL=C sort -k3) | /usr/bin/shasum -a 256; }
scn_post_pass() {
  new_sandbox post-pass; HOME_BEFORE="$(home_digest)"; run_post
  expect "healthy pet" PASS 0 "" ""
  check "pass: the same pid at the start and after the wait" bash -c "[ \"$(jget launchd_start.agent_pid_start)\" = 4242 ] && [ \"$(jget launchd_start.agent_pid_after_settle)\" = 4242 ]"
  check "pass: the panel of the agent's pid was found" equals "$(jget launchd_start.panel.windows_of_the_agent)" 1
  check "pass: the plist names the installed launcher and the launcher is the recorded one" bash -c "[ \"$(jget launcher.intact)\" = true ] && [ \"$(jget launcher.plist_program)\" = '$ROOT_/bin/clawd-pet-launch' ] && [ \"$(jget launcher.installed_sha256)\" = \"$(jget launcher.recorded_sha256)\" ]"
  check "pass: the recorded sha256 is the one in the repo's launcher/clawd-pet-launch.sha256" equals "$(jget launcher.recorded_sha256)" "$(cut -d' ' -f1 "$REPO/launcher/clawd-pet-launch.sha256")"
  check "pass: strictly read-only: nothing from the install was run (the stand-in agent never started)" bash -c "[ ! -e '$STUB/agent.pids' ]"
  check "pass: strictly read-only: the install and the fake HOME are unchanged by the check" test "$(home_digest)" = "$HOME_BEFORE"
  check "pass: the evidence names its scope and where check (c) lives" contains "$(jget scope)" "scripts/pre-install-snapshot.sh"
  check "pass: launchctl was asked twice (start and after the wait)" equals "$(cat "$STUB/launchctl.count")" 2
}
scn_post_not_installed() {
  new_sandbox post-not-installed; rm -- "$ROOT_/manifest"; run_post
  expect "no manifest" "NOT RUN" 3 "" "not-installed"
  check "not installed: the Mach-O was not run" bash -c "[ ! -e '$STUB/agent.pids' ]"
  check "not installed: launchctl was not asked" bash -c "[ ! -e '$STUB/launchctl.count' ]"
}
scn_post_no_plist() {
  new_sandbox post-no-plist; rm -- "$SB/home/Library/LaunchAgents/$LABEL.plist"; run_post
  expect "no plist" "NOT RUN" 3 "" "not-installed"
}
scn_post_not_loaded() {
  new_sandbox post-not-loaded; echo unloaded > "$STUB/launchctl.1"; run_post
  expect "launchctl does not list the label" "NOT RUN" 3 "" "not-loaded"
  check "not loaded: the launcher check still ran and passed" equals "$(jget launcher.intact)" true
}
scn_post_no_pid() {
  new_sandbox post-no-pid; echo nopid > "$STUB/launchctl.1"; run_post
  expect "loaded without a process" "NOT RUN" 3 "" "not-loaded"
}
scn_post_agent_dies() {
  new_sandbox post-dies; echo nopid > "$STUB/launchctl.2"; run_post
  expect "the agent has no process after the wait" FAIL 1 "agent-not-alive-after-5s" ""
}
scn_post_agent_unloaded_after_wait() {
  new_sandbox post-unloaded-after; echo unloaded > "$STUB/launchctl.2"; run_post
  expect "launchctl no longer lists the label after the wait" FAIL 1 "agent-not-alive-after-5s" ""
}
scn_post_agent_restarted() {
  new_sandbox post-restarted; echo 5555 > "$STUB/launchctl.2"; run_post
  expect "the pid changed within the wait" FAIL 1 "agent-restarted" ""
}
scn_post_panel_missing_aqua_running() {
  new_sandbox post-no-panel; echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10' > "$STUB/windows.1"; run_post
  expect "Aqua Voice runs and the agent has no on-screen window" FAIL 1 "panel-missing" ""
}
scn_post_panel_offscreen_only() {
  new_sandbox post-offscreen; { echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10'; echo 'WINDOW 4242 3 0 100.0 200.0 48.0 48.0 51'; } > "$STUB/windows.1"; run_post
  expect "the agent's only window is off-screen" FAIL 1 "panel-missing" ""
}
scn_post_panel_of_another_pid() {
  new_sandbox post-other-pid; { echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10'; echo 'WINDOW 4243 3 1 100.0 200.0 48.0 48.0 51'; } > "$STUB/windows.1"; run_post
  expect "an on-screen window of another pid is not the panel" FAIL 1 "panel-missing" ""
}
scn_post_panel_hidden_without_aqua() {
  new_sandbox post-no-aqua; echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10' > "$STUB/windows.1"; rm -- "$STUB/aqua.running"; run_post
  expect "no panel because Aqua Voice is not running" "NOT RUN" 3 "" "panel-not-visible"
}
scn_post_lister_fails() {
  new_sandbox post-lister; : > "$STUB/windows.fail.1"; run_post
  expect "the window list cannot be read for check (a)" "NOT RUN" 3 "" "window-lister-failed"
}
scn_post_lister_truncated() {
  new_sandbox post-lister-trunc; : > "$STUB/windows.truncated.1"; run_post
  expect "the window list has no footer" "NOT RUN" 3 "" "window-lister-failed"
}

scn_post_launcher_missing() {
  new_sandbox post-launcher-missing; rm -- "$ROOT_/bin/clawd-pet-launch"; run_post
  expect "the installed launcher is gone" FAIL 1 "launcher-missing" ""
}
scn_post_launcher_changed() {
  new_sandbox post-launcher-changed; printf 'X' >> "$ROOT_/bin/clawd-pet-launch"; run_post
  expect "the installed launcher differs from the recorded one by one byte" FAIL 1 "launcher-changed" ""
  check "launcher changed: both hashes are in the evidence and differ" bash -c "[ -n \"$(jget launcher.installed_sha256)\" ] && [ \"$(jget launcher.installed_sha256)\" != \"$(jget launcher.recorded_sha256)\" ] && [ \"$(jget launcher.intact)\" = false ]"
}
scn_post_launcher_is_a_link() {
  new_sandbox post-launcher-link; rm -- "$ROOT_/bin/clawd-pet-launch"; ln -s "$REPO/launcher/clawd-pet-launch" "$ROOT_/bin/clawd-pet-launch"; run_post
  expect "the installed launcher is a symlink to the right bytes" FAIL 1 "launcher-missing" ""
}
scn_post_plist_names_the_agent() {
  new_sandbox post-plist-agent; sed "s|clawd-pet-launch|clawd-pet-agent|" "$PLIST_FILE" > "$PLIST_FILE.new" && mv "$PLIST_FILE.new" "$PLIST_FILE"; run_post
  expect "the plist names the agent, as a v1 install did" FAIL 1 "plist-not-launcher" ""
}
scn_post_plist_unreadable() {
  new_sandbox post-plist-unreadable; : > "$PLIST_FILE"; run_post
  expect "the plist cannot be read" FAIL 1 "plist-not-launcher" ""
}
scn_post_art_whole() {
  new_sandbox post-art-whole; run_post
  expect "the installed art holds every file the atlas names" PASS 0 "" ""
  check "art whole: the evidence counts 5 named files and 0 missing" bash -c "[ \"$(jget art.atlas_files)\" = 5 ] && [ \"$(jget art.missing)\" = 0 ]"
  check "art whole: the PASS line says the art is checked" contains "$(last_line)" "every file the installed atlas names is installed"
}
scn_post_art_nested_motion_frame_missing() {
  new_sandbox post-art-motion; rm -- "$ROOT_/art/motions/A2-looking/000.png"; run_post
  expect "a nested motion frame the atlas names is not installed" FAIL 1 "art-missing" ""
  check "art missing: the reason names the path" bash -c "/usr/bin/plutil -extract fail_reasons.0 raw -o - '$JSON' | grep -qF 'motions/A2-looking/000.png'"
  check "art missing: the evidence counts 1 missing of 5 and names it" bash -c "[ \"$(jget art.missing)\" = 1 ] && [ \"$(jget art.atlas_files)\" = 5 ] && [ \"$(jget art.first_missing)\" = 'motions/A2-looking/000.png' ]"
}
scn_post_art_look_layer_missing() {
  new_sandbox post-art-look; rm -- "$ROOT_/art/looks/helmet/layer.png"; run_post
  expect "a look layer the atlas names is not installed" FAIL 1 "art-missing" ""
}
scn_post_art_only_the_frames_directory() {
  new_sandbox post-art-frames-only; rm -r -- "$ROOT_/art/motions" "$ROOT_/art/looks"; run_post
  expect "only frames/ is installed (what the first v2 install copied)" FAIL 1 "art-missing" ""
  check "art frames only: 4 missing of 5, three of them named" bash -c "[ \"$(jget art.missing)\" = 4 ] && printf '%s' \"$(jget art.first_missing)\" | grep -qF 'looks/helmet/layer.png'"
}
scn_post_art_atlas_missing() {
  new_sandbox post-art-no-atlas; rm -- "$ROOT_/art/clawd-atlas.json"; run_post
  expect "the installed atlas is gone" FAIL 1 "art-missing" ""
}
scn_post_art_a_symlink_is_not_a_file() {
  new_sandbox post-art-link; rm -- "$ROOT_/art/looks/helmet/layer.png"; ln -s "$ROOT_/art/frames/idle_0.png" "$ROOT_/art/looks/helmet/layer.png"; run_post
  expect "a symlink in the art tree is not an installed file" FAIL 1 "art-missing" ""
}
scn_post_art_is_checked_when_the_pet_is_not_loaded() {
  new_sandbox post-art-not-loaded; echo unloaded > "$STUB/launchctl.1"; rm -- "$ROOT_/art/motions/A1-thinking/001.png"; run_post
  expect "not loaded and an art file missing" FAIL 1 "art-missing" "not-loaded"
}
scn_post_interrupt() {
  new_sandbox post-interrupt; SETTLE=20
  env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_POSTINSTALL_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" \
    CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S=20 \
    STUB_DIR="$STUB" "$CHECK_BASH" "$POST" > "$SB/out" 2>&1 &
  local pid=$!
  wait_until 400 bash -c "[ -s '$STUB/launchctl.count' ]"
  check "interrupt: the script is inside its 20 s wait" bash -c "kill -0 '$pid' 2>/dev/null"
  kill -TERM "$pid"
  wait "$pid"; RC=$?
  JSON="$(ls "$SB"/evidence/post-install-check-*.json 2>/dev/null | head -n 1)"
  check "interrupt: exit 3" equals "$RC" 3
  check "interrupt: NOT RUN with the reason interrupted" bash -c "[ \"$(jget verdict)\" = 'NOT RUN' ] && [ \"$(codes notrun_codes)\" = interrupted ]"
  check "interrupt: nothing from the install was run" bash -c "[ ! -e '$STUB/agent.pids' ]"
}

# ---- pre-install-snapshot.sh --------------------------------------------------------------------------------------------------------------
snap_sandbox() { # NAME: a fake HOME with the three shared parents, nothing installed, launchctl not listing the label
  SB="$STAGE/$1"
  H="$SB/home"
  ROOT_="$H/Library/Application Support/clawd-pet"; MARKER_="$H/Library/Application Support/clawd-pet.installing"
  PLIST_="$H/Library/LaunchAgents/$LABEL.plist"; CLI_="$H/bin/clawd-pet"
  STUB="$SB/stub"
  mkdir -p "$H/bin" "$H/Library/LaunchAgents" "$H/Library/Application Support" "$STUB" "$SB/evidence" || return 1
  : > "$SB/.snapshot-sandbox"
  echo unloaded > "$STUB/launchctl.1"; echo unloaded > "$STUB/launchctl.2"; echo unloaded > "$STUB/launchctl.3"
  printf 'keep\n' > "$H/bin/other-tool"
}
run_snap() { # arguments -> OUT, RC
  OUT="$(env -i HOME="$H" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_SNAPSHOT_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" STUB_DIR="$STUB" \
    "$CHECK_BASH" "$SNAP" "$@" 2>&1)"
  RC=$?
}
snap_file() { ls "$SB"/evidence/pre-install-listing-*.txt 2>/dev/null | head -n 1; }
clean_body() {
  printf 'absent: %s\nabsent: %s\nabsent: %s\nabsent: %s\nparent exists: %s\nparent exists: %s\nparent exists: %s\nlabel: not loaded\n' \
    "$ROOT_" "$MARKER_" "$PLIST_" "$CLI_" "$H/bin" "$H/Library/LaunchAgents" "$H/Library/Application Support"
}
home_tree() { (cd "$H" && LC_ALL=C find . -print | LC_ALL=C sort && LC_ALL=C find . -type f -exec /usr/bin/cksum {} + | LC_ALL=C sort -k3); }
simulate_install() {
  mkdir -p "$ROOT_/bin" "$ROOT_/art/frames" "$ROOT_/probe"
  printf 'agent' > "$ROOT_/bin/clawd-pet-agent"; printf '{}' > "$ROOT_/art/clawd-atlas.json"; printf 'png' > "$ROOT_/art/frames/f1.png"
  printf 'schema 1\nend\n' > "$ROOT_/manifest"; printf 'root-created yes\n' > "$MARKER_"
  printf 'plist' > "$PLIST_"; printf 'cli' > "$CLI_"
}

scn_snap_clean() {
  snap_sandbox snap-clean; run_snap
  f="$(snap_file)"
  check "snapshot: exit 0 and the file path is printed" bash -c "[ '$RC' = 0 ] && printf '%s' '$OUT' | grep -qF '$f'"
  check "snapshot: the header names the date and the commit" bash -c "head -n 1 '$f' | grep -q '^pre-install listing .* commit .'"
  check "snapshot: a clean machine lists the four roots absent, the three parents and the label, in that order" equals "$(tail -n +2 "$f")" "$(clean_body)"
  check "snapshot: the format matches the listing the main session wrote by hand (absent / parent exists / label lines)" bash -c "grep -c '^absent: \\|^parent exists: \\|^label: ' '$f' | grep -qx 8"
}
scn_snap_parent_missing() {
  snap_sandbox snap-parent; rm -- "$H/bin/other-tool"; rmdir "$H/bin"; run_snap; f="$(snap_file)"
  check "snapshot: a missing shared parent is listed as missing" grep -qxF "parent missing: $H/bin" "$f"
}
scn_snap_label_loaded() {
  snap_sandbox snap-loaded; echo 4242 > "$STUB/launchctl.1"; run_snap; f="$(snap_file)"
  check "snapshot: a loaded label is listed" grep -qxF "label: loaded" "$f"
}
scn_snap_installed_tree() {
  snap_sandbox snap-installed; simulate_install; ln -s "$H/bin/other-tool" "$ROOT_/dangling-link"; run_snap; f="$(snap_file)"
  sha="$(/usr/bin/shasum -a 256 < "$ROOT_/bin/clawd-pet-agent" | cut -d' ' -f1)"
  check "snapshot: a file is listed with its size and sha256" grep -qxF "file: $ROOT_/bin/clawd-pet-agent 5 $sha" "$f"
  check "snapshot: directories are listed" bash -c "grep -qxF 'dir: $ROOT_' '$f' && grep -qxF 'dir: $ROOT_/art/frames' '$f'"
  check "snapshot: a symlink is listed with its target" grep -qxF "link: $ROOT_/dangling-link -> $H/bin/other-tool" "$f"
  check "snapshot: the marker, the plist and the CLI are listed as files" bash -c "grep -q '^file: $MARKER_ ' '$f' && grep -q '^file: $PLIST_ ' '$f' && grep -q '^file: $CLI_ ' '$f'"
}
scn_snap_read_only() {
  snap_sandbox snap-readonly; simulate_install; before="$(home_tree)"
  run_snap; run_snap --compare "$(snap_file)"
  check "snapshot and compare change nothing under the fake HOME" test "$(home_tree)" = "$before"
}
scn_snap_never_overwrites() {
  snap_sandbox snap-twice; run_snap; run_snap
  check "two snapshots in the same second make two files" equals "$(ls "$SB"/evidence/pre-install-listing-*.txt | wc -l | tr -d ' ')" 2
}
scn_snap_compare_equal_after_uninstall() {
  snap_sandbox snap-cmp-equal; run_snap; saved="$(snap_file)"
  simulate_install; printf 'a log\n' > "$ROOT_/agent.log"; printf 'an older log\n' > "$ROOT_/agent.log.1"
  run_snap --compare "$saved"
  check "compare: an installed tree differs from the clean listing (exit 1)" equals "$RC" 1
  check "compare: ... and the difference names an installed file" contains "$OUT" "$ROOT_/bin/clawd-pet-agent"
  # the uninstall: everything listed goes, the retained logs stay
  rm -- "$ROOT_/bin/clawd-pet-agent" "$ROOT_/art/clawd-atlas.json" "$ROOT_/art/frames/f1.png" "$ROOT_/manifest" "$MARKER_" "$PLIST_" "$CLI_"
  rmdir "$ROOT_/bin" "$ROOT_/art/frames" "$ROOT_/art" "$ROOT_/probe"
  run_snap --compare "$saved"
  check "compare: after the uninstall only the retained logs are left: equal (exit 0)" equals "$RC" 0
  check "compare: ... and it says equal" contains "$OUT" "equal"
  printf 'the agent logged more\n' >> "$ROOT_/agent.log"
  run_snap --compare "$saved"
  check "compare: a retained log whose content grew is not a difference" equals "$RC" 0
}
scn_snap_compare_differs() {
  snap_sandbox snap-cmp-diff; run_snap; saved="$(snap_file)"
  for what in "marker:$MARKER_" "plist:$PLIST_" "cli:$CLI_"; do
    run_snap --compare "$saved"; check "compare: clean again before $what (exit 0)" equals "$RC" 0
    printf 'x' > "${what#*:}"
    run_snap --compare "$saved"
    check "compare: a leftover ${what%%:*} is a difference (exit 1)" equals "$RC" 1
    check "compare: ... and it names the file" contains "$OUT" "${what#*:}"
    rm -- "${what#*:}"
  done
  mkdir "$ROOT_"; printf 'x' > "$ROOT_/state.json"
  run_snap --compare "$saved"
  check "compare: a \$ROOT that holds more than the retained logs is a difference" equals "$RC" 1
  rm -- "$ROOT_/state.json"; printf 'log\n' > "$ROOT_/agent.log"
  run_snap --compare "$saved"
  check "compare: an empty-but-for-logs \$ROOT equals an absent one" equals "$RC" 0
  rm -- "$ROOT_/agent.log"; rmdir "$ROOT_"
  echo 4242 > "$STUB/launchctl.3"
  run_snap --compare "$saved"
  check "compare: a loaded label is a difference" equals "$RC" 1
}
scn_snap_compare_with_the_hand_written_format() {
  snap_sandbox snap-cmp-hand
  { echo "pre-install listing 2026-10-17 12:31:45 CDT commit 7aa5b22"; clean_body; } > "$SB/hand-written.txt"
  run_snap --compare "$SB/hand-written.txt"
  check "compare: the listing the main session wrote by hand (same lines, header on top) equals a clean machine" equals "$RC" 0
}
scn_snap_compare_saved_with_retained_logs() {
  snap_sandbox snap-cmp-saved-logs
  mkdir "$ROOT_"; printf 'old log\n' > "$ROOT_/agent.log"; printf 'older\n' > "$ROOT_/agent.log.1"
  run_snap; saved="$(snap_file)"
  check "snapshot: retained logs in \$ROOT are listed as files" grep -q "^file: $ROOT_/agent.log " "$saved"
  printf 'the agent logged more\n' >> "$ROOT_/agent.log"; rm -- "$ROOT_/agent.log.1"
  run_snap --compare "$saved"
  check "compare: a saved listing that held retained logs equals the machine whose logs changed or went" equals "$RC" 0
}
scn_snap_compare_bad_file() {
  snap_sandbox snap-cmp-bad; run_snap --compare "$SB/does-not-exist.txt"
  check "compare: a missing file is refused (64)" equals "$RC" 64
  run_snap --compare
  check "compare: --compare without a file is refused (64)" equals "$RC" 64
}

# ---- direct-exec-check.sh (the gated step; it runs a COPY of the installed agent outside the install) ---------------------------------------
# new_dx_sandbox NAME: the same fake HOME; the window lister is the stub, the limits are generous (a loaded machine must not turn a
# pass into a failure) and the stand-in agent lingers 0.3 s so that the window list can be read while it lives.
new_dx_sandbox() {
  new_sandbox "$1"
  echo linger > "$STUB/agent.mode"
  DX_LIMIT_MS=20000; DX_GAP_MS=1000; DX_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
}
run_dx() { # extra arguments -> OUT, RC, JSON
  OUT="$(env -i HOME="$SB/home" PATH="$DX_PATH" CLAWD_DIRECTEXEC_SANDBOX="$SB" CLAWD_DIRECTEXEC_SAMPLER="$STUBS/sampler" \
    CLAWD_DIRECTEXEC_LIMIT_MS="$DX_LIMIT_MS" CLAWD_DIRECTEXEC_MAX_GAP_MS="$DX_GAP_MS" STUB_DIR="$STUB" "$CHECK_BASH" "$DX" --run-a-copy "$@" 2>"$SB/stderr")"
  RC=$?
  JSON="$(ls "$SB"/evidence/direct-exec-check-*.json 2>/dev/null | head -n 1)"
}
dx_expect() { # LABEL VERDICT EXIT FAIL-CODES NOTRUN-CODES
  local label="$1" verdict="$2" rc="$3" fc="$4" nc="$5"
  check "$label: verdict $verdict" equals "$(jget verdict)" "$verdict"
  check "$label: exit $rc" equals "$RC" "$rc"
  check "$label: fail codes [$fc]" equals "$(codes fail_codes)" "$fc"
  check "$label: not-run codes [$nc]" equals "$(codes notrun_codes)" "$nc"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "direct-exec-check: $verdict"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: the installed agent was never run (only a copy outside the install, if anything)" bash -c "! grep -qxF '$ROOT_/bin/clawd-pet-agent' '$STUB/agent.paths' 2>/dev/null"
}
scn_dx_pass() {
  new_dx_sandbox dx-pass; HOME_BEFORE="$(home_digest)"; run_dx
  dx_expect "a copy that lives 0.3 s, exits 0 and shows no window, observed throughout" PASS 0 "" ""
  copy="$(jget copy.path)"
  check "pass: the copy lies outside the install, in the check's own work directory" bash -c "case '$copy' in '$ROOT_'/*) exit 1 ;; '$SB/evidence/direct-exec-check-work/'*/copy/clawd-pet-agent) exit 0 ;; *) exit 1 ;; esac"
  check "pass: the only program started was that copy, once" bash -c "[ \"\$(wc -l < '$STUB/agent.paths' | tr -d ' ')\" = 1 ] && [ \"\$(cat '$STUB/agent.paths')\" = '$copy' ]"
  check "pass: the copy is byte-identical to the installed agent (sha256 in the evidence)" bash -c "[ \"$(jget copy.sha256)\" = \"$(jget copy.installed_sha256_before)\" ] && [ \"$(jget copy.installed_sha256_after)\" = \"$(jget copy.installed_sha256_before)\" ] && cmp -s '$copy' '$ROOT_/bin/clawd-pet-agent'"
  check "pass: at least one read of the window list began and ended while the copy lived" bash -c "[ \"$(jget direct_exec.reads_inside_the_life)\" -ge 1 ]"
  check "pass: no read failed, and no window was seen" bash -c "[ \"$(jget direct_exec.reads_failed)\" = 0 ] && [ \"$(jget direct_exec.windows_seen)\" = 0 ]"
  check "pass: the exit status is 0 and the elapsed time is recorded" bash -c "[ \"$(jget direct_exec.exit_status)\" = 0 ] && [ \"$(jget direct_exec.elapsed_ms)\" -gt 0 ]"
  check "pass: the install is untouched (the fake HOME digest is the one before)" test "$(home_digest)" = "$HOME_BEFORE"
}
scn_dx_copy_runs_in_its_own_home() {
  # Codex e (Sprint 10 round 1, pre-existing). The copy of the agent used to inherit the real HOME: an install whose start guard regressed,
  # the real agent stopped, and the gated step run, and the copy opened the real data directory and wrote the real log and status. The
  # stand-in agent in homewrite mode behaves like that agent: it writes its data directory, agent.log and status.json under $HOME, and says
  # which HOME, CFFIXED_USER_HOME and working directory it was started with. Nothing of it may land in the (fake) real HOME.
  new_dx_sandbox dx-own-home; echo homewrite > "$STUB/agent.mode"; HOME_BEFORE="$(home_digest)"; run_dx
  dx_expect "a copy that writes its data under its HOME, as an agent whose launch guard regressed would" PASS 0 "" ""
  scratch="$(jget copy.scratch_home)"
  check "own home: the real (fake) HOME's digest is unchanged: nothing the copy wrote reached the install" test "$(home_digest)" = "$HOME_BEFORE"
  check "own home: the copy was started with a HOME that is not the real one" bash -c "[ -n '$scratch' ] && [ \"\$(cat '$STUB/agent.home')\" = '$scratch' ] && [ \"\$(cat '$STUB/agent.home')\" != '$SB/home' ]"
  check "own home: ... a new directory inside the check's own work directory" bash -c "case '$scratch' in '$SB/evidence/direct-exec-check-work/'*/home) exit 0 ;; *) exit 1 ;; esac"
  check "own home: CFFIXED_USER_HOME is the same directory and so is the working directory" bash -c "[ \"\$(cat '$STUB/agent.cffixed')\" = '$scratch' ] && [ \"\$(cat '$STUB/agent.cwd')\" = \"\$(cd -P '$scratch' && pwd -P)\" ]"
  check "own home: what the copy wrote is under the scratch HOME, in its own data directory" bash -c "[ -f '$scratch/Library/Application Support/clawd-pet/agent.log' ] && [ -f '$scratch/Library/Application Support/clawd-pet/status.json' ]"
  check "own home: the evidence counts the files the copy left there" bash -c "[ \"$(jget copy.files_the_copy_left_in_the_scratch_home)\" -ge 2 ]"
  check "own home: the real install's agent.log and status.json were not created" bash -c "[ ! -e '$ROOT_/agent.log' ] && [ ! -e '$ROOT_/status.json' ]"
}
scn_dx_observer_refuses_a_home_that_is_not_isolated() {
  # The observer is the one that forks and execs, so it checks the HOME it is given itself, whatever the shell script did: no HOME, a
  # relative path, a path that does not exist, a symbolic link and a directory that is not empty are all refused (exit 2) and the program
  # is never started. A new empty directory is accepted and the program sees it as its HOME.
  new_dx_sandbox dx-observer-home; echo homewrite > "$STUB/agent.mode"
  local obs="$REPO/scripts/direct-exec-observe.pl" od="$SB/obs" rc
  mkdir -p "$od/nonempty" "$od/real" "$od/empty" || return 1
  : > "$od/nonempty/file"; ln -s "$od/real" "$od/link"
  obs_run() { env -i PATH="/usr/bin:/bin" STUB_DIR="$STUB" /usr/bin/perl "$obs" "$STUBS/sampler" 20000 "$STUBS/agent" "$od/obs.log" "$@" 2>"$od/obs.err"; }
  obs_run; rc=$?;                       check "observer: no HOME argument is refused (exit 2)" equals "$rc" 2
  ( cd "$od" && mkdir -p relative-home && obs_run relative-home ); rc=$?; check "observer: a relative HOME is refused (exit 2), also one that exists" equals "$rc" 2
  obs_run "$od/missing"; rc=$?;         check "observer: a HOME that does not exist is refused (exit 2)" equals "$rc" 2
  obs_run "$od/link"; rc=$?;            check "observer: a HOME that is a symbolic link is refused (exit 2)" equals "$rc" 2
  obs_run "$od/nonempty"; rc=$?;        check "observer: a HOME that is not empty is refused (exit 2)" equals "$rc" 2
  check "observer: none of the refused runs started the program" bash -c "[ ! -e '$STUB/agent.pids' ]"
  obs_run "$od/empty"; rc=$?
  check "observer: a new empty directory is accepted (exit 0) and the program ran" bash -c "[ '$rc' = 0 ] && [ \"\$(wc -l < '$STUB/agent.pids' | tr -d ' ')\" = 1 ]"
  check "observer: ... with that directory as its HOME" bash -c "[ \"\$(cat '$STUB/agent.home')\" = '$od/empty' ] && grep -qx 'HOME $od/empty' '$od/obs.log'"
}
scn_dx_pass_keeps_install() {
  new_dx_sandbox dx-install-untouched; HOME_BEFORE="$(home_digest)"; run_dx
  dx_expect "a healthy run" PASS 0 "" ""
  check "the install and everything else under the fake HOME is unchanged" test "$(home_digest)" = "$HOME_BEFORE"
}
scn_dx_exits_at_once_is_not_observed() {
  # A copy that is gone before one read of the window list is finished (the lister takes 1 s here; a program lives a fraction of that,
  # also on its first exec from a new path, which macOS checks first): nothing was observed, and that is not a PASS.
  new_dx_sandbox dx-instant; echo exit0 > "$STUB/agent.mode"; echo 1 > "$STUB/windows.delay"; DX_GAP_MS=5000; run_dx
  dx_expect "a copy that exits before one read fits in its life" "NOT RUN" 3 "" "direct-exec-not-observed"
  check "instant exit: reads were taken, none inside the life" bash -c "[ \"$(jget direct_exec.window_list_reads)\" -ge 1 ] && [ \"$(jget direct_exec.reads_inside_the_life)\" = 0 ]"
  # Finding f (Sprint 10 round 2): on a real machine a read of the window list (about 35 ms) takes longer than the copy lives (about 6 ms),
  # so the step is NOT RUN whatever the copy does. The reason says that, with the figures, instead of a bare 'no read fitted'.
  check "instant exit: the evidence has the shortest and the longest read, both of a 1 s lister" bash -c "[ \"$(jget direct_exec.shortest_read_ms)\" -ge 900 ] && [ \"$(jget direct_exec.longest_read_ms)\" -ge \"$(jget direct_exec.shortest_read_ms)\" ]"
  check "instant exit: the reason says that a read takes longer than the copy lives, and names the shortest read" bash -c "r=\"\$(/usr/bin/plutil -extract notrun_reasons json -o - '$JSON')\"; case \"\$r\" in *'the shortest took '*' ms'*'a read takes longer than the copy lives, and this instrument cannot see a program that short'*) exit 0 ;; *) exit 1 ;; esac"
}
scn_dx_exit_nonzero() {
  new_dx_sandbox dx-exit3; echo linger3 > "$STUB/agent.mode"; run_dx
  dx_expect "the copy exits 3" FAIL 1 "direct-exec-exit-nonzero" ""
  check "exit 3: the status is recorded" equals "$(jget direct_exec.exit_status)" 3
}
scn_dx_too_slow() {
  new_dx_sandbox dx-slow; echo slow > "$STUB/agent.mode"; DX_LIMIT_MS=600; run_dx
  dx_expect "the copy is still running at the limit" FAIL 1 "direct-exec-too-slow" ""
  pid="$(jget direct_exec.pid)"
  check "slow: the process the script started was stopped" wait_until 100 bash -c "case '$pid' in ''|*[!0-9]*) exit 1 ;; esac; ! kill -0 '$pid' 2>/dev/null"
  check "slow: the limit is recorded as hit" equals "$(jget direct_exec.limit_hit)" true
}
scn_dx_exits_inside_a_read_that_ends_past_the_limit() {
  # Codex (on a2c9368): the copy exits 0 during a slow read that ends past the limit. The observer reaps it before its limit test, so no
  # LIMIT line is written and only the elapsed-time test in decide() makes the run too slow (mutation row dx-elapsed-time-ignored).
  # Not timed (Codex on f18467b, 4bd1114 and cda73a7: a copy that starts late or exits late outlives a fixed or bounded wait and takes
  # the LIMIT branch): the first read waits, with no bound, until the observer (the sampler's parent, handed over by the sampler stub as
  # CLAWD_STUB_LISTER_PARENT) has no live child but the sampler. The observer forks the copy before its first read and reaps it only after
  # a read, so the wait ends once the copy is seen exited (a zombie; a failed or empty ps listing is retried), and the read then takes 1 s
  # more: it ends after the exit and past the 500 ms limit. The wait has no bound: it ends once a listing succeeds after the copy exited.
  new_dx_sandbox dx-exit-inside-a-late-read; echo exit0 > "$STUB/agent.mode"; DX_LIMIT_MS=500; DX_GAP_MS=600000
  cat > "$STUB/windows.hook.1" <<'HOOK'
obs="${CLAWD_STUB_LISTER_PARENT:-}"
case "$obs" in ''|*[!0-9]*) echo "windows.hook.1: no lister parent" >&2; exit 1 ;; esac
while :; do
  list="$(/bin/ps -ax -o ppid=,pid=,stat= 2>/dev/null)" && [ -n "$list" ] || { sleep 0.02; continue; }
  printf '%s\n' "$list" | /usr/bin/awk -v o="$obs" -v s="$PPID" '$1 == o && $2 != s && $3 !~ /^Z/ { found = 1 } END { exit !found }' || break
  sleep 0.02
done
HOOK
  echo 1 > "$STUB/windows.delay.1"; run_dx
  dx_expect "the copy exits 0 inside a read that ends past the limit" FAIL 1 "direct-exec-too-slow" "direct-exec-not-observed"
  check "late read: the limit was not hit, the copy exited 0, and it was reaped after the limit" bash -c "[ \"$(jget direct_exec.limit_hit)\" = false ] && [ \"$(jget direct_exec.exit_status)\" = 0 ] && [ \"$(jget direct_exec.elapsed_ms)\" -gt 500 ]"
}
scn_dx_window() {
  new_dx_sandbox dx-window; echo window > "$STUB/agent.mode"; run_dx
  dx_expect "the copy registers a window of its own pid" FAIL 1 "direct-exec-window" ""
  check "window: the sightings are counted" bash -c "[ \"$(jget direct_exec.windows_seen)\" -ge 1 ]"
}
scn_dx_window_of_another_pid_is_not_the_copys() {
  new_dx_sandbox dx-other-window; { echo 'WINDOW 777 0 1 0.0 0.0 1512.0 982.0 10'; echo 'WINDOW 4242 3 1 100.0 200.0 48.0 48.0 51'; } > "$STUB/windows.1"; run_dx
  dx_expect "windows of other pids are in every list and none is the copy's" PASS 0 "" ""
}
scn_dx_lister_fails_while_running() {
  new_dx_sandbox dx-lister-mid; n=2; while [ "$n" -le 600 ]; do : > "$STUB/windows.fail.$n"; n=$((n + 1)); done; run_dx
  dx_expect "every read after the first fails while the copy runs" "NOT RUN" 3 "" "window-lister-failed"
  check "lister failure: failed reads are counted" bash -c "[ \"$(jget direct_exec.reads_failed)\" -ge 1 ]"
}
scn_dx_one_failed_read_among_good_ones() {
  # A single failed read is enough: the claim needs every read, not most of them.
  new_dx_sandbox dx-lister-one; : > "$STUB/windows.fail.3"; run_dx
  dx_expect "one failed read among good ones" "NOT RUN" 3 "" "window-lister-failed"
  check "one failed read: exactly one is counted" equals "$(jget direct_exec.reads_failed)" 1
}
scn_dx_lister_always_fails() {
  new_dx_sandbox dx-lister-all; n=1; while [ "$n" -le 600 ]; do : > "$STUB/windows.fail.$n"; n=$((n + 1)); done; run_dx
  dx_expect "no read succeeds" "NOT RUN" 3 "" "direct-exec-not-observed,window-lister-failed"
  check "lister never works: the old rule (PASS when the first look found nothing) is gone: the verdict is not PASS" equals "$(jget verdict)" "NOT RUN"
}
scn_dx_truncated_list() {
  new_dx_sandbox dx-trunc; : > "$STUB/windows.truncated.2"; run_dx
  dx_expect "a window list without its footer in the middle of the run" "NOT RUN" 3 "" "window-lister-failed"
}
scn_dx_gap_too_long() {
  # With no gap allowed at all, the first read cannot begin at the very instant of the exec: the gap check must fire.
  new_dx_sandbox dx-gap; DX_GAP_MS=0; run_dx
  dx_expect "a gap between the exec and the first read (and between reads) above the allowed 0 ms" "NOT RUN" 3 "" "direct-exec-observation-gap"
  check "gap: the longest gap is recorded and above 0" bash -c "[ \"$(jget direct_exec.longest_gap_ms)\" -gt 0 ] && [ \"$(jget direct_exec.max_gap_allowed_ms)\" = 0 ]"
  check "gap: a read longer than the allowed gap leaves the limit unmeetable, and the reason says so" bash -c "case \"\$(/usr/bin/plutil -extract notrun_reasons json -o - '$JSON')\" in *'longer than the allowed gap, so this limit can never be met'*) exit 0 ;; *) exit 1 ;; esac"
}
# A read of the window list shows the windows as they are at ONE instant somewhere between its start and its end: the time inside a read is
# unobserved. The stand-in lister makes its list when the call returns, after any delay.
scn_dx_slow_read_between_two_reads() {
  # The finding's trigger: read 1 ends at about 20 ms; read 2 starts at once and takes 0.5 s (a window of the copy that came at 0.1 s and
  # went at 0.2 s is in neither list, and no list here shows one). The gap from the end of read 1 to the start of read 2 is about 1 ms: the
  # old rule said PASS.
  new_dx_sandbox dx-slow-read; DX_GAP_MS=300; echo 0.5 > "$STUB/windows.delay.2"; run_dx
  dx_expect "a read of the window list that takes 0.5 s, between two fast ones" "NOT RUN" 3 "" "direct-exec-observation-gap"
  check "slow read: no window was seen and no read failed (the NOT RUN is the gap rule alone)" bash -c "[ \"$(jget direct_exec.windows_seen)\" = 0 ] && [ \"$(jget direct_exec.reads_failed)\" = 0 ]"
  check "slow read: a read fitted inside the copy's life, so the old rule's other conditions held" bash -c "[ \"$(jget direct_exec.reads_inside_the_life)\" -ge 1 ]"
  check "slow read: the stretch from one read's start to the next read's end is above the 300 ms allowed" bash -c "[ \"$(jget direct_exec.longest_gap_ms)\" -ge 450 ] && [ \"$(jget direct_exec.max_gap_allowed_ms)\" = 300 ]"
}
scn_dx_slow_first_read() {
  # The first read takes 0.45 s, the copy lives 1 s and the later reads are fast. Nothing can have been seen between the exec and the end
  # of the first read; the old rule measured only the exec to the START of the first read.
  new_dx_sandbox dx-slow-first; echo linger1 > "$STUB/agent.mode"; DX_GAP_MS=300; echo 0.45 > "$STUB/windows.delay.1"; run_dx
  dx_expect "the first read of the window list takes 0.45 s" "NOT RUN" 3 "" "direct-exec-observation-gap"
  check "slow first read: a read fitted inside the copy's life and no window was seen" bash -c "[ \"$(jget direct_exec.reads_inside_the_life)\" -ge 1 ] && [ \"$(jget direct_exec.windows_seen)\" = 0 ]"
  check "slow first read: the stretch from the exec to the end of the first read is above the 300 ms allowed" bash -c "[ \"$(jget direct_exec.longest_gap_ms)\" -ge 400 ]"
}
scn_dx_slow_first_read_inside_the_allowed_gap_passes() {
  # The control of the two above: the same 0.45 s first read, with the default allowance of 1000 ms: PASS. The rule is a threshold on the
  # stretch no read can have seen, not a NOT RUN for every slow read.
  new_dx_sandbox dx-slow-first-allowed; echo linger1 > "$STUB/agent.mode"; echo 0.45 > "$STUB/windows.delay.1"; run_dx
  dx_expect "the first read takes 0.45 s and 1000 ms are allowed" PASS 0 "" ""
  check "slow first read inside the allowance: the longest stretch is above 400 ms and not above the allowed 1000 ms" bash -c "[ \"$(jget direct_exec.longest_gap_ms)\" -ge 400 ] && [ \"$(jget direct_exec.longest_gap_ms)\" -le 1000 ]"
}
scn_dx_copy_differs() {
  new_dx_sandbox dx-copy-differs; mkdir -p "$SB/shims"
  printf '#!/bin/sh\n/bin/cp "$@" || exit $?\nfor last; do :; done\nprintf X >> "$last"\n' > "$SB/shims/cp"; chmod 755 "$SB/shims/cp"
  DX_PATH="$SB/shims:/usr/bin:/bin:/usr/sbin:/sbin"; run_dx
  dx_expect "a copy that is not byte-identical to the installed agent" FAIL 1 "direct-exec-copy-differs" ""
  check "copy differs: nothing was run" bash -c "[ ! -e '$STUB/agent.pids' ]"
}
scn_dx_not_installed() {
  new_dx_sandbox dx-not-installed; rm -- "$ROOT_/manifest"; run_dx
  dx_expect "no manifest" "NOT RUN" 3 "" "not-installed"
  check "not installed: nothing was copied or run" bash -c "[ ! -e '$STUB/agent.pids' ] && [ ! -d '$SB/evidence/direct-exec-check-work' ] || ! find '$SB/evidence/direct-exec-check-work' -name clawd-pet-agent | grep -q ."
}
scn_dx_agent_not_executable() {
  new_dx_sandbox dx-not-exec; chmod 644 "$ROOT_/bin/clawd-pet-agent"; run_dx
  dx_expect "the installed agent is not executable" "NOT RUN" 3 "" "direct-exec-failed-to-start"
}
scn_dx_agent_is_a_symlink() {
  new_dx_sandbox dx-link; mv "$ROOT_/bin/clawd-pet-agent" "$ROOT_/bin/real-agent"; ln -s "$ROOT_/bin/real-agent" "$ROOT_/bin/clawd-pet-agent"; run_dx
  dx_expect "the installed agent is a symlink" "NOT RUN" 3 "" "direct-exec-failed-to-start"
  check "symlink: nothing was run" bash -c "[ ! -e '$STUB/agent.pids' ]"
}
scn_dx_sampler_missing() {
  new_dx_sandbox dx-no-sampler
  OUT="$(env -i HOME="$SB/home" PATH="$DX_PATH" CLAWD_DIRECTEXEC_SANDBOX="$SB" CLAWD_DIRECTEXEC_SAMPLER="$SB/no-such-sampler" CLAWD_DIRECTEXEC_LIMIT_MS=1000 CLAWD_DIRECTEXEC_MAX_GAP_MS=100 \
    STUB_DIR="$STUB" "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
  check "a window lister that does not exist is refused by the sandbox gate (64)" equals "$RC" 64
}
scn_dx_interrupt() {
  new_dx_sandbox dx-interrupt; echo slow > "$STUB/agent.mode"
  env -i HOME="$SB/home" PATH="$DX_PATH" CLAWD_DIRECTEXEC_SANDBOX="$SB" CLAWD_DIRECTEXEC_SAMPLER="$STUBS/sampler" CLAWD_DIRECTEXEC_LIMIT_MS=20000 \
    CLAWD_DIRECTEXEC_MAX_GAP_MS=1000 STUB_DIR="$STUB" "$CHECK_BASH" "$DX" --run-a-copy > "$SB/out" 2>&1 &
  local pid=$!
  wait_until 400 bash -c "[ -s '$STUB/agent.pids' ]"
  local apid; apid="$(tail -n 1 "$STUB/agent.pids")"
  check "interrupt: the script is inside the run, the copy lives" bash -c "kill -0 '$pid' 2>/dev/null && kill -0 '$apid' 2>/dev/null"
  kill -TERM "$pid"
  wait "$pid"; RC=$?
  JSON="$(ls "$SB"/evidence/direct-exec-check-*.json 2>/dev/null | head -n 1)"
  check "interrupt: exit 3" equals "$RC" 3
  check "interrupt: NOT RUN with the reason interrupted" bash -c "[ \"$(jget verdict)\" = 'NOT RUN' ] && [ \"$(codes notrun_codes)\" = interrupted ]"
  check "interrupt: the copy the script started is gone" wait_until 100 bash -c "! kill -0 '$apid' 2>/dev/null"
}

# ---- post-install-settings-step.sh (the gated step that changes a setting on the running agent and puts it back) -------------------------
# new_ss_sandbox NAME: the pet is installed and loaded (pid 4242), walking is on, and the stand-in CLI + agent behave (Tests/attended-stubs/settings-cli).
new_ss_sandbox() {
  new_sandbox "$1"
  printf '{"scale":1,"walk":true,"generation":0}\n' > "$ROOT_/control.json"
  printf '{"focusViolations":0,"appliedGeneration":0}\n' > "$ROOT_/status.json"
  printf '1792000000.000001 STATE scene=idle\n' > "$ROOT_/agent.log"
  echo ok > "$STUB/cli.mode"
  for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo 4242 > "$STUB/launchctl.$k"; done
}
run_ss() { # extra arguments -> OUT, RC, JSON
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_SETTINGS_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_SETTINGS_CLI="$STUBS/settings-cli" \
    STUB_DIR="$STUB" "$CHECK_BASH" "$SS" --change-a-setting "$@" 2>"$SB/stderr")"
  RC=$?
  JSON="$(ls "$SB"/evidence/post-install-settings-step-*.json 2>/dev/null | head -n 1)"
}
ss_expect() { # LABEL VERDICT EXIT FAIL-CODES NOTRUN-CODES
  local label="$1" verdict="$2" rc="$3" fc="$4" nc="$5"
  check "$label: verdict $verdict" equals "$(jget verdict)" "$verdict"
  check "$label: exit $rc" equals "$RC" "$rc"
  check "$label: fail codes [$fc]" equals "$(codes fail_codes)" "$fc"
  check "$label: not-run codes [$nc]" equals "$(codes notrun_codes)" "$nc"
  check "$label: the last stdout line is the one-line verdict" contains "$(last_line)" "post-install-settings-step: $verdict"
  check "$label: the evidence file is valid JSON" /usr/bin/plutil -convert json -o /dev/null "$JSON"
  check "$label: the CLI was only ever asked for walk on / walk off" bash -c "[ ! -s '$STUB/cli.violations' ]"
  check "$label: launchctl was only ever asked to list" bash -c "[ ! -s '$STUB/launchctl.violations' ] && ! grep -v '^launchctl list ' '$STUB/launchctl.calls'"
}
scn_ss_pass_walking_on() {
  new_ss_sandbox ss-pass-on; run_ss
  ss_expect "walking on at the start: off, then on" PASS 0 "" ""
  check "pass: the CLI was run twice, walk off then walk on" equals "$(paste -sd, - < "$STUB/cli.calls")" "walk off,walk on"
  check "pass: the setting ended where it started (walk true)" equals "$(/usr/bin/plutil -extract walk raw -o - "$ROOT_/control.json")" true
  check "pass: the evidence records the original, the flipped and the final value" bash -c "[ \"$(jget walk.original)\" = true ] && [ \"$(jget walk.after_first_change)\" = false ] && [ \"$(jget walk.at_the_end)\" = true ]"
  check "pass: generation rose by one per change and each was applied (status.json)" bash -c "[ \"$(/usr/bin/plutil -extract generation raw -o - "$ROOT_/control.json")\" = 2 ] && [ \"$(/usr/bin/plutil -extract appliedGeneration raw -o - "$ROOT_/status.json")\" = 2 ]"
  check "pass: both steps saw the SETTINGS line and then the WALK line" bash -c "[ \"$(jget steps.0.log_lines_seen)\" = '1 1 1' ] && [ \"$(jget steps.1.log_lines_seen)\" = '1 1 1' ]"
  check "pass: the agent's pid is recorded at both ends and is the same" bash -c "[ \"$(jget agent_pid.start)\" = 4242 ] && [ \"$(jget agent_pid.end)\" = 4242 ]"
}
scn_ss_pass_walking_off() {
  new_ss_sandbox ss-pass-off; printf '{"scale":1,"walk":false,"generation":5}\n' > "$ROOT_/control.json"; printf '{"appliedGeneration":5}\n' > "$ROOT_/status.json"; run_ss
  ss_expect "walking already off: on, then off" PASS 0 "" ""
  check "already off: the CLI was run twice, walk on then walk off" equals "$(paste -sd, - < "$STUB/cli.calls")" "walk on,walk off"
  check "already off: the setting ended where it started (walk false)" equals "$(/usr/bin/plutil -extract walk raw -o - "$ROOT_/control.json")" false
}
scn_ss_pass_walk_key_missing() {
  new_ss_sandbox ss-pass-nokey; printf '{"scale":1,"generation":0}\n' > "$ROOT_/control.json"; run_ss
  ss_expect "no walk key (the default is on)" PASS 0 "" ""
  check "no walk key: it was read as on, so the first change was off" equals "$(head -n 1 "$STUB/cli.calls")" "walk off"
}
scn_ss_pass_late_log() {
  new_ss_sandbox ss-late-log; echo late-log > "$STUB/cli.mode"; run_ss
  ss_expect "the agent's log lines arrive 0.6 s after the CLI returns" PASS 0 "" ""
}
scn_ss_unconfirmed() {
  new_ss_sandbox ss-unconfirmed; echo unconfirmed > "$STUB/cli.mode"; run_ss
  ss_expect "the CLI exits 3 (saved, not confirmed within 2 s)" FAIL 1 "cli-exit-nonzero,generation-not-applied,settings-line-missing" ""
}
scn_ss_stale_status() {
  new_ss_sandbox ss-stale; echo stale-status > "$STUB/cli.mode"; run_ss
  ss_expect "the CLI exits 0 but the agent never reported the generation" FAIL 1 "generation-not-applied" ""
}
scn_ss_no_settings_line() {
  new_ss_sandbox ss-no-settings; echo no-settings > "$STUB/cli.mode"; run_ss
  ss_expect "agent.log has WALK lines and no SETTINGS line" FAIL 1 "settings-line-missing" ""
}
scn_ss_no_walk_line() {
  new_ss_sandbox ss-no-walk; echo no-walk > "$STUB/cli.mode"; run_ss
  ss_expect "agent.log has SETTINGS lines and no WALK line" FAIL 1 "walk-line-missing" ""
}
scn_ss_wrong_order() {
  new_ss_sandbox ss-order; echo wrong-order > "$STUB/cli.mode"; run_ss
  ss_expect "the WALK line comes before the SETTINGS line" FAIL 1 "walk-line-out-of-order" ""
}
scn_ss_one_step_misbehaves() {
  # Only the first change loses its SETTINGS line; the second is healthy. The step still fails, and the setting is still put back.
  new_ss_sandbox ss-one-step; echo no-settings > "$STUB/cli.mode.1"; echo ok > "$STUB/cli.mode.2"; run_ss
  ss_expect "step 1 has only a WALK line" FAIL 1 "settings-line-missing" ""
  check "one step misbehaves: the second step ran and the setting is back (walk true)" bash -c "[ \"\$(paste -sd, - < '$STUB/cli.calls')\" = 'walk off,walk on' ] && [ \"$(/usr/bin/plutil -extract walk raw -o - "$ROOT_/control.json")\" = true ]"
}
scn_ss_pid_changes() {
  new_ss_sandbox ss-pid; echo restart > "$STUB/cli.mode"; run_ss
  ss_expect "the agent's pid changes during the first change" FAIL 1 "agent-pid-changed" ""
}
scn_ss_not_installed() {
  new_ss_sandbox ss-not-installed; rm -- "$ROOT_/manifest"; run_ss
  ss_expect "no manifest" "NOT RUN" 3 "" "not-installed"
  check "not installed: the CLI was not run" bash -c "[ ! -e '$STUB/cli.calls' ]"
}
scn_ss_not_loaded() {
  new_ss_sandbox ss-not-loaded; echo unloaded > "$STUB/launchctl.1"; run_ss
  ss_expect "launchctl does not list the label" "NOT RUN" 3 "" "not-loaded"
  check "not loaded: the CLI was not run" bash -c "[ ! -e '$STUB/cli.calls' ]"
}
scn_ss_no_pid() {
  new_ss_sandbox ss-no-pid; echo nopid > "$STUB/launchctl.1"; run_ss
  ss_expect "loaded without a process" "NOT RUN" 3 "" "not-loaded"
}
scn_ss_cli_missing() {
  new_ss_sandbox ss-no-cli
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_SETTINGS_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_SETTINGS_CLI="$SB/no-such-cli" STUB_DIR="$STUB" "$CHECK_BASH" "$SS" --change-a-setting 2>&1)"; RC=$?
  check "a CLI seam that is not an executable file is refused by the sandbox gate (64)" equals "$RC" 64
}
scn_ss_control_unreadable() {
  new_ss_sandbox ss-control; printf 'not json' > "$ROOT_/control.json"; run_ss
  ss_expect "control.json is not readable" "NOT RUN" 3 "" "control-unreadable"
  check "control unreadable: the CLI was not run" bash -c "[ ! -e '$STUB/cli.calls' ]"
}
scn_ss_interrupt() {
  new_ss_sandbox ss-interrupt; echo sleep > "$STUB/cli.mode.1"
  env -i HOME="$SB/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" CLAWD_SETTINGS_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_SETTINGS_CLI="$STUBS/settings-cli" \
    STUB_DIR="$STUB" "$CHECK_BASH" "$SS" --change-a-setting > "$SB/out" 2>&1 &
  local pid=$!
  wait_until 400 bash -c "[ -s '$STUB/cli.calls' ]"
  check "interrupt: the script is inside the first change" bash -c "kill -0 '$pid' 2>/dev/null"
  kill -TERM "$pid"
  wait "$pid"; RC=$?
  JSON="$(ls "$SB"/evidence/post-install-settings-step-*.json 2>/dev/null | head -n 1)"
  check "interrupt: exit 3" equals "$RC" 3
  check "interrupt: NOT RUN with the reason interrupted" bash -c "[ \"$(jget verdict)\" = 'NOT RUN' ] && [ \"$(codes notrun_codes)\" = interrupted ]"
  check "interrupt: the setting was put back (walk true, as it was)" equals "$(/usr/bin/plutil -extract walk raw -o - "$ROOT_/control.json")" true
  check "interrupt: the restoring change was run (walk off, then walk on)" bash -c "[ \"\$(paste -sd, - < '$STUB/cli.calls')\" = 'walk off,walk on' ]"
}

for s in $(declare -F | awk '{ print $3 }' | grep '^scn_' | grep -v -e '^scn_post_interrupt$' -e '^scn_dx_interrupt$' -e '^scn_ss_interrupt$'); do wanted "$s" && spawn "$s"; done
wanted scn_post_interrupt && spawn scn_post_interrupt
wanted scn_dx_interrupt && spawn scn_dx_interrupt
wanted scn_ss_interrupt && spawn scn_ss_interrupt
drain

# ---- refusals and mode gates (fast, no stub run) ---------------------------------------------------------------------------------------
RES="$RESDIR/zz-refusals"; : > "$RES"
# Runs outside a sandbox use an EMPTY fake HOME: were a gate to fail, the script would find no install there and stop at not-installed.
EH="$STAGE/empty-home"; mkdir -p "$EH"
new_sandbox refusals
before_tree="$(cd "$EH" && find . | sort)"
for pair in "post:$POST:CLAWD_POSTINSTALL_SANDBOX:CLAWD_POSTINSTALL_SAMPLER" "snap:$SNAP:CLAWD_SNAPSHOT_SANDBOX:CLAWD_LAUNCHCTL"; do
  IFS=: read -r tag script sandbox_var seam <<EOF
$pair
EOF
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$script" 2>&1)"; RC=$?
  check "$tag: no --real outside a sandbox: exit 64" equals "$RC" 64
  check "$tag: no --real: says --real is needed" contains "$OUT" "--real"
  check "$tag: no --real: nothing was written (the fake HOME is unchanged)" test "$(cd "$EH" && find . | sort)" = "$before_tree"
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$seam=/bin/echo" "$CHECK_BASH" "$script" 2>&1)"; RC=$?
  check "$tag: a seam outside a sandbox and no --real: exit 64" equals "$RC" 64
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$seam=1" "$CHECK_BASH" -c "source '$script'; resolve_mode" 2>&1)"; RC=$?
  check "$tag: resolve_mode refuses the seam $seam outside a sandbox with 64" equals "$RC" 64
  check "$tag: resolve_mode names the seam" contains "$OUT" "$seam"
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" "$sandbox_var=$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S=0 STUB_DIR="$STUB" "$CHECK_BASH" "$script" --real 2>&1)"; RC=$?
  check "$tag: the real-mode flag inside a fully stubbed sandbox run: exit 64" equals "$RC" 64
  check "$tag: ... and nothing ran (no evidence file, launchctl not asked)" bash -c "! ls '$SB'/evidence/*.json '$SB'/evidence/pre-install-listing-* 2>/dev/null | grep -q . && [ ! -e '$STUB/launchctl.count' ]"
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" "$sandbox_var=$SB" "$CHECK_BASH" "$script" --bogus 2>&1)"; RC=$?
  check "$tag: an unknown argument: exit 64" equals "$RC" 64
  OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" "$sandbox_var=$SB" "$CHECK_BASH" "$script" 2>&1)"; RC=$?
  check "$tag: a sandbox without its seams: exit 64" equals "$RC" 64
  outside="$(mktemp -d "${TMPDIR:-/tmp}/postinstall-outside.XXXXXX")"
  mkdir -p "$outside/home"; : > "$outside/.postinstall-sandbox"; : > "$outside/.snapshot-sandbox"
  OUT="$(env -i HOME="$outside/home" PATH="/usr/bin:/bin" "$sandbox_var=$outside" "$CHECK_BASH" "$script" 2>&1)"; RC=$?
  check "$tag: a sandbox outside .build: exit 64" equals "$RC" 64
  rmdir "$outside/home" 2>/dev/null; rm -- "$outside/.postinstall-sandbox" "$outside/.snapshot-sandbox" 2>/dev/null; rmdir "$outside" 2>/dev/null
done
# direct-exec-check.sh: two gates (--real AND --run-a-copy), and nothing is read, copied or run when either is missing
dx_tree_before="$(cd "$EH" && find . | sort)"
dx_env() { env -i HOME="$EH" PATH="/usr/bin:/bin" "$@"; }
OUT="$(dx_env "$CHECK_BASH" "$DX" 2>&1)"; RC=$?
check "dx: no flag at all: exit 64" equals "$RC" 64
check "dx: ... says it needs --run-a-copy" contains "$OUT" "--run-a-copy"
check "dx: ... and says the copy shows a window if the launch guard regressed, so it is run only while the user watches" contains "$OUT" "run it only while the user watches"
OUT="$(dx_env "$CHECK_BASH" "$DX" --real 2>&1)"; RC=$?
check "dx: --real without --run-a-copy: exit 64" equals "$RC" 64
check "dx: ... says it runs a copy of the installed agent" contains "$OUT" "runs a copy of the installed agent"
OUT="$(dx_env "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: --run-a-copy without --real outside a sandbox: exit 64" equals "$RC" 64
check "dx: ... says --real is needed" contains "$OUT" "--real"
OUT="$(dx_env CLAWD_DIRECTEXEC_SAMPLER=/bin/echo "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a seam outside a sandbox and no --real: exit 64" equals "$RC" 64
for seam in CLAWD_DIRECTEXEC_SAMPLER CLAWD_DIRECTEXEC_LIMIT_MS CLAWD_DIRECTEXEC_MAX_GAP_MS; do
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$seam=1" "$CHECK_BASH" -c "source '$DX'; resolve_mode" 2>&1)"; RC=$?
  check "dx: resolve_mode refuses the seam $seam outside a sandbox with 64" equals "$RC" 64
  check "dx: ... and names it" contains "$OUT" "$seam"
done
OUT="$(dx_env "$CHECK_BASH" "$DX" --bogus --run-a-copy 2>&1)"; RC=$?
check "dx: an unknown argument: exit 64" equals "$RC" 64
check "dx: the usage text says that with a regressed launch guard the copy opens a window, and that the step is run ONLY while the user watches" bash -c "printf '%s' \"\$1\" | grep -q 'regressed' && printf '%s' \"\$1\" | grep -q 'opens a window' && printf '%s' \"\$1\" | grep -q 'ONLY while the user watches'" _ "$OUT"
check "dx: the usage text names the scratch HOME" contains "$OUT" "scratch HOME"
check "dx: nothing was written by any refused run (the fake HOME is unchanged, no evidence in the repo's .evidence)" bash -c "[ \"\$(cd '$EH' && find . | sort)\" = '$dx_tree_before' ] && ! find '$REPO/.evidence' -maxdepth 1 -name 'direct-exec-check*' -newer '$STAGE' 2>/dev/null | grep -q ."
dx_sandbox_env() { env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_DIRECTEXEC_SANDBOX="$SB" CLAWD_DIRECTEXEC_SAMPLER="$STUBS/sampler" CLAWD_DIRECTEXEC_LIMIT_MS=1000 CLAWD_DIRECTEXEC_MAX_GAP_MS=100 STUB_DIR="$STUB" "$@"; }
OUT="$(dx_sandbox_env "$CHECK_BASH" "$DX" --real --run-a-copy 2>&1)"; RC=$?
check "dx: --real inside a stubbed sandbox: exit 64" equals "$RC" 64
check "dx: ... and nothing ran (no evidence, no work directory, the stand-in agent never started)" bash -c "! ls '$SB'/evidence/direct-exec-check-*.json 2>/dev/null | grep -q . && [ ! -d '$SB/evidence/direct-exec-check-work' ] && [ ! -e '$STUB/agent.pids' ]"
OUT="$(dx_sandbox_env "$CHECK_BASH" "$DX" 2>&1)"; RC=$?
check "dx: a sandbox run without --run-a-copy: exit 64 (the gate is not a mode of the sandbox)" equals "$RC" 64
OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_DIRECTEXEC_SANDBOX="$SB" "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a sandbox without its seams: exit 64" equals "$RC" 64
OUT="$(dx_sandbox_env CLAWD_DIRECTEXEC_LIMIT_MS=abc "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a non-numeric limit is refused (64)" equals "$RC" 64
OUT="$(dx_sandbox_env CLAWD_DIRECTEXEC_MAX_GAP_MS=1.5 "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a non-numeric gap is refused (64)" equals "$RC" 64
rm -- "$SB/.directexec-sandbox"
OUT="$(dx_sandbox_env "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a sandbox without its marker file: exit 64" equals "$RC" 64
: > "$SB/.directexec-sandbox"
dx_outside="$(mktemp -d "${TMPDIR:-/tmp}/directexec-outside.XXXXXX")"
mkdir -p "$dx_outside/home"; : > "$dx_outside/.directexec-sandbox"
OUT="$(env -i HOME="$dx_outside/home" PATH="/usr/bin:/bin" CLAWD_DIRECTEXEC_SANDBOX="$dx_outside" CLAWD_DIRECTEXEC_SAMPLER="$STUBS/sampler" CLAWD_DIRECTEXEC_LIMIT_MS=1000 CLAWD_DIRECTEXEC_MAX_GAP_MS=100 "$CHECK_BASH" "$DX" --run-a-copy 2>&1)"; RC=$?
check "dx: a sandbox outside .build: exit 64" equals "$RC" 64
rmdir "$dx_outside/home" 2>/dev/null; rm -- "$dx_outside/.directexec-sandbox" 2>/dev/null; rmdir "$dx_outside" 2>/dev/null
# the copy is never made inside the install (a function-level test: the work directory is forced into the root)
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" -c "source '$DX'; ROOT='$STAGE/fake-root'; WORK='$STAGE/fake-root/work'; AGENT=/bin/echo; make_copy; echo \"rc=\$? notruns=[\$NOTRUNS]\"" 2>&1)"
check "dx: make_copy refuses a scratch directory inside the install (rc 1, direct-exec-failed-to-start)" bash -c "printf '%s' \"\$1\" | grep -q 'rc=1' && printf '%s' \"\$1\" | grep -q 'direct-exec-failed-to-start'" _ "$OUT"
check "dx: ... and made nothing there" test ! -e "$STAGE/fake-root"
# the copy's own HOME is proved isolated before anything runs (function-level: make_home on forced paths; nothing is ever run here)
iso_case() { # HOME ROOT WORK -> "rc=<rc> home=[<COPY_HOME>] notruns=[<reasons>]"
  env -i HOME="$1" PATH="/usr/bin:/bin" "$CHECK_BASH" -c "source '$DX'; ROOT='$2'; WORK='$3'; make_home; echo \"rc=\$? home=[\$COPY_HOME] notruns=[\$NOTRUNS]\"" 2>&1
}
mkdir -p "$STAGE/iso-ok/home" "$STAGE/iso-ok/root" "$STAGE/iso-ok/work" "$STAGE/iso-a/work" "$STAGE/iso-b/root/work" "$STAGE/iso-c/work" "$STAGE/iso-e/work" "$STAGE/iso-e/h"
OUT="$(iso_case "$STAGE/iso-ok/home" "$STAGE/iso-ok/root" "$STAGE/iso-ok/work")"
check "dx: make_home accepts a new directory that is not the real HOME and not inside or around the install (rc 0)" bash -c "printf '%s' \"\$1\" | grep -q '^rc=0 home=\[$STAGE/iso-ok/work/home\] notruns=\[\]\$'" _ "$OUT"
check "dx: ... and that directory is new and empty" bash -c "[ -d '$STAGE/iso-ok/work/home' ] && [ ! -L '$STAGE/iso-ok/work/home' ] && [ -z \"\$(ls -A '$STAGE/iso-ok/work/home')\" ]"
OUT="$(iso_case "$STAGE/iso-a/work/home" "$STAGE/iso-a/root" "$STAGE/iso-a/work")"
check "dx: make_home refuses a scratch directory that is the real HOME (rc 1, direct-exec-failed-to-start, says so)" bash -c "printf '%s' \"\$1\" | grep -q 'rc=1' && printf '%s' \"\$1\" | grep -q 'direct-exec-failed-to-start' && printf '%s' \"\$1\" | grep -q 'is the real HOME' && printf '%s' \"\$1\" | grep -q 'home=\[\]'" _ "$OUT"
OUT="$(iso_case "$STAGE/iso-b/h" "$STAGE/iso-b/root" "$STAGE/iso-b/root/work")"
check "dx: make_home refuses a scratch directory inside the install (rc 1, says so)" bash -c "printf '%s' \"\$1\" | grep -q 'rc=1' && printf '%s' \"\$1\" | grep -q 'lies inside the install'" _ "$OUT"
OUT="$(iso_case "$STAGE/iso-c/h" "$STAGE/iso-c/work/home/Library/Application Support/clawd-pet" "$STAGE/iso-c/work")"
check "dx: make_home refuses a scratch directory that contains the install, which would be reachable through HOME (rc 1, says so)" bash -c "printf '%s' \"\$1\" | grep -q 'rc=1' && printf '%s' \"\$1\" | grep -q 'reachable through HOME'" _ "$OUT"
mkdir -p "$STAGE/iso-e/real"; ln -s "$STAGE/iso-e/real" "$STAGE/iso-e/work/home"
OUT="$(iso_case "$STAGE/iso-e/h" "$STAGE/iso-e/root" "$STAGE/iso-e/work")"
check "dx: make_home refuses a scratch directory that already exists, even a symbolic link to a real directory (rc 1, says so)" bash -c "printf '%s' \"\$1\" | grep -q 'rc=1' && printf '%s' \"\$1\" | grep -q 'cannot make the scratch HOME'" _ "$OUT"

# post-install-settings-step.sh: two gates (--real AND --change-a-setting)
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$SS" 2>&1)"; RC=$?
check "ss: no flag at all: exit 64" equals "$RC" 64
check "ss: ... says it needs --change-a-setting" contains "$OUT" "--change-a-setting"
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$SS" --real 2>&1)"; RC=$?
check "ss: --real without --change-a-setting: exit 64" equals "$RC" 64
check "ss: ... says it changes a setting" contains "$OUT" "changes a setting"
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$SS" --change-a-setting 2>&1)"; RC=$?
check "ss: --change-a-setting without --real outside a sandbox: exit 64" equals "$RC" 64
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" CLAWD_SETTINGS_CLI=/bin/echo "$CHECK_BASH" "$SS" --change-a-setting 2>&1)"; RC=$?
check "ss: a seam outside a sandbox: exit 64" equals "$RC" 64
for seam in CLAWD_LAUNCHCTL CLAWD_SETTINGS_CLI; do
  OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$seam=1" "$CHECK_BASH" -c "source '$SS'; resolve_mode" 2>&1)"; RC=$?
  check "ss: resolve_mode refuses the seam $seam outside a sandbox with 64" equals "$RC" 64
  check "ss: ... and names it" contains "$OUT" "$seam"
done
OUT="$(env -i HOME="$EH" PATH="/usr/bin:/bin" "$CHECK_BASH" "$SS" --bogus 2>&1)"; RC=$?
check "ss: an unknown argument: exit 64" equals "$RC" 64
check "ss: nothing was written by any refused run (the fake HOME is unchanged)" test "$(cd "$EH" && find . | sort)" = "$dx_tree_before"
ss_sandbox_env() { env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_SETTINGS_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_SETTINGS_CLI="$STUBS/settings-cli" STUB_DIR="$STUB" "$@"; }
OUT="$(ss_sandbox_env "$CHECK_BASH" "$SS" --real --change-a-setting 2>&1)"; RC=$?
check "ss: --real inside a stubbed sandbox: exit 64, and the CLI was not run" bash -c "[ '$RC' -eq 64 ] && [ ! -e '$STUB/cli.calls' ]"
OUT="$(ss_sandbox_env "$CHECK_BASH" "$SS" 2>&1)"; RC=$?
check "ss: a sandbox run without --change-a-setting: exit 64" equals "$RC" 64
OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_SETTINGS_SANDBOX="$SB" "$CHECK_BASH" "$SS" --change-a-setting 2>&1)"; RC=$?
check "ss: a sandbox without its seams: exit 64" equals "$RC" 64

rm -- "$SB/.postinstall-sandbox"
OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_POSTINSTALL_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S=0 "$CHECK_BASH" "$POST" 2>&1)"; RC=$?
check "post: a sandbox without its marker file: exit 64" equals "$RC" 64
OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_POSTINSTALL_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S=abc "$CHECK_BASH" "$POST" 2>&1)"; RC=$?
: > "$SB/.postinstall-sandbox"
OUT="$(env -i HOME="$SB/home" PATH="/usr/bin:/bin" CLAWD_POSTINSTALL_SANDBOX="$SB" CLAWD_LAUNCHCTL="$STUBS/launchctl" CLAWD_POSTINSTALL_SAMPLER="$STUBS/sampler" CLAWD_POSTINSTALL_LSAPPINFO="$STUBS/lsappinfo" CLAWD_POSTINSTALL_SETTLE_S=abc "$CHECK_BASH" "$POST" 2>&1)"; RC=$?
check "post: a non-numeric settle time is refused (64)" equals "$RC" 64
check "post: ... and it ran nothing (no evidence file)" bash -c "! ls '$SB'/evidence/post-install-check-*.json"

# ---- the --real lint: no test file passes --real to a check script --------------------------------------------------------------------
for f in "$REPO"/Tests/*.test.sh; do
  [ "$(basename "$f")" = "$(basename "$0")" ] && continue
  check "no test invokes a check script with --real ($(basename "$f"))" lint_no_real_flag "$f"
done
check "this file passes the --real lint" lint_no_real_flag "$0"

# ---- read-only observers ---------------------------------------------------------------------------------------------------------------
grep -vE '^[[:space:]]*#' "$POST" > "$STAGE/post.code"
grep -vE '^[[:space:]]*#' "$SNAP" > "$STAGE/snap.code"
code_lacks() { ! grep -E "$1" "$2"; }                 # PATTERN FILE: no line matches
code_count() { [ "$(grep -cE "$1" "$3")" = "$2" ]; }   # PATTERN COUNT FILE: exactly COUNT lines match
check "post: launchctl is called in one place, with list" code_count '"\$LAUNCHCTL" ' 1 "$STAGE/post.code"
check "post: ... and that call is list" code_count '"\$LAUNCHCTL" list ' 1 "$STAGE/post.code"
check "post: launchctl is never given a changing verb" code_lacks '(\$LAUNCHCTL|/bin/launchctl)"? +(bootstrap|bootout|kickstart|load|unload|start|stop|remove|enable|disable|kill|submit)' "$STAGE/post.code"
check "snap: launchctl is called in one place, with list" code_count '"\$LAUNCHCTL" list ' 1 "$STAGE/snap.code"
check "post: STRICTLY READ-ONLY: no line runs the installed agent or the installed launcher" code_lacks '(^|;|&&|\|\||\$\()[[:space:]]*"\$(AGENT|LAUNCHER)"' "$STAGE/post.code"
check "post: STRICTLY READ-ONLY: it starts no background job of any kind" code_lacks '[^&]&[[:space:]]*$|[^&>]&[[:space:]]+[a-z$"]|\bnohup\b|\bdisown\b' "$STAGE/post.code"
check "post: STRICTLY READ-ONLY: it never signals (no kill, no ck_kill_job)" code_lacks '(^|[^a-z_])kill +|ck_kill_job' "$STAGE/post.code"
check "post: STRICTLY READ-ONLY: it copies, moves, removes, links and touches nothing" code_lacks '(^|[;&|( ])(cp|mv|rm|chmod|ln|touch|tee|dd|install) ' "$STAGE/post.code"
check "post: STRICTLY READ-ONLY: it makes directories only for its own evidence (EVID and WORK)" code_lacks 'mkdir[^|;]*(\$ROOT|\$HOME|\$PLIST|\$MANIFEST|\$LAUNCHER)' "$STAGE/post.code"
check "post: STRICTLY READ-ONLY: no redirection writes into the install" code_lacks '>>?[[:space:]]*"?\$(ROOT|MANIFEST|PLIST|LAUNCHER|HOME)' "$STAGE/post.code"
check "post: it never uses open, osascript, an event API or a .app" code_lacks '(^|[;&|( ])open +|/usr/bin/open|osascript|cliclick|screencapture|CGEvent|AXIsProcessTrusted|\.app[/"]' "$STAGE/post.code"
check "post: it never calls kill itself; it signals only through ck_kill_job (the job table decides)" code_lacks '(^|[^a-z_])kill +' "$STAGE/post.code"
grep -vE '^[[:space:]]*#' "$DX" > "$STAGE/dx.code"
check "dx: it never runs the installed agent: the only program it starts is the copy, through the observer" code_count '"\$OBSERVER" "\$SAMPLER" "\$LIMIT_MS" "\$COPY"' 1 "$STAGE/dx.code"
check "dx: ... and no line runs \$AGENT" code_lacks '^[[:space:]]*"\$AGENT"|[;&|(][[:space:]]*"\$AGENT"' "$STAGE/dx.code"
check "dx: it never touches launchd" code_lacks 'launchctl|LAUNCHCTL' "$STAGE/dx.code"
check "dx: it never uses open, osascript, an event API or a .app" code_lacks '(^|[;&|( ])open +|/usr/bin/open|osascript|cliclick|screencapture|CGEvent|AXIsProcessTrusted|\.app[/"]' "$STAGE/dx.code"
check "dx: it signals only through ck_kill_job, for the observer it started" code_lacks '(^|[^a-z_])kill +' "$STAGE/dx.code"
check "dx: ... and uses ck_kill_job in one place" code_count 'ck_kill_job' 1 "$STAGE/dx.code"
grep -vE '^[[:space:]]*#' "$REPO/scripts/direct-exec-observe.pl" > "$STAGE/observe.code"
check "dx: the observer signals only the child it forked (every kill names \$pid)" bash -c "[ \"\$(grep -c 'kill ' '$STAGE/observe.code')\" -ge 1 ] && ! grep 'kill ' '$STAGE/observe.code' | grep -qv '\$pid'"
check "dx: the observer runs nothing but the program it was given and the lister (two exec sites)" bash -c "[ \"\$(grep -cE 'exec \\{|open\\(my \\\$lister' '$STAGE/observe.code')\" = 2 ]"
grep -vE '^[[:space:]]*#' "$SS" > "$STAGE/ss.code"
check "ss: the only program it runs is the CLI, and only as walk off / walk on" code_count '"\$CLI" walk ' 2 "$STAGE/ss.code"
check "ss: ... plus the launchctl list look-ups, and nothing else" bash -c "[ \"\$(grep -cE '\"\\\$CLI\"' '$STAGE/ss.code')\" -ge 2 ] && grep -c '\"\\\$LAUNCHCTL\" list ' '$STAGE/ss.code' | grep -qx 1 && ! grep -E '\\\$LAUNCHCTL\"? +(bootstrap|bootout|kickstart|load|unload|start|stop|remove|enable|disable|kill|submit)' '$STAGE/ss.code'"
check "ss: it never writes the agent's files itself (control.json, status.json and agent.log are only read)" code_lacks '>>?[[:space:]]*"?\$(CONTROL|STATUS|LOG|ROOT)|plutil -(replace|insert|remove)|(cp|mv|rm|touch|tee) [^|;]*\$(CONTROL|STATUS|LOG)' "$STAGE/ss.code"
check "ss: it never uses open, osascript, an event API or a .app, and never signals" code_lacks '(^|[;&|( ])open +|/usr/bin/open|osascript|cliclick|screencapture|CGEvent|AXIsProcessTrusted|\.app[/"]|(^|[^a-z_])kill +' "$STAGE/ss.code"
check "snap: it never signals, looks up processes, opens or launches anything" code_lacks '(^|[^a-z_])(kill|pkill|pgrep|killall)( |$)|(^|[;&|( ])open +|/usr/bin/open|osascript' "$STAGE/snap.code"
check "snap: it runs no other repo script and not the CLI (it sources check-common.sh and nothing else)" code_lacks '\$REPO/(bin/|scripts/(install|uninstall|attended|post|live))' "$STAGE/snap.code"
check "snap: it removes only its own temporary comparison files, one command per outcome (no rm -r)" code_lacks 'rm +-[a-zA-Z]*[rR]' "$STAGE/snap.code"
check "snap: ... and those are two rm commands" code_count 'rm -- ' 2 "$STAGE/snap.code"

RES="$RESDIR/zz-final"; : > "$RES"
check "no stand-in agent or sampler is left running from this test's stage" bash -c "! ps -axo command= | grep -F '$STAGE' | grep -v grep | grep -qE 'sampler|clawd-pet-agent|post-install-check'"

tally post-install-check.test
