#!/usr/bin/python3
"""Did a build or test run take the user's keyboard, or bring an application forward? Read-only.

  keyboard-check.py begin STATE_FILE     right before a run: the start time (one second early), every pid alive now, the frontmost pid
  keyboard-check.py check STATE_FILE     right after it: WindowServer's lines since the start, judged by the rules below
  keyboard-check.py --positive-control   the rules over real WindowServer lines of 2026-10-25 23:48:50-23:49:10 (a Dock key thief and the
                                         deferrals around it), with that thief's name standing in for a test process: H2 on the real line, H1 and H2
                                         when the name in it is replaced by swiftpm-testing-helper, and H3 on the real deferrals with an empty pid set
  keyboard-check.py --self-test          the rules over fixture lines; starts nothing and reads nothing of the machine

Rules (a "line" is a whole WindowServer message, continuation lines included):
  H1  a line naming `testing-helper` that grants it focus: `key thief updated ... (testing-helper)` or a `Deferring events from ...` line naming
      it. (`Making <private> <psn> the front process` lines name no process on 26.x and later; the Deferring lines carry name and pid, so they cover
      front changes.) Lifecycle lines (`Process creation`, `Process death`) and the policy lines a
      death causes (`deferringPolicyEvaluationSuppression`, `permitted list updated ... removed`) are not hits: every test run that creates
      AppKit objects makes a WindowServer connection and closes it (measured 2026-10-25 19:43, no focus line in the window).
  H2  a `key thief updated <id> <psn> (<name>)` or `frontmostProcess: <psn> (<name>)` whose name is a test runner's
      (swiftpm-testing-helper, xctest, a name ending in PackageTests, clawd-chat-stub).
  H3  a `Deferring events from frontmost process PSN <psn> (<name>) -> <pid: N>` whose N was not alive at `begin`: a process the run
      started is receiving the user's keys.
  H4  the frontmost application at `check` differs from the one at `begin`, and the HID idle time (ioreg -c IOHIDSystem, HIDIdleTime) is
      at least the run's length, so no user input happened during the run and the change was the run's. With input the change is
      printed as "attributed to the user" and is not a hit.

Reads only: /usr/bin/log show, ps -axo pid=, lsappinfo front, lsappinfo info -only pid, ioreg -c IOHIDSystem. Changes nothing.
Exit: 0 no hit; 1 a hit (each hit line printed with its rule); 2 bad arguments, an unreadable log, or a blind positive control or self-test.
Run it as /usr/bin/python3 -I scripts/keyboard-check.py ...
"""
import json
import re
import subprocess
import sys
import time

LOG = "/usr/bin/log"
WINDOW_SERVER_FILTER = ('process == "WindowServer" AND (eventMessage CONTAINS "key thief updated" OR eventMessage CONTAINS "updated frontmost process"'
                        ' OR eventMessage CONTAINS "Deferring events from" OR eventMessage CONTAINS "the front process")')
RUNNER_NAMES = {"swiftpm-testing-helper", "xctest", "clawd-chat-stub"}
STAMP = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} ")
THIEF = re.compile(r"key thief updated \S+ \S+ \(([^)]+)\)")
FRONTMOST = re.compile(r"frontmostProcess: \S+ \(([^)]+)\)")
DEFERRING_ANY = re.compile(r"Deferring events from")
DEFERRING = re.compile(r"Deferring events from frontmost process PSN \S+ \(([^)]+)\) -> <pid: (\d+)>")


class Unreadable(Exception):
    pass


def is_runner(name):
    return name in RUNNER_NAMES or name.endswith("PackageTests")


def messages(text):
    """Splits `log show --style compact` output into whole messages: a line that starts with a timestamp opens one, any other line continues it."""
    found = []
    for line in text.splitlines():
        if STAMP.match(line):
            found.append(line)
        elif found and line.strip():
            found[-1] += "\n" + line
    return found


