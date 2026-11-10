#!/bin/bash
# Plants one violation per rule in a temporary COPY of Sources (never in the tree) and requires the linter to
# exit non-zero and name that rule. Also requires the clean copy to pass and benign look-alikes not to trip it.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/scripts/lint-banned.sh"
STAGE="$REPO/.build/lint-test/$(date +%s)-$$"
mkdir -p "$STAGE" || { echo "cannot create $STAGE"; exit 2; }

pass=0; fail=0
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi; }

fresh_copy() { # name -> path of a copy that holds only Sources
  d="$STAGE/$1"; mkdir -p "$d" && cp -R "$REPO/Sources" "$d/Sources" && echo "$d"
}

# rule id -> Swift snippet planted as Sources/ClawdCore/Planted.swift
snippet() {
  case "$1" in
    kill-call) echo 'import Darwin
func planted(pid: Int32) { _ = kill(pid, 9) }' ;;
    terminate-call) echo 'import AppKit
func planted(app: NSRunningApplication) { _ = app.forceTerminate() }' ;;
    apple-events) echo 'import Foundation
let planted = NSAppleScript(source: "tell application \"Aqua\" to quit")' ;;
    socket-call) echo 'import Darwin
let planted = socket(AF_INET, SOCK_STREAM, 0)' ;;
    network-api) echo 'import Foundation
let planted = URLSession.shared' ;;
    activate-call) echo 'import AppKit
func planted() { NSApp.activate(ignoringOtherApps: true) }' ;;
    unhide-call) echo 'import AppKit
func planted() { NSApp.unhide(nil) }' ;;
    make-main) echo 'import AppKit
func planted(w: NSWindow) { w.makeKeyAndOrderFront(nil) }' ;;
    make-key) echo 'import AppKit
func planted(w: NSWindow) { w.makeKey() }' ;;
    pty-fork) echo 'import Darwin
func planted() { var m: Int32 = 0; _ = forkpty(&m, nil, nil, nil) }' ;;
    swiftterm-import) echo 'import SwiftTerm
let planted = 1' ;;
    swiftui-host) echo 'import AppKit
import SwiftUI
func planted() { _ = NSHostingView(rootView: Text("x")) }' ;;
    order-front) echo 'import AppKit
func planted(w: NSWindow) { w.orderFront(nil) }' ;;
    regular-policy) echo 'import AppKit
func planted() { NSApp.setActivationPolicy(.regular) }' ;;
    menus-and-modals) echo 'import AppKit
func planted() { NSAlert().runModal() }' ;;
    open-panel) echo 'import AppKit
func planted() -> NSOpenPanel { NSOpenPanel() }' ;;
    workspace-open) echo 'import AppKit
func planted(u: URL) { NSWorkspace.shared.open(u) }' ;;
    permission-prompts) echo 'import ApplicationServices
func planted() { _ = AXIsProcessTrustedWithOptions(nil) }' ;;
    event-injection) echo 'import CoreGraphics
func planted(e: CGEvent) { CGEventPost(.cghidEventTap, e) }' ;;
    key-or-tap-monitoring) echo 'import AppKit
func planted() { _ = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { _ in }) }' ;;
    audio-mutating-api) echo 'import CoreAudio
func planted(d: AudioDeviceID, p: AudioDeviceIOProcID) { _ = AudioDeviceStart(d, p) }' ;;
    microphone-usage-key) echo 'let planted = "NSMicrophoneUsageDescription"' ;;
    status-item) echo 'import AppKit
func planted() { _ = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }' ;;
    focus-following-screen) echo 'import AppKit
func planted() -> NSScreen? { NSScreen.main }' ;;
    filemanager-write) echo 'import Foundation
func planted() { try? FileManager.default.removeItem(atPath: "/tmp/x") }' ;;
    data-or-string-write) echo 'import Foundation
func planted() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }' ;;
    stdio-write) echo 'import Darwin
func planted() { _ = fopen("/tmp/x", "w") }' ;;
    file-handle-write) echo 'import Foundation
func planted() { _ = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/x")) }' ;;
    posix-mutation) echo 'import Darwin
func planted() { _ = unlink("/tmp/x") }' ;;
    open-call) echo 'import Darwin
func planted() { _ = Darwin.open("/tmp/x", O_RDONLY) }' ;;
    aqua-path-literal) echo 'let planted = "/Library/Logs/Aqua Voice/main.log"' ;;
    *) return 1 ;;
  esac
}

# 1. the real tree and a clean copy pass
bash "$LINT" >/dev/null 2>&1; check "the real tree passes" test "$?" -eq 0
clean="$(fresh_copy clean)"; bash "$LINT" "$clean" >/dev/null 2>&1; check "a clean copy passes" test "$?" -eq 0

