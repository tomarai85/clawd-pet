#!/usr/bin/python3
"""Checks the CPU evidence files of the done-bar (spec section 7, item 3, and 7b "CPU").

Usage: python3 -I scripts/check-cpu-evidence.py FILE [FILE ...]
Each FILE is the --json output of `clawd-measure-cpu ... --budget Bn`. Exit 0 only when every file exists, is a PASS for its own budget
(recomputed here from the measured numbers, never taken from the file's own verdict), covers its full window with one pid and one
start time, and shows what its budget needs:
  B1  motion off, v1's budget unchanged: CPU under 0.3 s and idle wakeups under 600 in 600 s; renders happened; no dictation line.
  B2  idle life at the default over 3600 s: CPU at most 1.8 s, wakeups under 3600; the seeded schedule shows at least 10 idle
      motions, at least 1 walk and at least 1 look change; no dictation line.
  B3  600 s in a quiet condition: no render, at most 1 armed timer at every sample and over the process's life, CPU under 0.05 s,
      a QUIET line that still held at the end.
  B4  lively with walk on, 600 s: CPU at most 1.5 s, at least 5 idle motions, no dictation line.
  B5  in situ (the installed, visible agent), 600 s: v1's budget exactly (CPU under 0.3 s, wakeups under 600), at least one idle-life
      line (MOTION or WALK) and no dictation line. A NOT RUN window is not a pass.
Files for B1 to B4 must all come from the same agent binary (same sha256): a budget claim is about one build.
"""
import json
import re
import sys
from pathlib import Path

HEADLESS_MODE = "test-idle-render-no-window"
NAMES = {"cpu-b1": "B1", "cpu-b2": "B2", "cpu-b3": "B3", "cpu-b4": "B4", "cpu-b5-in-situ": "B5", "cpu-b5": "B5"}
WINDOW = {"B1": 600, "B2": 3600, "B3": 600, "B4": 600, "B5": 600}
# (cpu limit, inclusive, wakeups limit or None)
LIMITS = {"B1": (0.3, False, 600), "B2": (1.8, True, 3600), "B3": (0.05, False, None), "B4": (1.5, True, None), "B5": (0.3, False, 600)}


