#!/bin/bash
# Done-bar 2(b): `lsof -p` is sampled every second across a replayed session of the real agent code and must show
# only read-mode descriptors on Aqua paths and no network descriptors.
#
# The replay runs the agent's headless --test-replay entry point (no app object, no window) against a FAKE HOME that holds
# a fake Aqua log; the real Aqua files are never touched. fs_usage needs root, so sampled lsof plus the source lint
# replace it. Empty lsof output counts as a failure only while the process is alive (kill -0 before and after each read).
# Output lines: AQUA-NONREAD-FDS, NET-FDS, SAMPLES-WHILE-ALIVE (+ evidence lines). Exit 0 only when every check holds,
# which includes AQUA-NONREAD-FDS: 0 and NET-FDS: 0.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENT=""
for candidate in "$REPO/.build/release/clawd-pet-agent" "$REPO/.build/debug/clawd-pet-agent"; do
  if [ -x "$candidate" ]; then AGENT="$candidate"; break; fi
done
[ -n "$AGENT" ] || { echo "build the agent first (swift build)"; exit 2; }
# CLAWD_LSOF is a test seam: a wrapper around the real lsof (the check's own tests add one synthetic descriptor to the agent's listing).
# It cannot make a bad run pass: the positive controls below must still see a real write descriptor and a real listener through it.
LSOF="${CLAWD_LSOF:-/usr/sbin/lsof}"
[ -x "$LSOF" ] || { echo "no lsof at $LSOF"; exit 2; }
DURATION=10
STAGE="$REPO/.build/lsof-test/$(date +%s)-$$"
FAKE="$STAGE/home"
AQUA_LOGS="$FAKE/Library/Logs/Aqua Voice"
AQUA_SUPPORT="$FAKE/Library/Application Support/Aqua Voice"
mkdir -p "$AQUA_LOGS" "$AQUA_SUPPORT" || { echo "cannot create $STAGE"; exit 2; }
LOG="$AQUA_LOGS/main.log"
stamp() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
printf '[%s] [info]  (Main)                                   app.bootstrap arch=arm64 pid=1 platform=darwin\n' "$(stamp)" > "$LOG"
printf '{"useNativeAudio":true,"nativeMicrophone":{"id":"fixture-device"}}\n' > "$AQUA_SUPPORT/settings.json"

children=()
cleanup() { for p in ${children[@]+"${children[@]}"}; do kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# Classifies one `lsof -F pftan` listing: prints "<aqua read-only fds> <aqua non-read fds> <network fds>".
classify() {
  /usr/bin/awk '
    function flush() {
      if (name != "") {
        if (name ~ /Library\/Logs\/Aqua Voice|Library\/Application Support\/Aqua Voice/) { if (access == "r") ar++; else anr++ }
        if (type == "IPv4" || type == "IPv6") net++
      }
      name = ""; access = ""; type = ""
    }
    /^f/ { flush() }
    /^a/ { access = substr($0, 2) }
    /^t/ { type = substr($0, 2) }
    /^n/ { name = substr($0, 2) }
    END { flush(); print ar + 0, anr + 0, net + 0 }
  '
}
sample_of() { "$LSOF" -nP -a -p "$1" -F pftan 2>/dev/null; }

# ---- positive controls: the classifier must see a write-mode Aqua fd and a network fd -------------------------------
bash -c "exec 9>>\"$AQUA_LOGS/control-write.log\"; sleep 6" & writer=$!; children+=("$writer")
/usr/bin/python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); time.sleep(6)' & listener=$!; children+=("$listener")
/bin/sleep 1
read -r _ w_nonread _ <<< "$(sample_of "$writer" | classify)"
read -r _ _ l_net <<< "$(sample_of "$listener" | classify)"
control_ok=1
if [ "${w_nonread:-0}" -ge 1 ]; then echo "LSOF-CONTROL-WRITE: detected"; else echo "LSOF-CONTROL-WRITE: MISSED"; control_ok=0; fi
if [ "${l_net:-0}" -ge 1 ]; then echo "LSOF-CONTROL-NET: detected"; else echo "LSOF-CONTROL-NET: MISSED"; control_ok=0; fi

# ---- before start: nothing holds the fake log -------------------------------------------------------------------------
holders_before="$("$LSOF" -nP "$LOG" 2>/dev/null | /usr/bin/awk 'NR > 1' | wc -l | tr -d ' ')"
echo "HOLDERS-BEFORE-START: $holders_before"