# 2. every rule has a planted violation that the linter rejects by that rule's name
rules="$(/usr/bin/python3 "$REPO/scripts/lint_banned.py" --list-rules)"
check "the linter lists its rules" test -n "$rules"
for rule in $rules; do
  [ "$rule" = "readonly-wrapper-incomplete" ] && continue
  planted="$(snippet "$rule")"
  check "rule $rule has a planted violation" test -n "$planted"
  copy="$(fresh_copy "rule-$rule")"
  printf '%s\n' "$planted" > "$copy/Sources/ClawdCore/Planted.swift"
  bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
  check "planted $rule makes the linter exit non-zero" test "$rc" -ne 0
  check "planted $rule is reported under its own rule id" grep -qF "[$rule]" "$copy/lint.out"
done

# 2b. makeKey is allowed in the chat panel's own file and nowhere else
copy="$(fresh_copy chatpanel-key)"
cp "$REPO/Sources/ClawdDesktop/ChatPanel.swift" "$copy/Sources/ClawdDesktop/ChatPanel.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "makeKey in ChatPanel.swift alone is allowed" test "$?" -eq 0

# 2b'. activate( is allowed in the chat activation file alone (Sprint 3e item 8)
copy="$(fresh_copy chat-activation)"
printf '%s\n' 'import AppKit
func planted() { NSApp.activate(ignoringOtherApps: true) }' > "$copy/Sources/ClawdDesktop/ChatActivation.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "activate( in ChatActivation.swift alone is allowed" test "$?" -eq 0
copy="$(fresh_copy chat-activation-elsewhere)"
printf '%s\n' 'import AppKit
func planted() { NSApp.activate(ignoringOtherApps: true) }' > "$copy/Sources/ClawdDesktop/ChatActivationElsewhere.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "activate( in any other file makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under activate-call" grep -qF "[activate-call]" "$copy/lint.out"

# 2b''. the open panel may be named in the chat's picker file alone, and even there it is never run modally
copy="$(fresh_copy attach-picker)"
printf '%s\n' 'import AppKit
func planted() -> NSOpenPanel { NSOpenPanel() }' > "$copy/Sources/ClawdDesktop/ChatAttachPicker.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "NSOpenPanel in ChatAttachPicker.swift alone is allowed" test "$?" -eq 0
copy="$(fresh_copy attach-picker-elsewhere)"
printf '%s\n' 'import AppKit
func planted() -> NSOpenPanel { NSOpenPanel() }' > "$copy/Sources/ClawdDesktop/ChatAttachElsewhere.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "NSOpenPanel in any other file makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under open-panel" grep -qF "[open-panel]" "$copy/lint.out"
copy="$(fresh_copy attach-picker-modal)"
printf '%s\n' 'import AppKit
func planted(panel: NSOpenPanel) { _ = panel.runModal() }' > "$copy/Sources/ClawdDesktop/ChatAttachPicker.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "runModal( inside ChatAttachPicker.swift makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under menus-and-modals" grep -qF "[menus-and-modals]" "$copy/lint.out"

# 2b-status. the system status bar may be named in the status menu file alone
copy="$(fresh_copy status-menu-file)"
printf '%s\n' 'import AppKit
func planted() { _ = NSStatusBar.system }' > "$copy/Sources/ClawdDesktop/StatusMenu.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "NSStatusBar in StatusMenu.swift alone is allowed" test "$?" -eq 0
copy="$(fresh_copy status-menu-elsewhere)"
printf '%s\n' 'import AppKit
func planted() { _ = NSStatusBar.system }' > "$copy/Sources/ClawdDesktop/StatusElsewhere.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "NSStatusBar in any other file makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under status-item" grep -qF "[status-item]" "$copy/lint.out"

# 2b-settings. the Settings window's file may make a window key and its folder picker's file may name the open panel; no other file may
copy="$(fresh_copy settings-window-file)"
printf '%s\n' 'import AppKit
func planted(w: NSWindow) { w.makeKey() }' > "$copy/Sources/ClawdDesktop/SettingsWindow.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "makeKey in SettingsWindow.swift alone is allowed" test "$?" -eq 0
copy="$(fresh_copy settings-window-elsewhere)"
printf '%s\n' 'import AppKit
func planted(w: NSWindow) { w.makeKey() }' > "$copy/Sources/ClawdDesktop/SettingsController.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "makeKey in any other Settings file makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under make-key" grep -qF "[make-key]" "$copy/lint.out"
copy="$(fresh_copy settings-picker-file)"
printf '%s\n' 'import AppKit
func planted() -> NSOpenPanel { NSOpenPanel() }' > "$copy/Sources/ClawdDesktop/SettingsFolderPicker.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "NSOpenPanel in SettingsFolderPicker.swift alone is allowed" test "$?" -eq 0
copy="$(fresh_copy settings-picker-elsewhere)"
printf '%s\n' 'import AppKit
func planted() -> NSOpenPanel { NSOpenPanel() }' > "$copy/Sources/ClawdDesktop/SettingsSections.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "NSOpenPanel in any other Settings file makes the linter exit non-zero" test "$rc" -ne 0
check "and is reported under open-panel" grep -qF "[open-panel]" "$copy/lint.out"

