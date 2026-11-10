#!/usr/bin/python3
"""Source lint for the production tree (spec section 6, done-bar 2a).

Scans Sources/ only: tests, fixtures, scripts and art may contain intentionally rejected inputs.
Usage: lint_banned.py ROOT        scan ROOT/Sources
       lint_banned.py --list-rules  print every rule id, one per line
Exit 0 = clean, 1 = violations, 2 = usage or read failure.
"""
from pathlib import Path
import re
import sys

OWN_STATE = "Sources/ClawdCore/OwnState.swift"
CHAT_PANEL = "Sources/ClawdDesktop/ChatPanel.swift"
READ_ONLY = "Sources/ClawdCore/ReadOnlyFile.swift"
# The one file that may import SwiftTerm (the terminal view and its delegate).
TERMINAL_VIEW = "Sources/ClawdDesktop/ChatTerminalView.swift"
# The one file that may call `activate(`: the real values of the chat's focus seams.
CHAT_ACTIVATION = "Sources/ClawdDesktop/ChatActivation.swift"
# The one file that opens a link in the default browser (the web chat's Cmd-click on an http(s) link).
CHAT_WEB_OPEN = "Sources/ClawdDesktop/ChatWebOpen.swift"
# The one file that may name the system's open panel (the chat's "+" picker, shown with begin, never modal).
CHAT_ATTACH_PICKER = "Sources/ClawdDesktop/ChatAttachPicker.swift"
# The Settings window's own make-key call, and its working-folder picker (also an open panel, shown with begin, never modal).
SETTINGS_WINDOW = "Sources/ClawdDesktop/SettingsWindow.swift"
SETTINGS_FOLDER_PICKER = "Sources/ClawdDesktop/SettingsFolderPicker.swift"
# The one file that names the system's status bar (the menu bar icon and its menu).
STATUS_MENU = "Sources/ClawdDesktop/StatusMenu.swift"
# The chat bridge signals its own child and writes to its pipes; nothing else in Sources may.
# The C half is the SIGTERM handler's one write to the quit pipe.
TERM_PROCESS = "Sources/ClawdCore/TermProcess.swift"
CHAT_PROCESS = {"Sources/ClawdCore/ChatProcess.swift", "Sources/ClawdProcess/quit.c", TERM_PROCESS}
AQUA_PATH_HOMES = {"Sources/ClawdCore/Configuration.swift", OWN_STATE}

# (id, regex, files exempt from the rule)
RULES = [
    ("kill-call", r"\bkill\s*\(", CHAT_PROCESS),
    ("terminate-call", r"\b(?:terminate|forceTerminate)\s*\(", set()),
    ("apple-events", r"\b(?:NSAppleScript|NSAppleEventDescriptor|AESend|AESendMessage|AEDeterminePermissionToAutomateTarget)\b", set()),
    ("socket-call", r"\b(?:socket|connect)\s*\(", set()),
    ("network-api", r"\b(?:URLSession|URLRequest|NWConnection|NWListener|CFSocket|CFStream|NSStream)\b|\bimport\s+Network\b|Network\.framework", set()),
    ("activate-call", r"\bactivate\s*\(", {CHAT_ACTIVATION}),
    ("unhide-call", r"\bunhide\s*\(", set()),
    ("make-main", r"\b(?:makeKeyAndOrderFront|makeMain|makeMainWindow)\b", set()),
    # Only the chat panel's own open call makes a window key (spec F1.5); the Gate A spike lives outside Sources.
    ("make-key", r"\b(?:makeKey|makeKeyWindow)\b", {CHAT_PANEL, SETTINGS_WINDOW}),
    # The terminal is drawn by SwiftTerm's view; the process behind it is Clawd's own posix_spawn on a PTY, never SwiftTerm's fork helpers.
    ("pty-fork", r"\b(?:forkpty|LocalProcess|PseudoTerminalHelpers)\b", set()),
    ("swiftterm-import", r"\bimport\s+SwiftTerm\b", {TERMINAL_VIEW}),
    ("swiftui-host", r"\bimport\s+SwiftUI\b|\bNSHosting(?:View|Controller)\b", set()),
    ("order-front", r"\borderFront\s*\(", set()),
    ("regular-policy", r"setActivationPolicy\s*\(\s*\.regular", set()),
    ("menus-and-modals", r"\b(?:popUpContextMenu|popUp|runModal|beginSheetModal)\s*\(|\b(?:NSAlert|NSSavePanel)\b", set()),
    ("open-panel", r"\bNSOpenPanel\b", {CHAT_ATTACH_PICKER, SETTINGS_FOLDER_PICKER}),
    # openDefaultLink is SwiftTerm's own link opener (it ends in NSWorkspace.shared.open): Clawd's delegate replaces it and never calls it.
    ("workspace-open", r"NSWorkspace\.shared\.(?:open|launchApplication|openApplication)|\bopenDefaultLink\b", {CHAT_WEB_OPEN}),
    ("permission-prompts", r"\b(?:requestAuthorization|AXIsProcessTrustedWithOptions|CGRequestScreenCaptureAccess|CGRequestPostEventAccess)\b", set()),
    ("event-injection", r"\b(?:CGEventPost|CGEventPostToPid|CGWarpMouseCursorPosition|CGEventCreateMouseEvent)\b", set()),
    ("key-or-tap-monitoring", r"\.keyDown\b|\.keyUp\b|\.flagsChanged\b|CGEventTapCreate|CGEvent\.tapCreate|CGRequestListenEventAccess|IOHIDRequestAccess", set()),
    ("audio-mutating-api", r"\b(?:AudioHardwareCreateAggregateDevice|AudioHardwareCreateProcessTap|AudioObjectSetPropertyData|AVAudioEngine|AVCaptureDevice|AudioDeviceCreateIOProcID|AudioDeviceStart|AudioQueueNewInput|AudioUnitInitialize)\b", set()),
    ("microphone-usage-key", r"NSMicrophoneUsageDescription", set()),
    ("filemanager-write", r"\b(?:createFile|removeItem|moveItem|copyItem|createDirectory)\s*\(", {OWN_STATE}),
    ("data-or-string-write", r"\.write\s*\(\s*to\s*:", {OWN_STATE}),
    ("stdio-write", r"\b(?:fopen|freopen|creat)\s*\(", {OWN_STATE}),
    ("file-handle-write", r"\bFileHandle\s*\(\s*for(?:Writing|Updating)|\b(?:OutputStream|FileOutputStream)\b", {OWN_STATE}),
    ("posix-mutation", r"Darwin\.(?:write|unlink|rename|truncate|ftruncate|mkdir|rmdir)\s*\(|(?<![\w.])(?:write|unlink|rename|truncate|ftruncate|mkdir|rmdir)\s*\(", {OWN_STATE} | CHAT_PROCESS),
    ("open-call", r"\bopen\s*\(", {READ_ONLY, OWN_STATE, TERM_PROCESS, CHAT_WEB_OPEN}),
    # The screen with keyboard focus moves with every click on another display; the pet stands on its saved display or the primary one.
    # The menu bar icon is one item, owned by the status menu file; nothing else may make or remove a status item.
    ("status-item", r"\bNSStatusBar\b", {STATUS_MENU}),
    ("focus-following-screen", r"\bNSScreen\s*\.\s*main\b|\b(?:keyWindow|mainWindow)\s*[!?]?\s*\.\s*screen\b", set()),
]
RULE_IDS = [rule[0] for rule in RULES] + ["aqua-path-literal", "readonly-wrapper-incomplete"]
REJECTED_FLAGS = ["O_ACCMODE", "O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND"]