def judge(found, alive):
    """The hits (rule, message) of H1-H3 over whole messages. `alive` is the set of pids that were alive at `begin`."""
    hits = []
    for message in found:
        grants_focus = THIEF.search(message) or DEFERRING_ANY.search(message)
        if "testing-helper" in message and grants_focus:
            hits.append(("H1", message))
        names = ([m.group(1) for m in THIEF.finditer(message)] + [m.group(1) for m in FRONTMOST.finditer(message)])
        if any(is_runner(name) for name in names):
            hits.append(("H2", message))
        for m in DEFERRING.finditer(message):
            if int(m.group(2)) not in alive:
                hits.append(("H3", message))
    return hits


def judge_front(begin_front, end_front, idle_seconds, run_seconds, end_is_lock_screen=False):
    """H4: returns ("hit", text), ("user", text), ("lock", text) or None. The lock screen (loginwindow, alive before the run) coming forward
    after the user has been idle for the whole run is the machine's own idle lock, not the run's doing."""
    if begin_front is None or end_front is None or begin_front == end_front:
        return None
    if end_is_lock_screen:
        return ("lock", f"the frontmost application changed from pid {begin_front} to the lock screen (loginwindow pid {end_front}); HID idle {idle_seconds:.1f} s, run {run_seconds:.1f} s")
    text = f"the frontmost application changed from pid {begin_front} to pid {end_front}; HID idle {idle_seconds:.1f} s, run {run_seconds:.1f} s"
    if idle_seconds >= run_seconds:
        return ("hit", text)
    return ("user", text)


def run(command):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as error:
        raise Unreadable(f"{command[0]}: {error}")
    if result.returncode != 0:
        raise Unreadable(f"{command[0]} exited {result.returncode}: {result.stderr.strip()[:200]}")
    return result.stdout


def log_messages(start, end=None):
    found = []
    command = [LOG, "show", "--style", "compact", "--start", start]
    if end:
        command += ["--end", end]
    text = run(command + ["--predicate", WINDOW_SERVER_FILTER])
    if "Timestamp" not in text[:200]:
        raise Unreadable("log show printed no header")
    for message in messages(text):
        if message not in found:
            found.append(message)
    return found


def alive_pids():
    return {int(line) for line in run(["/bin/ps", "-axo", "pid="]).split() if line.isdigit()}


def front_pid():
    asn = run(["/usr/bin/lsappinfo", "front"]).strip()
    if not asn:
        return None
    match = re.search(r'"pid"=(\d+)', run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn]))
    return int(match.group(1)) if match else None


def idle_seconds():
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', run(["/usr/sbin/ioreg", "-c", "IOHIDSystem"]))
    if not match:
        raise Unreadable("ioreg printed no HIDIdleTime")
    return int(match.group(1)) / 1e9


def stamp(epoch):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def begin(path):
    started = time.time() - 1
    state = {"start": stamp(started), "startEpoch": started, "pids": sorted(alive_pids()), "front": front_pid()}
    with open(path, "w") as handle:
        json.dump(state, handle)
    print(f"keyboard-check begin: start {state['start']}, {len(state['pids'])} pids, front pid {state['front']}")
    return 0


def report(hits, front):
    for rule, message in hits:
        print(f"HIT {rule}: " + message.replace("\n", " | "))
    if front is not None:
        kind, text = front
        label = {"hit": "HIT H4: ", "lock": "the lock screen came forward (not a hit): ", "user": "front changed during the run with user input: attributed to the user: "}[kind]
        print(label + text)


def check(path):
    with open(path) as handle:
        state = json.load(handle)
    now = time.time()
    hits = judge(log_messages(state["start"]), set(state["pids"]))
    end_front = front_pid()
    lock = end_front is not None and end_front in set(state["pids"]) and run(["/bin/ps", "-o", "comm=", "-p", str(end_front)]).strip().endswith("/loginwindow")
    front = judge_front(state["front"], end_front, idle_seconds(), now - state["startEpoch"], lock)
    report(hits, front)
    count = len(hits) + (1 if front and front[0] == "hit" else 0)
    print(f"keyboard-check check: {count} hits")
    return 1 if count else 0


POSITIVE_START, POSITIVE_END = "2026-10-25 23:48:50", "2026-10-25 23:49:10"
POSITIVE_NAME = "Dock"