# 2c. SwiftTerm may be imported by the terminal view's file alone; each name of the PTY helpers is flagged; openDefaultLink is flagged
copy="$(fresh_copy terminal-view-import)"
printf '%s\n' 'import AppKit
import SwiftTerm
final class Planted {}' > "$copy/Sources/ClawdDesktop/ChatTerminalView.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "import SwiftTerm in ChatTerminalView.swift alone is allowed" test "$?" -eq 0
for name in LocalProcess PseudoTerminalHelpers; do
  copy="$(fresh_copy "pty-$name")"
  printf '%s\n' "let planted = $name.self" > "$copy/Sources/ClawdCore/Planted.swift"
  bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
  check "planted $name makes the linter exit non-zero" test "$rc" -ne 0
  check "planted $name is reported under pty-fork" grep -qF "[pty-fork]" "$copy/lint.out"
done
copy="$(fresh_copy open-default-link)"
printf '%s\n' 'import AppKit
func planted(view: AnyObject, link: String) { _ = TerminalView.openDefaultLink(link) }' > "$copy/Sources/ClawdCore/Planted.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "planted openDefaultLink makes the linter exit non-zero" test "$rc" -ne 0
check "planted openDefaultLink is reported under workspace-open" grep -qF "[workspace-open]" "$copy/lint.out"

# 2c'. the terminal process file may spawn, signal, open and write (like ChatProcess.swift); the same calls anywhere else are flagged
copy="$(fresh_copy term-process)"
printf '%s\n' 'import Darwin
func planted(pid: Int32, fd: Int32) { _ = kill(pid, 1); _ = Darwin.open("/dev/null", 0); var byte: UInt8 = 0; _ = write(fd, &byte, 1) }' > "$copy/Sources/ClawdCore/TermProcess.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "kill, open and write in TermProcess.swift alone are allowed" test "$?" -eq 0
copy="$(fresh_copy term-process-elsewhere)"
printf '%s\n' 'import Darwin
func planted(pid: Int32, fd: Int32) { _ = kill(pid, 1); _ = Darwin.open("/dev/null", 0); var byte: UInt8 = 0; _ = write(fd, &byte, 1) }' > "$copy/Sources/ClawdCore/TermElsewhere.swift"
bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
check "the same calls in another file make the linter exit non-zero" test "$rc" -ne 0
for rule in kill-call posix-mutation open-call; do check "and are reported under $rule" grep -qF "[$rule]" "$copy/lint.out"; done

# 3. the ReadOnlyFile wrapper must keep rejecting every write flag
for flag in O_ACCMODE O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND; do
  copy="$(fresh_copy "wrapper-$flag")"
  sed "s/$flag/O_RDONLY/g" "$REPO/Sources/ClawdCore/ReadOnlyFile.swift" > "$copy/Sources/ClawdCore/ReadOnlyFile.swift"
  bash "$LINT" "$copy" > "$copy/lint.out" 2>&1; rc=$?
  check "dropping $flag from the ReadOnlyFile wrapper fails the lint" test "$rc" -ne 0
  check "dropping $flag is reported as readonly-wrapper-incomplete" grep -qF "readonly-wrapper-incomplete" "$copy/lint.out"
done
copy="$(fresh_copy wrapper-missing)"; rm "$copy/Sources/ClawdCore/ReadOnlyFile.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "a missing ReadOnlyFile wrapper fails the lint" test "$?" -ne 0

# 4. look-alikes that must NOT trip it: comments, deactivate, orderFrontRegardless, canBecomeKey, stdout writes
copy="$(fresh_copy benign)"
printf '%s\n' 'import AppKit
// kill(pid, 9) and NSApp.activate(ignoringOtherApps: true) are only mentioned in this comment
/* socket( connect( URLSession */
func benign(panel: NSPanel, app: NSApplication) {
    app.deactivate()
    panel.orderFrontRegardless()
    let key = panel.canBecomeKey
    FileHandle.standardOutput.write(Data("ok".utf8))
    _ = key
}' > "$copy/Sources/ClawdCore/Benign.swift"
bash "$LINT" "$copy" >/dev/null 2>&1; check "comments and look-alikes do not trip the lint" test "$?" -eq 0

# 5. usage errors are exit 2, not a silent pass
bash "$LINT" "$STAGE/does-not-exist" >/dev/null 2>&1; check "a missing root is a usage error, not a pass" test "$?" -eq 2

echo "lint-banned.test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
