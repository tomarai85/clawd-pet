#!/usr/bin/python3
"""Is the vendored SwiftTerm still exactly upstream's v1.99.1, plus the patches PATCHES.md lists, and nothing that reaches outside the process?

  check-vendor.py DIR          DIR is Vendor/SwiftTerm
  check-vendor.py --self-test  plants each fault in a temporary copy of Vendor/SwiftTerm and requires the check to see it

Checks (R9.3, R9.4):
  1. the sha256 of DIR/UPSTREAM.sha256 is the pinned digest;
  2. every file under DIR/Sources/SwiftTerm matches its line in UPSTREAM.sha256, or is listed in DIR/PATCHES.md with its actual sha256; and no
     upstream file other than the left-out ones is missing;
  3. DIR/LICENSE matches its line;
  4. none of the left-out files is present (LocalProcess.swift, Pty.swift, HeadlessTerminal.swift, Mac/MacLocalTerminalView.swift, iOS/,
     Documentation.docc/, Mac/README.md);
  5. the scan of comment-free code finds exactly one `addLocalMonitorForEvents(matching: .mouseMoved)` and exactly one `NSWorkspace.shared.open`
     (the default link handler Clawd's delegate replaces), and none of: another local monitor, addGlobalMonitorForEvents, an event tap or post,
     an application activation (`activate(` on NSApp, NSApplication.shared or an NSRunningApplication, or the ignoringOtherApps: / options:
     activation labels), makeKey, makeKeyAndOrderFront, orderFrontRegardless, socket(, URLSession, NWConnection.

PATCHES.md lines that list a file: - `<path under DIR>` sha256 `<hex>` -- <reason>
Exit: 0 holds; 1 a check failed (each failure printed); 2 bad arguments. --self-test exits 0 only when every planted fault is caught.
Run it as /usr/bin/python3 -I scripts/check-vendor.py ...
"""
import hashlib
import re
import shutil
import sys
import tempfile
from pathlib import Path

PINNED_DIGEST = "ff58b68e5605122c89bf054dcbe4320d3106d3562cecad7cd77ddf102de62b2a"
LEFT_OUT_FILES = ["LocalProcess.swift", "Pty.swift", "HeadlessTerminal.swift", "Mac/MacLocalTerminalView.swift", "Mac/README.md"]
LEFT_OUT_DIRS = ["iOS", "Documentation.docc"]
SOURCES = "Sources/SwiftTerm"