# ---- replay -------------------------------------------------------------------------------------------------------------
HOME="$FAKE" "$AGENT" --test-replay "$DURATION" > "$STAGE/agent.out" 2>&1 &
pid=$!; children+=("$pid")
(
  /bin/sleep 1.5; printf '[%s] [info]  (DictationOrchestrator)                  dictation.start_accepted lease_id=1 provider=online\n' "$(stamp)" >> "$LOG"
  /bin/sleep 1.5; printf '[%s] [info]  (DictationOrchestrator)                  dictation.lock_accepted lease_id=1 provider=online\n' "$(stamp)" >> "$LOG"
  /bin/sleep 1.5; printf '[%s] [info]  (DictationOrchestrator)                  dictation.completed audio_duration_s=3.0 has_audio_data=true lease_id=1 result_source=live session_id=1 text_length=12\n' "$(stamp)" >> "$LOG"
  /bin/sleep 0.6; printf '[%s] [info]  (IPCFloating)                            PASTE_ACK received { timestamp: 1.0, success: true }\n' "$(stamp)" >> "$LOG"
  /bin/sleep 2.5; printf '[%s] [info]  (DictationOrchestrator)                  dictation.start_accepted lease_id=2 provider=online\n' "$(stamp)" >> "$LOG"
  /bin/sleep 0.8; printf '[%s] [info]  (DictationOrchestrator)                  dictation.cancel_accepted lease_id=2\n' "$(stamp)" >> "$LOG"
) &
children+=("$!")

samples=0; read_seen=0; nonread=0; net=0; failures=0
while kill -0 "$pid" 2>/dev/null; do
  out="$(sample_of "$pid")"
  if ! kill -0 "$pid" 2>/dev/null; then
    [ -z "$out" ] && break                       # it exited while lsof ran: this read is not a sample
  fi
  if [ -z "$out" ]; then
    echo "FAIL: empty or denied lsof output while the process was alive"; failures=$((failures + 1)); break
  fi
  read -r r nr n <<< "$(printf '%s\n' "$out" | classify)"
  samples=$((samples + 1))
  [ "$r" -gt "$read_seen" ] && read_seen="$r"
  nonread=$((nonread + nr)); net=$((net + n))
  /bin/sleep 1
done
wait "$pid" 2>/dev/null; agent_rc=$?

# ---- after stop: the process is gone and nothing holds the log ------------------------------------------------------------
gone=0; kill -0 "$pid" 2>/dev/null || gone=1
holders_after="$("$LSOF" -nP "$LOG" 2>/dev/null | /usr/bin/awk 'NR > 1' | wc -l | tr -d ' ')"
echo "HOLDERS-AFTER-STOP: $holders_after"
scenes="$(grep -o 'STATE scene=[a-z]*' "$STAGE/agent.out" | sed 's/STATE scene=//' | tr '\n' ',' | sed 's/,$//')"
echo "REPLAY-SCENES: $scenes"
echo "AQUA-READ-FDS-SEEN: $read_seen"
echo "AQUA-NONREAD-FDS: $nonread"
echo "NET-FDS: $net"
echo "SAMPLES-WHILE-ALIVE: $samples"

ok=1
[ "$failures" -eq 0 ] || ok=0
[ "$control_ok" -eq 1 ] || ok=0
[ "$gone" -eq 1 ] || { echo "FAIL: agent still alive after stop"; ok=0; }
[ "$agent_rc" -eq 0 ] || { echo "FAIL: agent exit status $agent_rc"; ok=0; }
[ "$holders_before" = "0" ] && [ "$holders_after" = "0" ] || { echo "FAIL: a process held the fake log before start or after stop"; ok=0; }
[ "$read_seen" -ge 2 ] || { echo "FAIL: fewer than 2 read-only Aqua descriptors seen: the replay did not exercise the tailer"; ok=0; }
for scene in listening thinking sent interrupted; do
  case ",$scenes," in *",$scene,"*) ;; *) echo "FAIL: the replay never reached $scene"; ok=0 ;; esac
done
[ "$samples" -ge 5 ] || { echo "FAIL: fewer than 5 samples while alive"; ok=0; }
# The point of the check: any non-read descriptor on an Aqua path, or any network descriptor, at any sample, fails the run.
[ "$nonread" -eq 0 ] || { echo "FAIL: $nonread non-read-only descriptor(s) on Aqua paths seen in the samples"; ok=0; }
[ "$net" -eq 0 ] || { echo "FAIL: $net network descriptor(s) seen in the samples"; ok=0; }
[ "$ok" -eq 1 ]
