#!/usr/bin/python3
"""Refuses chat fixtures that still carry personal data.

Usage: scripts/check-chat-fixtures.py DIR      scan every regular file under DIR
       scripts/check-chat-fixtures.py --self-test

A fixture is sanitized when it holds none of: a home path other than /Users/example, the running user's name or home directory, an email
address outside an example domain, an API-key or bearer-token shape, a 40+ character base64/hex run (a signature, a token, a hash), or a
UUID that is not one of the sanitizer's placeholders (00000000-0000-4000-8000-<12 digits>: real session and request ids are replaced by them).
Exit 0 when clean, 1 with `file:line: rule` for each finding (the matched text is never printed), 2 on bad arguments.
--self-test also scans Tests/Fixtures/chat-bad (one file per rule, each holding a leak the checker must report) and fails unless every rule fires.
"""
import base64
import binascii
import os
import pwd
import re
import sys
import tempfile

HOME_PATH = re.compile(r"/(?:Users|home)/([A-Za-z0-9._-]+)")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+)")
KEY_SHAPE = re.compile(r"sk-[A-Za-z0-9_-]{8,}|[Bb]earer\s+[A-Za-z0-9._~+/=-]{8,}|xox[a-z]-[A-Za-z0-9-]{8,}|gh[pousr]_[A-Za-z0-9]{20,}")
LONG_RUN = re.compile(r"[A-Za-z0-9+=]{40,}")
# An image block's data (`"data":"<base64>"`) is allowed when it decodes to a PNG of at most 256 bytes: the capture driver's own generated test
# image, which holds no personal data. Any other data value is still checked as a token-like run.
IMAGE_DATA = re.compile(r'"data":"([A-Za-z0-9+/=]{1,400})"')
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
API_ID = re.compile(r"\b(?:toolu|msg|req)_[A-Za-z0-9]{20,}\b")
API_PLACEHOLDER = re.compile(r"(?:toolu|msg|req)_[0-9]{24}")
PLACEHOLDER = re.compile(r"00000000-0000-4000-8000-[0-9]{12}")
BAD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "Fixtures", "chat-bad")
RULES = ("home path other than /Users/example", "the running user's home directory", "the running user's name",
         "email address outside an example domain", "API-key or bearer-token shape", "40+ character token-like run", "UUID that is not a placeholder",
         "API id (toolu_, msg_, req_) that is not a placeholder")


def owner_names():
    names = set()
    for candidate in (os.environ.get("USER", ""), os.environ.get("LOGNAME", ""), pwd.getpwuid(os.getuid()).pw_name):
        if len(candidate) >= 3 and candidate.lower() != "example":
            names.add(candidate.lower())
    return names


def tiny_png(match):
    try:
        raw = base64.b64decode(match.group(1), validate=True)
    except (binascii.Error, ValueError):
        return match.group(0)
    return '"data":"PNG"' if len(raw) <= 256 and raw.startswith(PNG_SIGNATURE) else match.group(0)


def findings_in(text, names, home):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        lowered = line.lower()
        for match in HOME_PATH.finditer(line):
            if match.group(1) != "example":
                found.append((number, "home path other than /Users/example"))
        if home and home in line:
            found.append((number, "the running user's home directory"))
        for name in names:
            if name in lowered:
                found.append((number, "the running user's name"))
        for match in EMAIL.finditer(line):
            if not match.group(1).lower().startswith("example"):
                found.append((number, "email address outside an example domain"))
        if KEY_SHAPE.search(line):
            found.append((number, "API-key or bearer-token shape"))
        if LONG_RUN.search(IMAGE_DATA.sub(tiny_png, line)):
            found.append((number, "40+ character token-like run"))
        for match in UUID.finditer(line):
            if not PLACEHOLDER.fullmatch(match.group(0)):
                found.append((number, "UUID that is not a placeholder"))
        for match in API_ID.finditer(line):
            if not API_PLACEHOLDER.fullmatch(match.group(0)):
                found.append((number, "API id (toolu_, msg_, req_) that is not a placeholder"))
    return found


def scan(directory):
    names = owner_names()
    home = os.path.expanduser("~")
    files = 0
    bad = []
    for root, _, filenames in os.walk(directory):
        for filename in sorted(filenames):
            path = os.path.join(root, filename)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            files += 1
            text = open(path, encoding="utf-8", errors="replace").read()
            for number, rule in findings_in(text, names, home):
                bad.append("%s:%d: %s" % (path, number, rule))
    return files, bad


