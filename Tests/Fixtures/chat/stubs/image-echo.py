#!/usr/bin/python3
# Stands in for claude over stream-json: the first user line is written whole to ./received.jsonl (the folder the child runs in), then turn 3 of
# d-image-replay.jsonl is played with its stream events left out. The message's own replay is the received frame with isReplay added, as the
# measured CLI does (it carries the image data back), and the lifecycle and result lines name the received uuid.
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
lines = [json.loads(line) for line in open(os.path.join(here, "..", "d-image-replay.jsonl"), encoding="utf-8")][82:]
lines = [o for o in lines if o.get("type") != "stream_event"]
old = "00000000-0000-4000-8000-000000000086"
for raw in sys.stdin:
    if '"type":"user"' not in raw:
        continue
    frame = json.loads(raw)
    with open("received.jsonl.tmp", "w", encoding="utf-8") as handle:
        handle.write(raw)
    os.replace("received.jsonl.tmp", "received.jsonl")
    out = sys.stdout
    for o in lines:
        if o.get("type") == "user" and o.get("isReplay"):
            replay = dict(frame)
            replay["isReplay"] = True
            out.write(json.dumps(replay, separators=(",", ":")) + "\n")
        else:
            out.write(json.dumps(o, separators=(",", ":")).replace(old, frame["uuid"]) + "\n")
        out.flush()
    break
sys.stdin.read()
