#!/usr/bin/python3 -I
"""A claude stand-in for the steer tests: plays frames of a fixture (or frames the test wrote) when user frames and interrupts come in.

It reads plan.json from its working directory, which is the chat folder of the test. The plan:
  {"fixture": "<path of a .jsonl>",
   "subst": {"<a uuid in the fixture>": <n>},      # that uuid becomes the uuid of the n-th user frame received (1-based), as Clawd's frames carry theirs
   "steps": [{"on_user": 1, "frames": [...]}, {"on_interrupt": 1, "frames": [...]}, {"on_cancel_async": 1, "frames": [...]}]}
A step may carry "delay": seconds, slept before its frames are played (a later step of the same trigger, so its frames come after the earlier ones).
The stub also writes argv.txt (its arguments, one per line), env.txt (the CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS variable) and received.jsonl (every line
that came in on stdin) into the working directory, for the tests to read.
A frame item is an integer (one fixture line, 0-based), [from, to] (the fixture lines from..to-1), or an object (a frame written out whole; a string
"$n" in it becomes the uuid of the n-th user frame; "$rid" the request_id of the control request being answered, "$msg" its message_uuid).
Stdin closing ends the process. The first line of stdout the stub writes is flushed at once.
"""
import json
import os
import sys
import time

open("argv.txt", "w").write("\n".join(sys.argv[1:]) + "\n")
open("env.txt", "w").write(os.environ.get("CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS", "") + "\n")
received = open("received.jsonl", "a")
plan = json.load(open("plan.json"))
fixture = [line.rstrip("\n") for line in open(plan["fixture"])] if plan.get("fixture") else []
users = []          # the uuids of the user frames received, in order
interrupts = 0
cancels = 0
answering = {}      # "$rid" and "$msg" while a control request is being answered


def substitute(text):
    for fixture_uuid, number in plan.get("subst", {}).items():
        if number <= len(users):
            text = text.replace(fixture_uuid, users[number - 1])
    return text


def literal(value):
    if isinstance(value, str):
        if value in answering:
            return answering[value]
        if value.startswith("$") and value[1:].isdigit() and int(value[1:]) <= len(users):
            return users[int(value[1:]) - 1]
        return value
    if isinstance(value, list):
        return [literal(v) for v in value]
    if isinstance(value, dict):
        return {k: literal(v) for k, v in value.items()}
    return value


def play(frames, delay=0):
    if delay:
        time.sleep(delay)
    out = []
    for item in frames:
        if isinstance(item, int):
            out.append(substitute(fixture[item]))
        elif isinstance(item, list):
            out.extend(substitute(fixture[i]) for i in range(item[0], item[1]))
        else:
            out.append(json.dumps(literal(item), separators=(",", ":")))
    sys.stdout.write("\n".join(out) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    received.write(raw if raw.endswith("\n") else raw + "\n")
    received.flush()
    try:
        frame = json.loads(raw)
    except ValueError:
        continue
    kind = frame.get("type")
    if kind == "user":
        users.append(frame.get("uuid", ""))
        for step in plan["steps"]:
            if step.get("on_user") == len(users):
                play(step["frames"], step.get("delay", 0))
    elif kind == "control_request":
        request = frame.get("request") or {}
        answering = {"$rid": frame.get("request_id", ""), "$msg": request.get("message_uuid", "")}
        if request.get("subtype") == "interrupt":
            interrupts += 1
            for step in plan["steps"]:
                if step.get("on_interrupt") == interrupts:
                    play(step["frames"], step.get("delay", 0))
        elif request.get("subtype") == "cancel_async_message":
            cancels += 1
            for step in plan["steps"]:
                if step.get("on_cancel_async") == cancels:
                    play(step["frames"], step.get("delay", 0))