def strip_comments(text):
    """Blanks comments but keeps line numbers and string contents (strings are scanned too)."""
    out = []
    for line in text.split("\n"):
        i, in_string, kept = 0, False, []
        while i < len(line):
            ch = line[i]
            if in_string:
                kept.append(ch)
                if ch == "\\" and i + 1 < len(line):
                    kept.append(line[i + 1]); i += 1
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True; kept.append(ch)
            elif line.startswith("//", i):
                break
            else:
                kept.append(ch)
            i += 1
        out.append("".join(kept))
    stripped = "\n".join(out)
    return re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), stripped, flags=re.S)


def main(argv):
    if argv[1:] == ["--list-rules"]:
        print("\n".join(RULE_IDS)); return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr); return 2
    root = Path(argv[1]).resolve()
    sources = root / "Sources"
    if not sources.is_dir():
        print(f"lint-banned: no Sources directory under {root}", file=sys.stderr); return 2
    errors, count = [], 0
    for path in sorted(sources.rglob("*")):
        if path.suffix not in (".swift", ".c", ".h", ".m", ".mm") or not path.is_file():
            continue
        count += 1
        relative = path.relative_to(root).as_posix()
        try:
            text = strip_comments(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as error:
            print(f"lint-banned: cannot read {relative}: {error}", file=sys.stderr); return 2
        for rule_id, pattern, exempt in RULES:
            if relative in exempt:
                continue
            for match in re.finditer(pattern, text):
                line = text[:match.start()].count("\n") + 1
                errors.append(f"{relative}:{line}: [{rule_id}] banned: {match.group(0).strip()}")
        if relative not in AQUA_PATH_HOMES:
            for match in re.finditer(r"Aqua Voice", text):
                line = text[:match.start()].count("\n") + 1
                errors.append(f"{relative}:{line}: [aqua-path-literal] Aqua paths may be named only in Configuration.swift and OwnState.swift")
        if relative == READ_ONLY:
            missing = [flag for flag in REJECTED_FLAGS if flag not in text]
            if missing:
                errors.append(f"{relative}:1: [readonly-wrapper-incomplete] the wrapper does not mention {', '.join(missing)}")
    if not (sources / "ClawdCore/ReadOnlyFile.swift").is_file():
        errors.append(f"{READ_ONLY}:1: [readonly-wrapper-incomplete] the ReadOnlyFile wrapper is missing")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"lint-banned: {'FAIL' if errors else 'PASS'} ({count} source files, {len(RULE_IDS)} rules)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