def bad_set_failures():
    """The committed leaking set must be refused, each of its files for the rule it is named after; the checker is not trusted until it has refused it."""
    expected = {"home-path.jsonl": "home path other than /Users/example", "user-directory.jsonl": "home path other than /Users/example",
                "email.jsonl": "email address outside an example domain", "real-uuid.jsonl": "UUID that is not a placeholder",
                "real-api-id.jsonl": "API id (toolu_, msg_, req_) that is not a placeholder"}
    failures = 0
    names = owner_names()
    home = os.path.expanduser("~")
    for filename, rule in sorted(expected.items()):
        path = os.path.join(BAD_DIR, filename)
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            failures += 1
            print("FAIL self-test: %s is missing" % path)
            continue
        if rule not in [found for _, found in findings_in(text, names, home)]:
            failures += 1
            print("FAIL self-test: %s was not reported as: %s" % (filename, rule))
    files, bad = scan(BAD_DIR)
    if files != len(expected) or len(bad) < len(expected):
        failures += 1
        print("FAIL self-test: the bad set gave %d finding(s) in %d file(s), wanted at least %d in %d" % (len(bad), files, len(expected), len(expected)))
    return failures


TINY_PNG = base64.b64encode(PNG_SIGNATURE + bytes(range(1, 80))).decode()


def self_test():
    names = {"jane"}
    home = "/Users/jane"
    clean = '{"cwd":"/Users/example/work","plugin":"example-plugin@example","sig":"SIG","id":"00000000-0000-4000-8000-000000000001"}'
    cases = [
        (clean, False),
        ('{"cwd":"/Users/jane/work"}', True),
        ('{"cwd":"/Users/someoneelse/work"}', True),
        ('{"owner":"Jane Doe"}', True),
        ('{"mail":"person@gmail.com"}', True),
        ('{"mail":"user@example.invalid"}', False),
        ('{"auth":"Bearer abcdefgh12345678"}', True),
        ('{"key":"sk-abcdefghij"}', True),
        ('{"sig":"' + "A" * 44 + '"}', True),
        ('{"sig":"' + "A" * 39 + '"}', False),
        ('{"source":{"type":"base64","data":"' + TINY_PNG + '"}}', False),
        ('{"source":{"type":"base64","data":"' + "A" * 60 + '"}}', True),
        ('{"source":{"type":"base64","data":"' + base64.b64encode(PNG_SIGNATURE + bytes(300)).decode().replace("AAAA", "AAAB")[:390] + '"}}', True),
        ('{"id":"3b70edf5-cf25-4280-8761-d587adf86ab7"}', True),
        ('{"id":"00000000-0000-4000-8000-00000000000a"}', True),
        ('{"wire_tool_inputs":{"toolu_01Xfvz2RW1PGmZHEz1XwR6s5":{}}}', True),
        ('{"id":"toolu_000000000000000000000001","m":"msg_lifecycle_v1"}', False),
    ]
    failures = 0
    for text, expect_bad in cases:
        got = bool(findings_in(text, names, home))
        if got != expect_bad:
            failures += 1
            print("FAIL self-test: %r -> flagged=%s, wanted %s" % (text[:60], got, expect_bad))
    with tempfile.TemporaryDirectory() as directory:
        with open(os.path.join(directory, "ok.jsonl"), "w") as handle:
            handle.write(clean + "\n")
        files, bad = scan(directory)
        if files != 1 or bad:
            failures += 1
            print("FAIL self-test: a clean directory was refused")
        with open(os.path.join(directory, "leak.jsonl"), "w") as handle:
            handle.write('{"cwd":"/Users/someoneelse/work"}\n')
        files, bad = scan(directory)
        if len(bad) != 1 or "leak.jsonl:1" not in bad[0]:
            failures += 1
            print("FAIL self-test: a leaking file was not reported by file and line")
    failures += bad_set_failures()
    print("check-chat-fixtures self-test: %s" % ("pass" if failures == 0 else "%d failure(s)" % failures))
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        print("usage: scripts/check-chat-fixtures.py DIR | --self-test", file=sys.stderr)
        return 2
    files, bad = scan(argv[0])
    for line in bad:
        print(line)
    if bad:
        print("check-chat-fixtures: %d finding(s) in %d file(s) under %s" % (len(bad), files, argv[0]))
        return 1
    print("check-chat-fixtures: %d file(s) clean under %s" % (files, argv[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