def positive_control():
    """Real lines, not fixtures: a Dock key thief and the deferrals around it, kept in the unified log from 23:48 on 2026-10-25."""
    real = log_messages(POSITIVE_START, POSITIVE_END)
    thieves = [m for m in real if f"key thief updated" in m and f"({POSITIVE_NAME})" in m]
    defers = [m for m in real if DEFERRING.search(m)]
    RUNNER_NAMES.add(POSITIVE_NAME)
    try:
        h2 = [m for r, m in judge(thieves, {1}) if r == "H2"]
    finally:
        RUNNER_NAMES.discard(POSITIVE_NAME)
    swapped = [m.replace(f"({POSITIVE_NAME})", "(swiftpm-testing-helper)") for m in thieves]
    h1 = [m for r, m in judge(swapped, {1}) if r == "H1"]
    h3 = [m for r, m in judge(defers, set()) if r == "H3"]
    if not (h2 and h1 and h3):
        print(f"keyboard-check positive-control: BLIND (real thief lines {len(thieves)}, deferral lines {len(defers)}; H2 {len(h2)}, H1 {len(h1)}, H3 {len(h3)})", file=sys.stderr)
        return 2
    print(f"keyboard-check positive-control: ok, H2 on {len(h2)} real thief message(s), H1 on {len(h1)} with the name replaced, H3 on {len(h3)} real deferral(s)")
    return 0


FIXTURE_THIEF = ("2026-10-25 16:41:34.649 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] 14e237[StealKeyFocusReturningID]: [DeferringManager] Updating policy {\n"
                 "    advicePolicy: .keyThief;\n    frontmostProcess: 0x0-0x85a85a (Orca) mainConnectionID: AC58B;\n    keyThiefConnectionID: 14E237;\n"
                 "} for reason: key thief updated 14e237 0x0-0x30d10ce (%s)\n")
FIXTURE_DEFER = ("2026-10-25 16:41:34.651 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] 14e237[X]: [DeferringManager] Deferring events "
                 "from frontmost process PSN 0x0-0x85a85a (Orca) -> <pid: %d>\n")
FIXTURE_CREATE = ("2026-10-25 19:43:29.197 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Lifecycle] 940d3[CreateApplication]: Process creation: "
                  "0x0-0x313d13a (swiftpm-testing-helper) connectionID: 940D3 pid: 80317 in session 0x101\n")
FIXTURE_DEATH = ("2026-10-25 19:43:31.754 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Lifecycle] 0[outside of RPC]: Process death: "
                 "0x0-0x313d13a (swiftpm-testing-helper) connectionID: 940D3 pid: 80317 in session 0x101\n"
                 "2026-10-25 19:43:31.754 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] <BSCompoundAssertion:0x9dac116c0> "
                 "([FocusManager:257]-deferringPolicyEvaluationSuppression) acquire for reason:process death - 0x0-0x313d13a (swiftpm-testing-helper) "
                 "acq:0x9d813fe40 count:1\n"
                 "2026-10-25 19:43:31.755 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] 0[outside of RPC]: [FocusManager:257] update to "
                 "deferring policy requested for reason: permitted list updated - 0x0-0x313d13a removed - but we are suppressing evaluation for reasons: "
                 "{(\n    \"process death - 0x0-0x313d13a (swiftpm-testing-helper)\"\n)}\n")
FIXTURE_MAKING = ("2026-10-26 03:18:24.782 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] 74003[SetFrontProcess]: [DataSource] Making <private> "
                  "0x0-0x30ca0c7 the front process in session 0x186b9\n")
FIXTURE_DEFER_NAMED = ("2026-10-26 03:42:18.242 Df WindowServer[624:1701] [com.apple.SkyLight.processes:Focus] 0[outside of RPC]: [DeferringManager] Deferring events "
                       "from frontmost process PSN 0x0-0x3003 (%s) -> <pid: %d>\n")
FIXTURE_FRONT = ("2026-10-25 19:17:48.423 Df WindowServer[414:1414] [com.apple.SkyLight.processes:Focus] 6b893[Y]: [DeferringManager] Updating policy {\n"
                 "    advicePolicy: .frontmost;\n    frontmostProcess: 0x0-0x11011 (%s) mainConnectionID: 6B893;\n} for reason: updated frontmost process\n")