def number(report, key):
    value = report.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def check(path):
    """Returns (budget, agent_sha, list of problems)."""
    problems = []
    file = Path(path)
    if not file.is_file():
        return None, None, [f"{path}: does not exist"]
    try:
        report = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, None, [f"{path}: cannot be read as JSON ({error})"]
    if not isinstance(report, dict):
        return None, None, [f"{path}: not a JSON object"]
    stem = file.name[:-5] if file.name.endswith(".json") else file.name
    expected = NAMES.get(stem)
    budget = report.get("budget")
    if budget not in WINDOW:
        return None, None, [f"{path}: no valid budget field (got {budget!r})"]
    if expected and expected != budget:
        problems.append(f"{path}: the file name says {expected} but the report measured {budget}")
    mode = report.get("mode")
    if budget == "B5":
        if mode != "installed-agent":
            problems.append(f"{path}: B5 must measure the installed agent (mode installed-agent), got {mode!r}")
    elif mode != HEADLESS_MODE:
        problems.append(f"{path}: {budget} must come from the headless render mode {HEADLESS_MODE}, got {mode!r}")

    duration = number(report, "duration_s")
    if duration is None or duration < WINDOW[budget]:
        problems.append(f"{path}: the window is {duration!r} s, {budget} needs at least {WINDOW[budget]} s")
    if report.get("pid_start") is None or report.get("pid_start") != report.get("pid_end"):
        problems.append(f"{path}: the pid changed during the window ({report.get('pid_start')!r} -> {report.get('pid_end')!r})")
    if not report.get("start_time_start") or report.get("start_time_start") != report.get("start_time_end"):
        problems.append(f"{path}: the process start time changed during the window")
    sha = report.get("agent_sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        problems.append(f"{path}: no agent sha256")
        sha = None

    cpu_limit, inclusive, wake_limit = LIMITS[budget]
    cpu = number(report, "cpu_delta_s")
    if cpu is None:
        problems.append(f"{path}: no CPU measurement")
    elif (cpu > cpu_limit) if inclusive else (cpu >= cpu_limit):
        problems.append(f"{path}: CPU {cpu:.4f} s breaks the {budget} budget ({'at most' if inclusive else 'under'} {cpu_limit} s)")
    wakeups = number(report, "wakeups_delta")
    if wake_limit is not None:
        if wakeups is None:
            problems.append(f"{path}: no wakeup measurement")
        elif wakeups >= wake_limit:
            problems.append(f"{path}: {int(wakeups)} idle wakeups break the {budget} budget (under {wake_limit})")

    dictation = number(report, "dictation_lines")
    if budget != "B3" and (dictation is None or dictation != 0):
        problems.append(f"{path}: the window holds dictation lines ({dictation!r}): measured something else")
    if report.get("state_log_idle_whole_window") is not True:
        problems.append(f"{path}: the agent was not idle for the whole window")
    renders = number(report, "render_count_delta")
    motions = number(report, "idle_motions") or 0
    walks = number(report, "walks") or 0
    looks = number(report, "look_changes") or 0
    if budget in ("B1", "B2", "B4") and not (renders and renders > 0):
        problems.append(f"{path}: no render inside the window (render_count_delta={renders!r})")
    if budget == "B2":
        if motions < 10:
            problems.append(f"{path}: the seeded schedule shows {int(motions)} idle motions, B2 needs at least 10")
        if walks < 1:
            problems.append(f"{path}: the seeded schedule shows no walk")
        if looks < 1:
            problems.append(f"{path}: the seeded schedule shows no look change")
    if budget == "B3":
        if renders != 0:
            problems.append(f"{path}: {renders!r} renders in a quiet window, B3 needs none")
        sampled, lifetime = report.get("timers_max_sampled"), report.get("timers_max_lifetime")
        if not isinstance(sampled, int) or isinstance(sampled, bool) or sampled > 1:
            problems.append(f"{path}: armed timers sampled {sampled!r}, B3 allows at most 1 at every sample")
        if not isinstance(lifetime, int) or isinstance(lifetime, bool) or lifetime > 1:
            problems.append(f"{path}: armed timers over the process's life {lifetime!r}, B3 allows at most 1")
        if not report.get("quiet_reason"):
            problems.append(f"{path}: no quiet condition held at the end of the window")
    if budget == "B4" and motions < 5:
        problems.append(f"{path}: lively shows {int(motions)} idle motions, B4 needs at least 5 to mean anything")
    if budget == "B5" and motions + walks < 1:
        problems.append(f"{path}: no idle-life line (MOTION or WALK) in the window: NOT RUN, rerun it")
    if report.get("result") == "NOT RUN":
        problems.append(f"{path}: the measuring tool says NOT RUN")
    elif report.get("result") != "PASS":
        problems.append(f"{path}: the measuring tool's own verdict is {report.get('result')!r}")
    summary = (f"{budget}: {duration:.0f} s, CPU {cpu:.4f} s, wakeups {int(wakeups) if wakeups is not None else 'n/a'}, renders {renders}, "
               f"motions {int(motions)}, walks {int(walks)}, looks {int(looks)}") if not problems or (duration and cpu is not None) else budget
    print(f"{'FAIL' if problems else 'PASS'} {path}: {summary}")
    return budget, sha, problems


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    all_problems = []
    seen = {}
    headless_hashes = set()
    for path in argv[1:]:
        budget, sha, problems = check(path)
        all_problems.extend(problems)
        if budget in seen:
            all_problems.append(f"{path}: {budget} is given twice")
        if budget:
            seen[budget] = path
        if budget in ("B1", "B2", "B3", "B4") and sha:
            headless_hashes.add(sha)
    if len(headless_hashes) > 1:
        all_problems.append("B1 to B4 were measured on different agent builds: " + ", ".join(sorted(h[:12] for h in headless_hashes)))
    for problem in all_problems:
        print(problem, file=sys.stderr)
    print(f"check-cpu-evidence: {'FAIL' if all_problems else 'PASS'} ({len(argv) - 1} files)")
    return 1 if all_problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