LOCAL_MONITOR = re.compile(r"addLocalMonitorForEvents\s*\(")
MOUSE_MOVED_MONITOR = re.compile(r"addLocalMonitorForEvents\s*\(\s*matching:\s*\.mouseMoved\b")
WORKSPACE_OPEN = re.compile(r"NSWorkspace\.shared\.open\b")
FORBIDDEN = [
    ("addGlobalMonitorForEvents", re.compile(r"addGlobalMonitorForEvents")),
    ("an event tap or post", re.compile(r"CGEventTapCreate|CGEvent\.tapCreate|CGEventPost|CGEventPostToPid|\.post\s*\(\s*tap\s*:|postToPid")),
    ("an application activation",
     re.compile(r"(?:\bNSApp|NSApplication\.shared|NSRunningApplication[^\n]*?)\s*\.\s*activate\s*\(|ignoringOtherApps\s*:|activate\s*\(\s*options\s*:")),
    ("makeKey", re.compile(r"\bmakeKey(?:AndOrderFront|Window)?\b")),
    ("orderFrontRegardless", re.compile(r"\borderFrontRegardless\b")),
    ("socket(", re.compile(r"(?<![\w.])socket\s*\(")),
    ("URLSession", re.compile(r"\bURLSession\b")),
    ("NWConnection", re.compile(r"\bNWConnection\b")),
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code_lines(path):
    """The lines of a Swift file that are not comment lines (a line starting with //, /// , /* or * after its indent)."""
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(("//", "/*", "*")):
            continue
        yield number, line


def upstream_lines(root):
    table = {}
    for line in (root / "UPSTREAM.sha256").read_text().splitlines():
        digest, _, name = line.partition("  ")
        table[name] = digest
    return table


def patch_lines(root):
    table = {}
    for line in (root / "PATCHES.md").read_text().splitlines():
        match = re.match(r"^- `([^`]+)` sha256 `([0-9a-f]{64})`", line)
        if match:
            table[match.group(1)] = match.group(2)
    return table


def check(root):
    root = Path(root)
    failures = []
    if not (root / "UPSTREAM.sha256").is_file() or not (root / "PATCHES.md").is_file():
        return ["UPSTREAM.sha256 or PATCHES.md is missing"]
    digest = sha256(root / "UPSTREAM.sha256")
    if digest != PINNED_DIGEST:
        failures.append(f"UPSTREAM.sha256 digest is {digest}, not {PINNED_DIGEST}")
    upstream, patches = upstream_lines(root), patch_lines(root)
    sources = root / SOURCES
    present = sorted(p for p in sources.rglob("*") if p.is_file() and p.name != ".DS_Store")
    for path in present:
        relative = path.relative_to(root).as_posix()
        actual = sha256(path)
        if relative in patches:
            if patches[relative] != actual:
                failures.append(f"{relative}: PATCHES.md lists sha256 {patches[relative]}, the file is {actual}")
        elif upstream.get(relative) != actual:
            failures.append(f"{relative}: differs from UPSTREAM.sha256 or is not in it, and PATCHES.md does not list it")
    left_out = [f"{SOURCES}/{name}" for name in LEFT_OUT_FILES]
    for name in sorted(upstream):
        if not name.startswith(SOURCES + "/"):
            continue
        inside = name[len(SOURCES) + 1:]
        if name in left_out or any(inside.startswith(d + "/") for d in LEFT_OUT_DIRS):
            continue
        if not (root / name).is_file():
            failures.append(f"{name}: an upstream file that is neither vendored nor left out")
    for name in left_out:
        if (root / name).exists():
            failures.append(f"{name}: a left-out file is present")
    for directory in LEFT_OUT_DIRS:
        if (sources / directory).exists():
            failures.append(f"{SOURCES}/{directory}: a left-out directory is present")
    license_path = root / "LICENSE"
    if not license_path.is_file():
        failures.append("LICENSE is missing")
    elif upstream.get("LICENSE") != sha256(license_path):
        failures.append("LICENSE differs from UPSTREAM.sha256")
    monitors, opens = [], []
    for path in present:
        if path.suffix != ".swift":
            continue
        relative = path.relative_to(root).as_posix()
        for number, line in code_lines(path):
            if MOUSE_MOVED_MONITOR.search(line):
                monitors.append(f"{relative}:{number}")
            elif LOCAL_MONITOR.search(line):
                failures.append(f"{relative}:{number}: another addLocalMonitorForEvents")
            if WORKSPACE_OPEN.search(line):
                opens.append(f"{relative}:{number}")
            for label, pattern in FORBIDDEN:
                if pattern.search(line):
                    failures.append(f"{relative}:{number}: {label}")
    if len(monitors) != 1:
        failures.append(f"expected exactly one addLocalMonitorForEvents(matching: .mouseMoved), found {len(monitors)}: {monitors}")
    if len(opens) != 1:
        failures.append(f"expected exactly one NSWorkspace.shared.open (the default link handler), found {len(opens)}: {opens}")
    return failures


def self_test(root):
    root = Path(root)
    problems = []
    if check(root):
        print("check-vendor self-test: the real tree does not pass:", file=sys.stderr)
        for line in check(root):
            print("  " + line, file=sys.stderr)
        return 2
    target = f"{SOURCES}/Apple/AppleTerminalView.swift"

    def register_patch(copy):
        """Lists the edited file in PATCHES.md with its new digest, so that only the scan can flag a planted call."""
        path = copy / target
        with open(copy / "PATCHES.md", "a") as handle:
            handle.write(f"\n- `{target}` sha256 `{sha256(path)}` -- planted by the self-test\n")

    def plant_code(text):
        def mutate(copy):
            path = copy / target
            path.write_text(path.read_text() + "\n" + text + "\n")
            register_patch(copy)
        return mutate

    def patched_without_line(copy):
        path = copy / target
        path.write_text(path.read_text() + "\n// changed\n")

    def missing_license(copy):
        (copy / "LICENSE").unlink()

    def wrong_digest(copy):
        path = copy / "UPSTREAM.sha256"
        path.write_text(path.read_text() + "0" * 64 + "  Sources/SwiftTerm/Extra.swift\n")

    def left_out_present(copy):
        (copy / SOURCES / "Pty.swift").write_text("import Foundation\n")

    def comment_only(copy):
        path = copy / target
        path.write_text(path.read_text() + "\n    /// NSWorkspace.shared.open and NSApp.activate in prose\n")
        register_patch(copy)

    def layout_constraint(copy):
        path = copy / target
        path.write_text(path.read_text() + "\nfunc layoutOnly() { NSLayoutConstraint.activate([]) }\n")
        register_patch(copy)

    faults = [
        ("a changed file without a PATCHES line", patched_without_line, True),
        ("a planted addGlobalMonitorForEvents", plant_code("func plantedGlobal() { _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in } }"), True),
        ("a planted URLSession", plant_code("func plantedSession() { _ = URLSession.shared }"), True),
        ("a planted NSApp.activate", plant_code("func plantedActivate() { NSApp.activate(ignoringOtherApps: true) }"), True),
        ("a second addLocalMonitorForEvents", plant_code("func plantedLocal() { _ = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { $0 } }"), True),
        ("a second NSWorkspace.shared.open in code", plant_code("func plantedOpen() { NSWorkspace.shared.open(URL(fileURLWithPath: \"/\")) }"), True),
        ("a missing LICENSE", missing_license, True),
        ("a wrong UPSTREAM digest", wrong_digest, True),
        ("a left-out file present", left_out_present, True),
        ("a comment naming the calls is NOT a fault", comment_only, False),
        ("NSLayoutConstraint.activate is NOT a fault", layout_constraint, False),
    ]
    for name, mutate, must_fail in faults:
        with tempfile.TemporaryDirectory(prefix="check-vendor-") as temporary:
            copy = Path(temporary) / "SwiftTerm"
            shutil.copytree(root, copy)
            mutate(copy)
            found = check(copy)
        if must_fail and not found:
            problems.append(f"{name}: not caught")
        if not must_fail and found:
            problems.append(f"{name}: flagged: {found}")
    for line in problems:
        print(f"check-vendor self-test FAILED: {line}", file=sys.stderr)
    if not problems:
        print(f"check-vendor self-test: ok ({len(faults)} cases)")
    return 1 if problems else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test(Path(__file__).resolve().parent.parent / "Vendor" / "SwiftTerm")
    if len(argv) == 1 and not argv[0].startswith("-") and Path(argv[0]).is_dir():
        failures = check(argv[0])
        for line in failures:
            print(line)
        print(f"check-vendor: {'FAIL' if failures else 'PASS'} ({len(failures)} problem(s))")
        return 1 if failures else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