def self_test():
    failures = []

    def expect(name, condition):
        if not condition:
            failures.append(name)

    def rules(text, alive):
        return sorted({r for r, _ in judge(messages(text), alive)})

    expect("multi-line message is one message", len(messages(FIXTURE_THIEF % "swiftpm-testing-helper" + FIXTURE_DEFER % 77655)) == 2)
    expect("a process creation line naming testing-helper is not a hit", rules(FIXTURE_CREATE, {1}) == [])
    expect("a process death and its policy lines naming testing-helper are not hits", rules(FIXTURE_DEATH, {1}) == [])
    expect("the death lines are three messages", len(messages(FIXTURE_DEATH)) == 3)
    expect("a real `Making <private> ... the front process` line names no process and is no hit", rules(FIXTURE_MAKING, {1}) == [])
    expect("a real deferral naming testing-helper to a new pid is H1 and H3", rules(FIXTURE_DEFER_NAMED % ("swiftpm-testing-helper", 77655), {1}) == ["H1", "H3"])
    expect("the 16:41:34.649 thief line is H1", "H1" in rules(FIXTURE_THIEF % "swiftpm-testing-helper", {1}))
    expect("the 16:41:34.651 deferral line is H3", rules(FIXTURE_DEFER % 77655, {1}) == ["H3"])
    expect("a thief naming testing-helper is H1 and H2", rules(FIXTURE_THIEF % "swiftpm-testing-helper", {1}) == ["H1", "H2"])
    expect("a thief naming xctest is a hit (H2)", rules(FIXTURE_THIEF % "xctest", {1}) == ["H2"])
    expect("a thief naming a PackageTests process is a hit", rules(FIXTURE_THIEF % "clawdPackageTests", {1}) == ["H2"])
    expect("a thief naming clawd-chat-stub is a hit", rules(FIXTURE_THIEF % "clawd-chat-stub", {1}) == ["H2"])
    expect("a thief naming Spotlight is not a hit", rules(FIXTURE_THIEF % "Spotlight", {1}) == [])
    expect("a frontmost line naming xctest is a hit", rules(FIXTURE_FRONT % "xctest", {1}) == ["H2"])
    expect("a frontmost line naming Finder is not a hit", rules(FIXTURE_FRONT % "Finder", {1}) == [])
    expect("a deferral to a pid started during the run is a hit (H3)", rules(FIXTURE_DEFER % 77655, {1, 2}) == ["H3"])
    expect("the same deferral to an older pid is not a hit", rules(FIXTURE_DEFER % 77655, {1, 77655}) == [])
    expect("a front change with no input is a hit (H4)", judge_front(10, 20, 600.0, 60.0) is not None and judge_front(10, 20, 600.0, 60.0)[0] == "hit")
    expect("the same change with input is attributed to the user", judge_front(10, 20, 3.0, 60.0) is not None and judge_front(10, 20, 3.0, 60.0)[0] == "user")
    expect("the lock screen coming forward is not a hit", judge_front(10, 416, 5000.0, 60.0, True)[0] == "lock")
    expect("a non-lock front change with idle input is still a hit", judge_front(10, 416, 5000.0, 60.0, False)[0] == "hit")
    expect("no change is nothing", judge_front(10, 10, 600.0, 60.0) is None)
    expect("an unreadable front is nothing here (the reader raises instead)", judge_front(None, 10, 600.0, 60.0) is None)
    expect("empty output is no message", messages("Timestamp               Ty Process[PID:TID]\n") == [])
    if failures:
        for name in failures:
            print(f"keyboard-check self-test FAILED: {name}", file=sys.stderr)
        return 2
    print("keyboard-check self-test: ok (24 cases)")
    return 0


def main(argv):
    try:
        if argv == ["--self-test"]:
            return self_test()
        if argv == ["--positive-control"]:
            return positive_control()
        if len(argv) == 2 and argv[0] == "begin":
            return begin(argv[1])
        if len(argv) == 2 and argv[0] == "check":
            return check(argv[1])
    except (Unreadable, OSError, ValueError, KeyError) as error:
        print(f"keyboard-check: cannot read: {error}", file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
