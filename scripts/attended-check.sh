#!/bin/bash
# attended-check.sh: the attended focus check for clawd-pet (spec section 6, done-bar 1(b) as replaced in "r4 change"; round brief r4 B.2).
#
# The user has installed and started the pet. They run `scripts/attended-check.sh --real`, then for N seconds (default 15) clicks and
# drags Clawd a few times while typing in another app. This script only OBSERVES: it never installs, starts, stops or kickstarts
# anything (launchctl is called with `list` only), posts no event, opens no window and requests no Accessibility, Screen Recording or
# other permission. The one helper it starts is the read-only sampler (Sources/ClawdAttendedSampler), which reads the frontmost
# application's pid every 20 ms and, once per read of the stage window, the window server's window list (owner pid, bounds; no titles).
#
# What is observed, and what is not (also written into every evidence file as "scope"):
#   Activation is observed OUTSIDE the agent: the frontmost application's pid, sampled every 20 ms. Key and main status are observed only
#   through the agent's own notifications (FOCUS_VIOLATION lines in agent.log). External observation of the key window is not claimed.
#
# Verdicts (exit 0 PASS, 1 FAIL, 3 NOT RUN; one JSON file under .evidence/ holds every count, the verdict and the reasons). The verdict is a
# function of the measured WINDOW and of what any retained source records; it is decided in this order, and no source is skipped:
#   1. every source is read and scanned first: the ledger (focus-violations.log, read at the window's start and at its end), agent.log and
#      agent.log.1 (their WHOLE retained content), status.json at both ends, the frontmost-pid sampler and the independent lsappinfo looks;
#   2. FAIL   a violation in ANY source, at any time, whatever else is missing: ledger-violation, ledger-torn-line, ledger-write-failed
#             (status.json ledgerFailures, or a FOCUS_VIOLATION_LEDGER_FAILED line), ledger-behind-counter (a BOOT line whose counter= is above
#             the VIOLATION lines before it), focusViolations-nonzero, focus-violation-line, agent-frontmost (the sampler, or any independent
#             look). The log line and the ledger are the primary instruments: the counter can be stale because the agent swallows persist errors;
#   3. NOT RUN  only without a FAIL, any gap in the window's required evidence, every gap named: ledger-not-adopted, ledger-missing,
#             ledger-unreadable, ledger-malformed (a damaged header, or a complete line of an unknown kind), ledger-changed-in-window (the end read
#             does not begin with the bytes of the start read), ledger-final-read-failed, ledger-stale-agent (status.json's pid wrote no BOOT),
#             agent-restarted-in-window (a BOOT line came in during the window), log-unreadable:<file>, and the sampler and window rows below.
#             agent.log rotating is NOT a gap: it is an expected event, the ledger is the window's primary record, and the rotation is only noted
#             (window.log_window_rotated);
#   4. PASS   otherwise. A PASS claims only that during the window the sampled pid was never frontmost, the agent recorded no violation of its
#             own in the ledger, in any retained agent.log file or in status.json, the ledger was read intact at both ends, and no retained
#             source holds a violation from any time. It never says "since install".
# The report carries a separate HISTORY line ("since ledger birth <date> (how=...): complete | incomplete (<reasons>)"). "complete" is a structural
# observation of the retained records, not a claim of uninterrupted coverage, and the line never changes the verdict. The install-time proof of
# the logs (`clawd-pet install` records `logbase <path> absent|<bytes> <sha256>` in the manifest) is supporting detail of that report.
#
# "The panel" below is the agent's STAGE window: the largest on-screen window of the agent's pid (ck_panel_of_pid). Since Sprint 4c the pet
# is two windows, the stage window (the fixed canvas Clawd, the bubble and the costume are drawn on; it never takes a click) and a smaller
# body window (Clawd's body, the only one that takes clicks). Both follow a drag; the stage window is the one read, and its SIZE changes
# when a motion needs more room (a drop after a drag plays A3, which makes it 3 units taller for 1.75 to 1.92 s).
#
# The observation window is the SAMPLED window. It opens when the sampler has written its first sample: only then does the script record
# agent.log's byte size and inode, agent.log.1, the stage window's origin and size (CGWindowList) and status.json's counters. It keeps
# sampling for 1 s after the last window INPUT line, then freezes the end facts (agent.log's size and inode, the stage window, the counters,
# the agent's pid) while the sampler is still running, and only then stops the sampler. INPUT lines count only if they are bytes appended
# between those two offsets: an event before the first sample or after the frozen end never counts toward a PASS.
# A rotation of agent.log is never a gap, and the retained files are read across it (what the log alone would lose to a rotation is the one case the
# ledger exists for: a violation that only a log line recorded and that rotated away before it was read stays a stated limit): the rotated file (agent.log.1 now, identified by the inode agent.log had at
# the start) is read for the window's INPUT lines, both retained files are scanned whole, and a FOCUS_VIOLATION line in either is a FAIL. That holds for a rotation anywhere between the start of the window
# and the end of the analysis, not only inside the window: the log is read after the end facts are frozen and the sampler is stopped, so
# agent.log is compared with its start inode when it is read as well (a rotation after the freeze counts as ROTATED, a note and not a gap), and the
# reads of one analysis run between two looks at the log generation (agent.log's inode, agent.log.1's signature): when they differ, a
# rotation fell between two of the reads, and the whole analysis is done again (at most LOG_READ_TRIES times; the last pass stands). A run that never
# opened its window (preflight failed) still reads the ledger, status.json and both retained logs before it reports: a violation any of them records is a FAIL.
# Sampler freshness is proved by behavior, not by reading the sampler's source: at the start and at the end of the window, and every
# LOOK_EVERY_TICKS-th poll (about 0.2 s) inside it, the frontmost pid the sampler last reported must equal the one `lsappinfo` reports
# (the system's own answer, an independent read that needs no permission). A mismatch, or an unreadable answer, is NOT RUN
# (sampler-stale / sampler-freshness-unproven) at the two ends at once, and inside the window when it lasts STALE_LOOKS looks in a row (a
# sampler one tick behind a real switch disagrees for one look at most): a cached or frozen value cannot pass as "the agent was never
# frontmost", also when the real frontmost went A -> agent -> A between two end checks that both match. The tolerance is for a pid that is
# NOT the agent's: a look that names the agent's pid is a focus violation seen directly (a second instrument, not a freshness question),
# so it is a FAIL at once, tolerated for no count of looks. The looks do not stop when the end facts are collected: the end read of the
# stage window (up to 3 s of re-reads, more under load) is looked at before its first read, after every read and between two reads, so the
# looks cover the time from the start of the window to the last end check at about the look interval (0.2 s), or one read of the window
# list when that is longer. What stays unseen: a switch to the agent that begins and ends between two looks, or inside one window-list
# read, while the sampler also misses it.
# NOT RUN reasons: not-installed, not-loaded, status-unreadable, sampler-missing, sampler-failed, window-lister-failed, panel-not-found,
#   agent-pid-changed, frontmost-read-failed, sampler-gap (> 50 ms between two samples), sampler-stalled,
#   sampler-stale (the sampler's frontmost pid differs from lsappinfo's, at an end or STALE_LOOKS looks in a row inside the window),
#   sampler-freshness-unproven (lsappinfo gave no pid, at an end or STALE_LOOKS looks in a row inside the window),
#   look-gap (more than LOOK_GAP_MAX_MS from the window's start to the first look that saw the frontmost app, between two such looks, or from
#   the last one to the end: a slow window-list read, status read or look),
#   frontmost-changed (to any app other than the agent: the user switched apps, so the test condition broke; retry), display-changed
#   (displayChangeCount differs between the start and its read AFTER the last stage-window read of the end),
#   the ledger rows above (a MENU run also has menu-log-gap: a generation of agent.log the window spans was rotated away before its lines were read; one rotation is not a gap),
#   too-few-mousedowns (< 3 INPUT kind=mouseDown), no-drag-sequence (no ordered down, drag, up),
#   panel-not-moved (the stage window's origin moved < 3 pt between window start and end), scene-changed (the stage window's size differs
#   between the two reads, also after a 3 s re-read grace: the longest drop motion lasts 1.92 s), interrupted.
# A completed drag is the ordered sequence down, at least one drag, up in the window's INPUT lines AND an on-screen origin move of at
# least 3 pt read at equal stage window size. With equal sizes the clamp in AgentRuntime.swift depends only on the in-memory position, which
# changes only in the drag branch past 3 pt; state.json is not used, because a failed save at an earlier mouseUp (`try?`) can make the
# saved position differ without a drag in this window.
#
# Real mode needs the flag `--real`; without it (and outside a sandbox run) the script refuses with 64 before reading anything. Tests run
# it in a sandbox with every external effect stubbed (see check-common.sh). Seams: CLAWD_ATTENDED_SANDBOX, CLAWD_LAUNCHCTL,
# CLAWD_ATTENDED_SAMPLER (a stub of the helper's `sample` and `windows` commands), CLAWD_ATTENDED_LSAPPINFO (a stub of lsappinfo's
# `front` and `info -only pid` answers), CLAWD_ATTENDED_COUNTDOWN_STEP_S. Every call of lsappinfo carries the variable
# CLAWD_LSAPPINFO_CALLER (proof: the checks at the two ends; window-poll: the looks inside the window; end-read-poll: the looks during the
# end read of the stage window); the real lsappinfo ignores it, and the stub counts the three kinds of call apart, so a test can put an
# event at "the first call of the end check" however many looks the window and the end read made.
#
# Menu mode (`--menu`, design-clawd-pet-v2-sM-attended.md v3.2). A separate mode of the same script: the same preflight, sampler (started with
# its `clicks` argument: a listen-only mouse-down monitor that writes CLICK lines on its stderr), independent looks, look-gap, rotation, history
# and focus FAIL rows; its own window end (a settle that waits until every line a click causes has had its time to arrive), its own kinds
# (right-click, hover, item click, outside click, typing while the menu is shown) and rows. The user right-clicks Clawd, hovers, types a word the
# check prints, picks an item, right-clicks again and clicks another application; the check only observes. The agent's MENU and GEOM lines
# are paired with the sampler's CLICK lines by the event time stamp (`et=`), never by time; every opening of the menu has a number (`gen=`)
# that places a line in its interval. The analysis is the Perl program MENU_PERL below, fed with frozen files.
# Seam for tests: CLAWD_ATTENDED_KEYS (a stub that prints the lines the user would type).
#
# Usage: scripts/attended-check.sh --real [--menu] [--seconds N]   (menu mode: N defaults to 60)
# `source` this file to get the functions without running anything.

set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK_REPO="$REPO"
. "$REPO/scripts/check-common.sh"

LABEL="com.tomtim.clawd-pet"
DEFAULT_SECONDS=15
SAMPLE_INTERVAL_MS=20
MAX_GAP_MS=50
QUIET_AFTER_INPUT_MS=1000
MIN_MOUSE_DOWNS=3
MIN_MOVE_PT=3
GRACE_RE_READS=15   # re-reads of a stage window whose size differs at the end, 0.2 s apart: 3 s, the longest drop motion (1.92 s) with margin
SCOPE="Activation is observed outside the agent (the frontmost application's pid, sampled every 20 ms). Key and main status are observed only through the agent's own notifications (FOCUS_VIOLATION lines in agent.log). External observation of the key window is not claimed."
SCOPE_MENU=" Menu mode: clicks are observed by a listen-only mouse-down monitor in the sampler (no key events, no permission requested); typing by this terminal receiving a word it printed while it saw the menu window before and after the read; landing by the clicked application coming to the front; menu clicks are judged only while Clawd was held still. This run's PASS is not the bubble and stage click-through step of the spec's 7b."
SEAM_VARS="CLAWD_LAUNCHCTL CLAWD_ATTENDED_SAMPLER CLAWD_ATTENDED_LSAPPINFO CLAWD_ATTENDED_COUNTDOWN_STEP_S CLAWD_ATTENDED_KEYS"
DEFAULT_MENU_SECONDS=60
W_MS=2000            # the attacker's bound on a delay of handling an event or of writing its log line (design 4)
STAMP_LAG_MS=100     # a stamp read from the samples is at most two intervals old (design 4)
SETTLE_MS=2000       # deadline A is W_MS + SETTLE_MS after the last click or menu line
PICK_WAIT_MS=17000   # the CLI's lock wait (10 s, bin/clawd-pet:20) and apply wait (2 s, :21), the 140 ms flash, W for the close and W for the line, rounded up
FRESH_RETRIES=5
LOOK_EVERY_TICKS=2  # inside the window, one look at the system's frontmost application per 2 polls of 0.1 s
LOOK_GAP_MAX_MS=2000  # longest time allowed between two independent looks (window and end read); a slow window-list read in between is
                      # time in which a cached sampler hides A -> agent -> A, so a longer gap is NOT RUN (look-gap). Normal: ~0.2 s.
STALE_LOOKS=2       # looks in a row at which the sampler and the system must disagree (or the system be unreadable) before the sampler is called stale
LOG_READ_TRIES=5    # reads of agent.log and agent.log.1 as one generation before a log that keeps rotating makes the verdict NOT RUN

SAMPLER_PID=""; SAMPLER_STARTED=""
WINDOW_RAN=0
MENU_MODE=0
READER_PID=""; READER_STARTED=""; KEYS_SRC=""
POLL_TICK=0; FRESHW_STALE_RUN=0; FRESHW_UNREAD_RUN=0
SECONDS_WINDOW=$DEFAULT_SECONDS

# Facts. Empty means "not measured"; the evidence file writes it as null.
P0=""; P1=""
STATUS_FV0=""; STATUS_FV1=""; STATUS_DC0=""; STATUS_DC1=""
HIST_OK=0; HIST_OFFSET=""; HIST_D_LOG="not checked"; HIST_D_LOG1="not checked"
LOG_S0=""; LOG_I0=""; LOG1_SIG0=""; LOG_S1=""; LOG_I1=""; LOG1_SIG1=""; ROTATED=""; ROT_FILE=""; ROT_NOTE=""; ROT_NOW_I=""; ROT_NOW_L1=""
WIN_T0=""; WIN_T1=""; FRESH0=""; FRESH1=""
FRESHW_LOOKS=""; FRESHW_STALE_MAX=""; FRESHW_UNREAD_MAX=""; FRESHW_DETAIL=""; FRESHW_GAP_MAX_MS=""; FRESHW_LAST_MS=""
LOOK_LOG=""; L_TOTAL=""; L_AGENT=""; L_FIRST=""
PANEL0=""; PANEL1=""; PANEL_MOVED=""; PANEL_MOVED_OK=""; PANEL_SIZE_EQUAL=""
IN_DOWN=""; IN_DRAG=""; IN_UP=""; IN_SEQ=""; FV_WINDOW=""; FV_HISTORY=""
ROT_FV_WINDOW=""; ROT_FV_HISTORY=""
S_COUNT=""; S_FIRST=""; S_LAST=""; S_MAXGAP=""; S_AGENT=""; S_UNREAD=""; S_CHANGES=""; S_STARTPID=""
EVIDENCE_FILE=""; WORK=""; SAMPLES=""; WINDOW_LINES_FILE=""
# Menu mode state (all empty or zero in the default mode).
POLLS_FILE=""; PROMPTS_FILE=""; KEYS_LOG=""; SEED_FILE=""; MENU_WIN_FILE=""; MENU_RESULT_FILE=""; MENU_EVIDENCE=""; MENU_FAILS=""; MENU_NOTRUNS=""
MENU_GAP=""; MENU_LAST_INODE=""; MENU_LAST_RAW=0; MENU_BASE=0; SCAN_HOOK=""
PSIG1=0; PSIG2=0; NOW_ERR_SIZE=""; NOW_KEYS_SIZE=""; MENU_LAST_SIZE=""; MENU_DIRTY=1; KEYS_SIZE=""; CLICKS_SIZE=""; LAST_CLICK_MS=0; PROMPT_N=0; PENDING_WORD=""; PROMPTED_GENS=""
LV_ESTATE=closed; LV_OGEN="-"; LV_OREC="-"; LV_OOFF="-"; LV_MATCHED=0; LV_EARLY=0; LV_MENU_SIG="-"; LV_PEND="-"
COUNTDOWN_EARLY=0; SETTLE_ENDED_BY=""; END_WAIT_POLLS=0; READER_NOTE=""
SETTLE_ANCHOR=""; SETTLE_A_MS=""; SETTLE_PICK_MS="none"; SETTLE_STAMP=""   # the numbers of the last settle test (the evidence)
VERDICT=""; EXIT_CODE=""
START_EPOCH=0
# The ledger and the retained logs (D5). LD0_* is the read at the window's start, LD1_* the read at its end.
LEDGER=""; LEDGER_LISTED=0; LD0_STATE=""; LD1_STATE=""; LD_CONT=unknown; LD_BOOT_IN_WINDOW=0; LD_VIOL_IN_WINDOW=0
LD0_HDR=""; LD1_HDR=""; LD0_VIOL=0; LD1_VIOL=0; LD0_TORN=0; LD1_TORN=0; LD0_UNKNOWN=0; LD1_UNKNOWN=0; LD0_BEHIND=0; LD1_BEHIND=0
LD0_PIDS=""; LD1_PIDS=""; LD0_BOOTS=0; LD1_BOOTS=0; LD0_BORN=""; LD1_BORN=""; LD0_HOW=""; LD1_HOW=""
LD0_SEALED=0; LD1_SEALED=0; LD0_TAILBOOT=0; LD1_TAILBOOT=0
STATUS_PID0=""; STATUS_PID1=""; STATUS_LF0=""; STATUS_LF1=""
FV_RETAINED=""; LF_RETAINED=""; SYNC_RETAINED=""; LOG_GAPS=""; LOGS_SCANNED=0
HIST_REASONS=""; HIST_COMPLETE=0; HIST_BORN=""; HIST_HOW=""; HIST_BOOTS=""; HIST_VIOL=""; HIST_TEXT=""
EPOCH_S=""; EPOCH_E=""

usage() { ck_warn "usage: scripts/attended-check.sh --real [--menu] [--seconds N]   (N is 1 to 600, default $DEFAULT_SECONDS, or $DEFAULT_MENU_SECONDS with --menu)"; }

# ---------------------------------------------------------------------------------------------------------------
# Mode and paths
# ---------------------------------------------------------------------------------------------------------------

resolve_mode() {
  ck_resolve_mode attended-check CLAWD_ATTENDED_SANDBOX .attended-sandbox "$SEAM_VARS" "CLAWD_LAUNCHCTL CLAWD_ATTENDED_SAMPLER CLAWD_ATTENDED_LSAPPINFO" || return $?
  if [ "$CK_SANDBOX_MODE" = 1 ]; then
    LAUNCHCTL="$CLAWD_LAUNCHCTL"
    SAMPLER="$CLAWD_ATTENDED_SAMPLER"
    LSAPPINFO="$CLAWD_ATTENDED_LSAPPINFO"
    STEP_S="$CLAWD_ATTENDED_COUNTDOWN_STEP_S"
    ck_is_number "$STEP_S" || { ck_warn "attended-check: refused: CLAWD_ATTENDED_COUNTDOWN_STEP_S is not a number"; return 64; }
    KEYS_SRC="$CLAWD_ATTENDED_KEYS"
    SCAN_HOOK="${CLAWD_ATTENDED_SCAN_HOOK:-}"
    if [ "$MENU_MODE" = 1 ] && [ ! -x "$KEYS_SRC" ]; then ck_warn "attended-check: refused: seam CLAWD_ATTENDED_KEYS is not an executable file"; return 64; fi
    EVID="$CK_SANDBOX/evidence"
  else
    LAUNCHCTL="/bin/launchctl"
    SAMPLER="$(ck_find_tool clawd-attended-sampler)"
    LSAPPINFO="/usr/bin/lsappinfo"
    STEP_S=1
    EVID="$REPO/.evidence"
    if [ -n "${CLAWD_ATTENDED_SCAN_HOOK:-}" ]; then
      ck_warn "attended-check: refused: CLAWD_ATTENDED_SCAN_HOOK is set but this is not a sandbox run. Test seams never reach the real machine."
      return 64
    fi
  fi
  ROOT="$HOME/Library/Application Support/clawd-pet"
  MANIFEST="$ROOT/manifest"
  STATUS="$ROOT/status.json"
  LOG="$ROOT/agent.log"
  LOG1="$ROOT/agent.log.1"
  LEDGER="$ROOT/focus-violations.log"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# Readers (all read-only)
# ---------------------------------------------------------------------------------------------------------------

# One `launchctl list` call. Sets LOADED (0|1) and the pid (empty when the job has none).
read_agent() {
  local out
  LOADED=0; AGENT_PID=""
  out="$("$LAUNCHCTL" list "$LABEL" 2>/dev/null)" || return 1
  LOADED=1
  AGENT_PID="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/.*"PID" = \([0-9][0-9]*\);.*/\1/p' | head -n 1)"
  return 0
}

status_value() { /usr/bin/plutil -extract "$1" raw -o - "$STATUS" 2>/dev/null; }

# Sets the two status counters at the given slot (0 start, 1 end); returns 1 when either is missing or not a number.
read_status() {
  local fv dc
  fv="$(status_value focusViolations)"; dc="$(status_value displayChangeCount)"
  ck_is_uint "$fv" && ck_is_uint "$dc" || return 1
  if [ "$1" = 0 ]; then STATUS_FV0="$fv"; STATUS_DC0="$dc"; else STATUS_FV1="$fv"; STATUS_DC1="$dc"; fi
  # The optional keys of the ledger build: ledgerFailures (absent in an older build's file) and the writing process's pid.
  fv="$(status_value ledgerFailures)"; dc="$(status_value pid)"
  ck_is_uint "$fv" || fv=""; ck_is_uint "$dc" || dc=""
  if [ "$1" = 0 ]; then STATUS_LF0="$fv"; STATUS_PID0="$dc"; else STATUS_LF1="$fv"; STATUS_PID1="$dc"; fi
  return 0
}

# The first N bytes of a file, hashed.
prefix_hash() { /usr/bin/head -c "$2" "$1" 2>/dev/null | /usr/bin/shasum -a 256 | cut -d' ' -f1; }

# The text after "logbase <path> " on the manifest's one line for <path>; fails unless there is exactly one.
logbase_record() {
  /usr/bin/awk -v key="logbase $1 " 'index($0, key) == 1 { print substr($0, length(key) + 1); n++ } END { exit (n == 1) ? 0 : 1 }' "$MANIFEST"
}

# Proves from the manifest that agent.log and agent.log.1 are the generations install saw. Sets HIST_OK, HIST_OFFSET (the bytes of
# agent.log that predate the install) and one sentence per log. Returns 1 when the since-install history cannot be proved.
prove_history() {
  local rec1 rec2 bytes hash size
  HIST_OK=0; HIST_OFFSET=""
  if [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ] || [ "$(/usr/bin/sed -n 1p "$MANIFEST")" != "schema 1" ] || [ "$(tail -n 1 "$MANIFEST")" != "end" ]; then
    HIST_D_LOG="the manifest is missing or incomplete"; HIST_D_LOG1="the manifest is missing or incomplete"; return 1
  fi
  if ! rec1="$(logbase_record "$LOG")"; then HIST_D_LOG="the manifest has no single logbase record for agent.log (an install from before the record existed?)"; return 1; fi
  if ! rec2="$(logbase_record "$LOG1")"; then HIST_D_LOG1="the manifest has no single logbase record for agent.log.1"; return 1; fi
  # agent.log.1 first: it must still be absent, or hash-equal to its record
  if [ "$rec2" = "absent" ]; then
    if [ -e "$LOG1" ] || [ -L "$LOG1" ]; then HIST_D_LOG1="absent at install, present now (the log rotated since install)"; return 1; fi
    HIST_D_LOG1="absent at install and still absent"
  else
    bytes="${rec2%% *}"; hash="${rec2#* }"
    if ! ck_is_uint "$bytes" || [ "${#hash}" -ne 64 ]; then HIST_D_LOG1="the logbase record is malformed"; return 1; fi
    if [ ! -f "$LOG1" ] || [ -L "$LOG1" ]; then HIST_D_LOG1="recorded at install, not a regular file now"; return 1; fi
    size="$(ck_file_size "$LOG1")"
    if [ "$size" != "$bytes" ] || [ "$(prefix_hash "$LOG1" "$bytes")" != "$hash" ]; then
      HIST_D_LOG1="the content differs from its record (the log rotated since install)"; return 1
    fi
    HIST_D_LOG1="$bytes bytes, sha256 equal to the record"
  fi
  if [ "$rec1" = "absent" ]; then
    HIST_OFFSET=0
    HIST_D_LOG="absent at install: every current line is since install"
  else
    bytes="${rec1%% *}"; hash="${rec1#* }"
    if ! ck_is_uint "$bytes" || [ "${#hash}" -ne 64 ]; then HIST_D_LOG="the logbase record is malformed"; return 1; fi
    if [ ! -f "$LOG" ] || [ -L "$LOG" ]; then HIST_D_LOG="recorded at install, not a regular file now"; return 1; fi
    size="$(ck_file_size "$LOG")"
    if [ "$size" -lt "$bytes" ] || [ "$(prefix_hash "$LOG" "$bytes")" != "$hash" ]; then
      HIST_D_LOG="the first $bytes bytes differ from their record (the log was replaced or rotated since install)"; return 1
    fi
    HIST_OFFSET="$bytes"
    HIST_D_LOG="the first $bytes bytes are sha256-equal to the record; lines after them are since install"
  fi
  HIST_OK=1
  return 0
}

log1_signature() { if [ -e "$LOG1" ] || [ -L "$LOG1" ]; then printf '%s:%s' "$(ck_file_inode "$LOG1")" "$(ck_file_size "$LOG1")"; else printf 'absent'; fi; }

# The last complete sample's uptime in ms (0 when there is none). The final line may be half written, so the one before it is read.
sample_stamp() {
  local line
  line="$(tail -n 2 "$SAMPLES" 2>/dev/null | /usr/bin/sed -n 1p)"
  case "$line" in
    [0-9]*\ [0-9-]*) set -- $line; if ck_is_uint "$1"; then printf '%s' "$1"; return 0; fi ;;
  esac
  printf '0'
}

# The frontmost pid the sampler reported in its last complete sample (empty when there is none).
sample_front() {
  local line
  line="$(tail -n 2 "$SAMPLES" 2>/dev/null | /usr/bin/sed -n 1p)"
  case "$line" in
    [0-9]*\ [0-9-]*) set -- $line; printf '%s' "$2"; return 0 ;;
  esac
  return 1
}

# The frontmost pid according to the system (lsappinfo: `front` names the application, `info -only pid` gives its pid). Empty on failure.
# $1 says who asks (proof: the checks at the two ends, the default; window-poll: a look inside the window; end-read-poll: a look during the
# end read of the stage window). The real lsappinfo ignores the variable; the test stub counts the three kinds of call apart.
system_front() {
  local asn pid caller="${1:-proof}"
  asn="$(CLAWD_LSAPPINFO_CALLER="$caller" "$LSAPPINFO" front 2>/dev/null)" || return 1
  case "$asn" in ASN:*) ;; *) return 1 ;; esac
  pid="$(CLAWD_LSAPPINFO_CALLER="$caller" "$LSAPPINFO" info -only pid "$asn" 2>/dev/null | /usr/bin/sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}

# Keeps the pid the system named at one independent look (lsappinfo), and where the look was taken ($2). Every look is also a second
# instrument for the claim itself: the sampler is one reader of the frontmost application, and a look that names the agent's pid is a
# focus violation observed directly, whatever the sampler printed. The agent's pid at the end is known only at the end, so the pids are
# counted against it when the verdict is made (analyze_looks). Kept in memory: a failed write could silently lose a sighting.
record_look() {
  local now gap
  [ -n "$1" ] || return 0
  LOOK_LOG="$LOOK_LOG$1 $2
"
  # The time since the previous look that saw something (or since the window opened, WIN_T0) is time in which nothing independent saw
  # the frontmost application: it holds every slow window-list read, status read and slow look in between. The longest such stretch is
  # kept for decide() (look-gap). Stamped when the look has returned, so a slow look counts in the stretch that ends with it, and a look
  # that read nothing is no observation.
  if [ -n "$FRESHW_LAST_MS" ]; then
    now="$(ck_now_ms)"; gap=$((now - FRESHW_LAST_MS))
    [ "$gap" -le "${FRESHW_GAP_MAX_MS:-0}" ] || FRESHW_GAP_MAX_MS="$gap"
    FRESHW_LAST_MS="$now"
  fi
}

# Proves the sampler's frontmost value is live: the pid it reports must equal the system's own answer. Up to FRESH_RETRIES looks 100 ms
# apart (an app switch lands between the two reads). $1 says where the proof is taken (start or end). Sets FRESH_RESULT to
# "sampler=<pid> system=<pid>" and returns 0 on a match; returns 1 on a mismatch and 2 when the system's answer could not be read.
prove_fresh() {
  local tries=0 mine theirs
  FRESH_RESULT=""
  while :; do
    mine="$(sample_front)" || mine=""
    theirs="$(system_front)" || theirs=""
    record_look "$theirs" "${1:-proof}"
    FRESH_RESULT="sampler=${mine:-none} system=${theirs:-none}"
    [ -n "$theirs" ] || return 2
    if [ -n "$mine" ] && [ "$mine" = "$theirs" ]; then return 0; fi
    tries=$((tries + 1))
    [ "$tries" -lt "$FRESH_RETRIES" ] || return 1
    sleep 0.1
  done
}

# The number of INPUT lines appended to agent.log after the window's start offset.
window_input_count() { tail -c +"$((LOG_S0 + 1))" "$LOG" 2>/dev/null | /usr/bin/awk '$2 == "INPUT" { n++ } END { print n + 0 }'; }

# Reads the agent's stage window (the "panel"): "x y w h count" of its largest on-screen window, the body window being smaller. Returns 2
# when the lister failed, 3 when there is no such window.
read_panel() {
  local lines panel
  lines="$(ck_windows "$SAMPLER")" || return 2
  panel="$(ck_panel_of_pid "$1" "$lines")"
  [ -n "$panel" ] || return 3
  printf '%s' "$panel"
}

# ---------------------------------------------------------------------------------------------------------------
# The sampler (the only process this script starts)
# ---------------------------------------------------------------------------------------------------------------

start_sampler() {
  if [ "$MENU_MODE" = 1 ]; then
    # `clicks`: the sampler also writes a CLICK line on stderr for every mouse-down (the countdown, the settle and the pick wait come on top of N)
    "$SAMPLER" sample "$((SECONDS_WINDOW + 120))" "$SAMPLE_INTERVAL_MS" clicks > "$SAMPLES" 2> "$WORK/sampler.err" &
  else
    "$SAMPLER" sample "$((SECONDS_WINDOW + 60))" "$SAMPLE_INTERVAL_MS" > "$SAMPLES" 2> "$WORK/sampler.err" &
  fi
  SAMPLER_PID=$!; SAMPLER_STARTED="$SAMPLER_PID"
}

# True while the sampler this script started is still running. The shell's own job table answers, so a pid that was reused after the
# sampler exited can never be mistaken for it. (`jobs -rp` prints one pid per line; with the reader of menu mode running as a second job
# the pids are joined first. ck_kill_job, in check-common.sh, joins them the same way, so it finds either running job.)
sampler_alive() { [ -n "$SAMPLER_PID" ] && case " $(jobs -rp | tr '\n' ' ') " in *" $SAMPLER_PID "*) return 0 ;; esac; return 1; }

# True when the sampler is alive and its clock moved during the next 200 ms: a frozen or dead sampler leaves no gap to find, only silence.
sampler_still_producing() {
  local before
  before="$(sample_stamp)"
  sleep 0.2
  sampler_alive && [ "$(sample_stamp)" -gt "$before" ]
}

# Stops the sampler this script started, and only that: ck_kill_job signals it only while it is a running job of this shell.
stop_sampler() {
  [ -n "$SAMPLER_PID" ] || return 0
  ck_kill_job "$SAMPLER_PID"
  wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
}

# ---------------------------------------------------------------------------------------------------------------
# The focus-violation ledger and the retained logs (attended-history amendment, D5)
# ---------------------------------------------------------------------------------------------------------------

# One read of the ledger (whole file, a symlink is never followed) into $WORK/ledger-r<slot>. Sets LD<slot>_STATE: ok, absent or
# unreadable (anything that is not a regular file that could be read to the end).
ledger_snapshot() {
  local slot="$1" dest="$WORK/ledger-r$1" state
  : > "$dest" 2>/dev/null || true
  if [ -L "$LEDGER" ]; then state=unreadable
  elif [ ! -e "$LEDGER" ]; then state=absent
  elif [ ! -f "$LEDGER" ]; then state=unreadable
  elif /bin/cat "$LEDGER" > "$dest" 2>/dev/null; then state=ok
  else state=unreadable; fi
  if [ "$slot" = 0 ]; then LD0_STATE="$state"; else LD1_STATE="$state"; fi
}

# The classification of one ledger snapshot (D1), as key=value lines. A header is ok only when it is the complete first line; a missing,
# truncated or different header is damage to the ledger as a whole (never a torn event). After a valid header: a complete well-formed
# VIOLATION line is a violation; a complete well-formed BOOT line is a start (its counter= is compared with the VIOLATION lines above it);
# an unterminated tail, or a complete line the newline guard sealed, that is a prefix of a BOOT line is a torn BOOT (no violation); any
# other unterminated line, and any complete line that begins with digits or names VIOLATION, is a torn event; any other complete line is
# an unknown kind (malformed). With a damaged header every complete line is still scanned for VIOLATION.
IFS= read -r -d '' LEDGER_PERL <<'PERL' || true
use strict;
use warnings;
my ($file) = @ARGV;
open(my $fh, '<:raw', $file) or do { print "error=open\n"; exit 0 };
my $all = do { local $/; <$fh> };
close $fh;
$all = '' unless defined $all;
my $HDR  = qr/^LEDGER 1 born=([0-9]+) how=(install|adopt-update|recreate)$/;
my $VIOL = qr/^[0-9]+\.[0-9]+ VIOLATION n=[0-9]+ pid=[0-9]+ trigger=\S+ notification=\S+$/;
my $BOOT = qr/^BOOT [0-9]+\.[0-9]+ pid=([0-9]+) counter=([0-9]+) violations=([0-9]+)$/;

# Is $s a prefix (or all) of a line built from the tokens? A token is ['L', literal], ['S', stamp], ['D', digits] or ['W', words...].
sub prefix_of {
  my ($s, @tok) = @_;
  for my $i (0 .. $#tok) {
    my ($kind, @arg) = @{ $tok[$i] };
    return 1 if $s eq '';
    if ($kind eq 'L') {
      my $lit = $arg[0];
      return 1 if length($s) <= length($lit) && substr($lit, 0, length($s)) eq $s;
      return 0 unless substr($s, 0, length($lit)) eq $lit;
      $s = substr($s, length($lit));
    } elsif ($kind eq 'S') {
      $s =~ /^([0-9]+(?:\.[0-9]*)?)(.*)$/s or return 0;
      my ($t, $rest) = ($1, $2);
      return 1 if $rest eq '';
      return 0 unless $t =~ /^[0-9]+\.[0-9]+$/;
      $s = $rest;
    } elsif ($kind eq 'D') {
      $s =~ /^([0-9]*)(.*)$/s or return 0;
      my ($t, $rest) = ($1, $2);
      return 1 if $rest eq '' ;
      return 0 if $t eq '';
      $s = $rest;
    } else {
      for my $w (@arg) { return 1 if length($s) <= length($w) && substr($w, 0, length($s)) eq $s; }
      return 0;
    }
  }
  return $s eq '' ? 1 : 0;
}
sub boot_prefix { return prefix_of($_[0], ['L', 'BOOT '], ['S'], ['L', ' pid='], ['D'], ['L', ' counter='], ['D'], ['L', ' violations='], ['D']); }
sub header_prefix {
  return prefix_of($_[0], ['L', 'LEDGER 1 born='], ['D'], ['L', ' how='], ['W', 'install', 'adopt-update', 'recreate']);
}

my @parts = split(/\n/, $all, -1);
my $tail = @parts ? pop(@parts) : '';
my ($hdr, $born, $how) = ('missing', '', '');
if (@parts) {
  if ($parts[0] =~ $HDR) { ($hdr, $born, $how) = ('ok', $1, $2); }
  else { $hdr = header_prefix($parts[0]) ? 'partial' : 'bad'; }
} elsif ($tail ne '') {
  $hdr = header_prefix($tail) ? 'partial' : 'bad';
}
my ($nviol, $ntorn, $nunknown, $nboot, $sealed, $behind, $tailboot) = (0, 0, 0, 0, 0, 0, 0);
my (@pids, %seen, @counters);
if ($hdr eq 'ok') {
  my $above = 0;
  for my $l (@parts[1 .. $#parts]) {
    if ($l =~ $VIOL) { $nviol++; $above++; next; }
    if ($l =~ $BOOT) {
      $nboot++;
      push @pids, $1 unless $seen{$1}++;
      $behind++ if $2 > $above;
      next;
    }
    if ($l ne '' && boot_prefix($l)) { $sealed++; next; }
    if ($l =~ /VIOLATION/ || $l =~ /^[0-9]/) { $ntorn++; next; }
    $nunknown++;
  }
  if ($tail ne '') { if (boot_prefix($tail)) { $tailboot = 1; } else { $ntorn++; } }
} else {
  for my $l (@parts) { $nviol++ if $l =~ /VIOLATION/; }
}
print "header=$hdr\nborn=$born\nhow=$how\nviolations=$nviol\ntorn=$ntorn\nunknown=$nunknown\nboots=$nboot\nsealed=$sealed\ntailboot=$tailboot\nbehind=$behind\npids=@pids\n";
PERL

# Parses snapshot <slot> (0 or 1): sets LD<slot>_HDR, _BORN, _HOW, _VIOL, _TORN, _UNKNOWN, _BOOTS, _SEALED, _TAILBOOT, _BEHIND, _PIDS.
ledger_parse() {
  local slot="$1" key value pre="LD$1" got=0
  eval "${pre}_HDR=''; ${pre}_BORN=''; ${pre}_HOW=''; ${pre}_VIOL=0; ${pre}_TORN=0; ${pre}_UNKNOWN=0; ${pre}_BOOTS=0; ${pre}_SEALED=0; ${pre}_TAILBOOT=0; ${pre}_BEHIND=0; ${pre}_PIDS=''"
  eval "[ \"\${${pre}_STATE:-}\" = ok ]" || return 0
  while IFS='=' read -r key value; do
    got=1
    case "$key" in
      header) eval "${pre}_HDR=\$value" ;;
      born) eval "${pre}_BORN=\$value" ;;
      how) eval "${pre}_HOW=\$value" ;;
      violations) eval "${pre}_VIOL=\$value" ;;
      torn) eval "${pre}_TORN=\$value" ;;
      unknown) eval "${pre}_UNKNOWN=\$value" ;;
      boots) eval "${pre}_BOOTS=\$value" ;;
      sealed) eval "${pre}_SEALED=\$value" ;;
      tailboot) eval "${pre}_TAILBOOT=\$value" ;;
      behind) eval "${pre}_BEHIND=\$value" ;;
      pids) eval "${pre}_PIDS=\$value" ;;
    esac
  done < <(/usr/bin/perl -e "$LEDGER_PERL" -- "$WORK/ledger-r$slot" 2>/dev/null)
  # A parser that printed nothing is a failed read of the file, not a clean ledger.
  [ "$got" = 1 ] || eval "${pre}_STATE=unreadable"
}

# True when word $1 is one of the space-separated words of $2.
has_word() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# The ledger facts of the window, from the two snapshots: continuity (R1 begins with exactly the bytes of R0), the BOOT lines that came in
# the window (by file position, never by clock) and whether the running agent wrote its own BOOT. Sets LD_CONT (ok|changed|unknown),
# LD_BOOT_IN_WINDOW, LD_VIOL_IN_WINDOW.
analyze_ledger() {
  local n0 n1
  LD_CONT=unknown; LD_BOOT_IN_WINDOW=0; LD_VIOL_IN_WINDOW=0
  ledger_parse 0
  ledger_parse 1
  [ "${LD0_STATE:-}" = ok ] && [ "${LD1_STATE:-}" = ok ] || return 0
  n0="$(ck_file_size "$WORK/ledger-r0")"; n1="$(ck_file_size "$WORK/ledger-r1")"
  if [ "$n1" -ge "$n0" ] && [ "$(/usr/bin/head -c "$n0" "$WORK/ledger-r1" 2>/dev/null | /usr/bin/shasum -a 256 | cut -d' ' -f1)" = "$(/usr/bin/shasum -a 256 < "$WORK/ledger-r0" | cut -d' ' -f1)" ]; then
    LD_CONT=ok
    set -- $(/usr/bin/tail -c +"$((n0 + 1))" "$WORK/ledger-r1" 2>/dev/null | /usr/bin/awk '/^BOOT / { b++ } / VIOLATION / { v++ } END { print b + 0, v + 0 }')
    LD_BOOT_IN_WINDOW="${1:-0}"; LD_VIOL_IN_WINDOW="${2:-0}"
  else
    LD_CONT=changed
  fi
}

# One read of a retained log into $WORK/scan-<name>; counts its FOCUS_VIOLATION, FOCUS_VIOLATION_LEDGER_FAILED and LEDGER_BOOT_SYNC_FAILED
# lines over the WHOLE retained content (not from an offset, and whether or not the install-time proof held). Returns 1 when the file exists
# and could not be read. A rotation renames agent.log to agent.log.1 before the agent creates the next agent.log, so a file that is gone from
# its name when it is opened is the rotation scheme's doing, not an unreadable file: the open is retried (5 times, 100 ms apart, the retry
# the existence check in scan_logs uses) and read from its new name. Only a file that is still there and cannot be read, or one that stays
# gone, is a failure.
scan_one() {
  local file="$1" copy="$WORK/scan-$2" line tries=0
  while :; do
    scan_seam "$file" "$tries"
    if [ ! -L "$file" ] && [ -f "$file" ] && /bin/cat "$file" > "$copy" 2>/dev/null; then break; fi
    if [ ! -e "$file" ] && [ ! -L "$file" ] && [ "$tries" -lt 5 ]; then tries=$((tries + 1)); sleep 0.1; continue; fi
    return 1
  done
  line="$(/usr/bin/awk '$2 == "FOCUS_VIOLATION" { a++ } $2 == "FOCUS_VIOLATION_LEDGER_FAILED" { b++ } $2 == "LEDGER_BOOT_SYNC_FAILED" { c++ } END { print a + 0, b + 0, c + 0 }' "$copy")" || return 1
  set -- $line
  FV_RETAINED=$((FV_RETAINED + $1)); LF_RETAINED=$((LF_RETAINED + $2)); SYNC_RETAINED=$((SYNC_RETAINED + $3))
  return 0
}

# Test seam (sandbox runs only): runs CLAWD_ATTENDED_SCAN_HOOK with the file and the attempt number between the check that the file exists
# and its open, so a test can rename agent.log at exactly that moment.
scan_seam() { [ -z "$SCAN_HOOK" ] || "$SCAN_HOOK" "$1" "$2" >/dev/null 2>&1 || true; }

# What a reader of the logs sees of their generations: agent.log's inode and agent.log.1's signature. A rotation changes both.
log_generation() { printf '%s|%s' "$(ck_file_inode "$LOG")" "$(log1_signature)"; }

# Both retained logs, agent.log.1 first. Sets FV_RETAINED, LF_RETAINED, SYNC_RETAINED and LOG_GAPS (one "log-unreadable:<file>" per file
# that exists and cannot be read). Rotation is not a gap: agent.log.1 absent is normal; agent.log absent right after a rename is retried
# (5 times, 100 ms apart) and, when it is still absent, is transient if agent.log.1 changed its inode since the end snapshot (a rename
# just happened). A rotation between the reads moves the content that was already read as agent.log into agent.log.1, so the generation
# is compared before and after and both files are read again (LOG_READ_TRIES passes at most, the last pass's gaps stand). The counts are
# the highest any pass read: a violation read in one pass stays evidence even when a later rotation removed its file before the next pass
# (the highest, not the sum, because the content that moved is read again).
scan_logs() {
  local pass=0 before after fv=0 lf=0 sync=0
  while :; do
    before="$(log_generation)"
    scan_logs_once
    if [ "$FV_RETAINED" -gt "$fv" ]; then fv=$FV_RETAINED; fi
    if [ "$LF_RETAINED" -gt "$lf" ]; then lf=$LF_RETAINED; fi
    if [ "$SYNC_RETAINED" -gt "$sync" ]; then sync=$SYNC_RETAINED; fi
    after="$(log_generation)"
    [ "$before" != "$after" ] || break
    pass=$((pass + 1))
    [ "$pass" -lt "$LOG_READ_TRIES" ] || break
  done
  FV_RETAINED=$fv; LF_RETAINED=$lf; SYNC_RETAINED=$sync
}
scan_logs_once() {
  local tries=0 sig_now now_i then_i
  FV_RETAINED=0; LF_RETAINED=0; SYNC_RETAINED=0; LOG_GAPS=""
  if [ -e "$LOG1" ] || [ -L "$LOG1" ]; then
    scan_one "$LOG1" agent.log.1 || LOG_GAPS="$LOG_GAPS${LOG_GAPS:+ }agent.log.1"
  fi
  while [ ! -e "$LOG" ] && [ ! -L "$LOG" ] && [ "$tries" -lt 5 ]; do sleep 0.1; tries=$((tries + 1)); done
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    scan_one "$LOG" agent.log || LOG_GAPS="$LOG_GAPS${LOG_GAPS:+ }agent.log"
  else
    sig_now="$(log1_signature)"
    now_i="${sig_now%%:*}"; then_i="${LOG1_SIG1%%:*}"; [ -n "$LOG1_SIG1" ] || then_i="${LOG1_SIG0%%:*}"
    if [ "$sig_now" = absent ] || [ "$now_i" = "$then_i" ]; then LOG_GAPS="$LOG_GAPS${LOG_GAPS:+ }agent.log"; fi
  fi
}

# The history line (informational; never a verdict input). It reports what the retained records show from the ledger's birth. "Complete"
# is a structural observation: a valid header, one prefix-consistent sequence of well-formed lines, every BOOT counter agreeing with the
# VIOLATION lines above it, and none of the listed reasons. It is not a claim of uninterrupted coverage.
compute_history() {
  local pre state reasons="" born how date text limits broken
  HIST_REASONS=""; HIST_COMPLETE=0; HIST_BORN=""; HIST_HOW=""; HIST_BOOTS=""; HIST_VIOL=""; HIST_TEXT=""
  if [ "${LD1_STATE:-}" = ok ]; then pre=LD1; elif [ "${LD0_STATE:-}" = ok ]; then pre=LD0; else pre=""; fi
  if [ -z "$pre" ]; then
    if [ "${LD0_STATE:-}" = absent ] || [ "${LD1_STATE:-}" = absent ]; then reasons="ledger missing"; else reasons="unreadable"; fi
    HIST_TEXT="since ledger birth: unknown: incomplete ($reasons)"
    HIST_REASONS="$reasons"
    return 0
  fi
  eval "state=\$${pre}_HDR; born=\$${pre}_BORN; how=\$${pre}_HOW; HIST_BOOTS=\$${pre}_BOOTS; HIST_VIOL=\$${pre}_VIOL"
  if [ "$state" != ok ]; then reasons="unreadable"; fi
  [ "$how" != recreate ] || reasons="${reasons:+$reasons, }recreated"
  [ "${LD_CONT:-unknown}" != changed ] || reasons="${reasons:+$reasons, }truncated or rewritten"
  eval "[ \"\${${pre}_BEHIND:-0}\" -gt 0 ]" && reasons="${reasons:+$reasons, }rollback period"
  if [ -n "${STATUS_PID1:-}" ]; then
    eval "has_word \"$STATUS_PID1\" \"\${${pre}_PIDS:-}\"" || reasons="${reasons:+$reasons, }rollback period"
  fi
  eval "[ \"\${${pre}_TAILBOOT:-0}\" -gt 0 ]" && reasons="${reasons:+$reasons, }torn BOOT tail"
  eval "[ \"\${${pre}_SEALED:-0}\" -gt 0 ]" && reasons="${reasons:+$reasons, }sealed torn BOOT"
  eval "broken=\$(( \${${pre}_TORN:-0} + \${${pre}_UNKNOWN:-0} ))"
  [ "$broken" -le 0 ] || reasons="${reasons:+$reasons, }$broken torn or unknown ledger line(s)"
  [ "${SYNC_RETAINED:-0}" -le 0 ] || reasons="${reasons:+$reasons, }boot sync failed"
  # a repeated reason is listed once
  reasons="$(printf '%s' "$reasons" | /usr/bin/awk -F', ' '{ for (i = 1; i <= NF; i++) if (!s[$i]++) printf "%s%s", (n++ ? ", " : ""), $i }')"
  HIST_REASONS="$reasons"; HIST_BORN="$born"; HIST_HOW="$how"
  [ -n "$reasons" ] || HIST_COMPLETE=1
  date="$(/bin/date -r "$born" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)" || date=""
  text="since ledger birth ${date:-$born} (how=$how): $([ "$HIST_COMPLETE" = 1 ] && echo complete || echo "incomplete ($reasons)"); $HIST_BOOTS BOOT lines; $HIST_VIOL VIOLATION lines"
  HIST_TEXT="$text"
}
HIST_LIMITS="This line reports what the retained files show; it is not a proof of absence and it never changes the verdict. It cannot show: a violation that a full disk hid from the ledger, status.json and agent.log together, followed by a crash and a restart with a zero counter; a violation during a rollback to a build that does not know the ledger, with a swallowed status write and a rotated agent.log; a ledger that was truncated back to a complete-line boundary before the window; that every agent start was recorded (a BOOT count is the lines present, and the user's direct use is not an automated instrument)."

# ---------------------------------------------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------------------------------------------

# The sources a run that never opened its window can still read (preflight failed, or the window could not open): the ledger, the status
# counters, and both retained logs. Evidence is collected before any outcome is chosen, so a violation recorded in any of them is a FAIL
# even when status.json is unreadable or the agent was not running. One read of the ledger stands for both ends. The reads are best effort:
# a source that is not there records nothing.
collect_unrun_sources() {
  local v
  mkdir -p "$WORK" 2>/dev/null || return 0
  if [ -f "$MANIFEST" ] && grep -qxF -- "file $LEDGER" "$MANIFEST"; then LEDGER_LISTED=1; fi
  ledger_snapshot 0
  LD1_STATE="$LD0_STATE"
  /bin/cp "$WORK/ledger-r0" "$WORK/ledger-r1" 2>/dev/null || LD1_STATE=unreadable
  analyze_ledger
  v="$(status_value focusViolations)"; if ck_is_uint "$v"; then STATUS_FV0="$v"; fi
  v="$(status_value ledgerFailures)"; if ck_is_uint "$v"; then STATUS_LF0="$v"; fi
  scan_logs
  LOGS_SCANNED=1
}

preflight() {
  local rc
  if [ ! -f "$MANIFEST" ] || [ ! -f "$PLIST" ]; then
    notrun not-installed "no manifest or no LaunchAgent plist: run scripts/install and 'clawd-pet start' yourself first"; return 1
  fi
  if ! read_agent; then notrun not-loaded "launchctl does not list $LABEL: run 'clawd-pet start' first"; return 1; fi
  P0="$AGENT_PID"
  if [ -z "$P0" ]; then notrun not-loaded "$LABEL is loaded but has no running process"; return 1; fi
  if ! read_status 0; then notrun status-unreadable "status.json is missing or lacks focusViolations / displayChangeCount"; return 1; fi
  if [ ! -x "$SAMPLER" ]; then notrun sampler-missing "$SAMPLER is not built: swift build -c release"; return 1; fi
  # The install-time proof of the logs is supporting detail of the history report; it gates nothing.
  prove_history || true
  if grep -qxF -- "file $LEDGER" "$MANIFEST"; then LEDGER_LISTED=1; fi
  return 0
}

# Opens the observation window. It is called when the sampler has produced its first sample, so everything recorded here lies inside the
# sampled time. Returns 1 (and the window does not run) when the panel cannot be found or the status cannot be read.
window_start() {
  local rc
  LOG_S0="$(ck_file_size "$LOG")"; LOG_I0="$(ck_file_inode "$LOG")"; LOG1_SIG0="$(log1_signature)"
  ledger_snapshot 0
  EPOCH_S="$(date +%s)"
  WIN_T0="$(sample_stamp)"
  FRESHW_GAP_MAX_MS=0; FRESHW_LAST_MS="$(ck_now_ms)"   # look-gap: the window opens here, so its first stretch starts here
  prove_history || true
  if ! read_status 0; then notrun status-unreadable "status.json could not be read at the start of the window"; return 1; fi
  PANEL0="$(read_panel "$P0")"; rc=$?
  case "$rc" in
    0) ;;
    2) notrun window-lister-failed "the window list could not be read"; return 1 ;;
    *) notrun panel-not-found "no on-screen window of pid $P0 (is Aqua Voice running? the pet is hidden without it)"; return 1 ;;
  esac
  prove_fresh start; rc=$?; FRESH0="$FRESH_RESULT"
  case "$rc" in
    0) ;;
    2) notrun sampler-freshness-unproven "the system's frontmost application could not be read at the start of the window ($FRESH0)" ;;
    *) notrun sampler-stale "the sampler's frontmost pid differs from the system's at the start of the window ($FRESH0)" ;;
  esac
  return 0
}

run_window() {
  local n sub subs stamp polls frozen prev
  mkdir -p "$WORK" || { notrun sampler-failed "cannot create $WORK"; return 1; }
  : > "$SAMPLES"
  start_sampler
  polls=0
  while [ "$polls" -lt 250 ]; do
    [ "$(sample_stamp)" != 0 ] && break
    sampler_alive || break
    sleep 0.02; polls=$((polls + 1))
  done
  if [ "$(sample_stamp)" = 0 ]; then notrun sampler-failed "the sampler wrote no sample (it exited, or none arrived within 5 s)"; stop_sampler; return 1; fi
  # The window opens now, inside the sampled time (see the header): the start facts are read after the first sample.
  if ! window_start; then stop_sampler; return 1; fi
  WINDOW_RAN=1
  FRESHW_LOOKS=0; FRESHW_STALE_MAX=0; FRESHW_UNREAD_MAX=0

  LAST_SIZE="$LOG_S0"
  LAST_INPUT_N="$(window_input_count)"
  LAST_INPUT_STAMP="$(sample_stamp)"
  if [ "$MENU_MODE" = 1 ]; then run_menu_window; return 0; fi
  ck_say "attended-check: click and drag Clawd a few times while typing in another app; $SECONDS_WINDOW s"
  n="$SECONDS_WINDOW"
  # one poll of agent.log per 0.1 s inside each countdown step
  subs="$(/usr/bin/awk -v s="$STEP_S" 'BEGIN { n = int(s * 10 + 0.5); if (n < 1) n = 1; print n }')"
  while [ "$n" -ge 1 ]; do
    ck_say "attended-check: $n s left"
    sub=0
    while [ "$sub" -lt "$subs" ]; do
      sleep 0.1
      poll_window
      sub=$((sub + 1))
    done
    n=$((n - 1))
  done
  # Keep sampling until 1 s of sampler time has passed since the last window INPUT line. A clock that stops for 2 s, or a wait of
  # 5 minutes, ends it: the sampler is stalled or dead.
  polls=0; frozen=0; prev=-1
  while :; do
    stamp="$(sample_stamp)"
    if [ "$((stamp - LAST_INPUT_STAMP))" -ge "$QUIET_AFTER_INPUT_MS" ]; then break; fi
    if [ "$stamp" = "$prev" ]; then frozen=$((frozen + 1)); else frozen=0; fi
    prev="$stamp"
    polls=$((polls + 1))
    if [ "$frozen" -ge 20 ] || [ "$polls" -ge 3000 ]; then
      notrun sampler-stalled "the sampler's clock stopped before it was 1 s past the last INPUT line"; break
    fi
    sleep 0.1
    poll_window
  done
  # The end facts are frozen here, while the sampler is still running; only afterwards is it stopped.
  collect_end
  # The sampler must still be producing at the end.
  if ! sampler_still_producing; then
    notrun sampler-stalled "the sampler produced no new sample in the last 200 ms of the window"
  fi
  stop_sampler
  return 0
}

# One look at agent.log: when it changed, the number of window INPUT lines is re-counted, and a new one moves the quiet marker.
poll_log() {
  local size count
  size="$(ck_file_size "$LOG")"
  if [ "$size" != "$LAST_SIZE" ]; then
    LAST_SIZE="$size"
    count="$(window_input_count)"
    if [ "$count" != "$LAST_INPUT_N" ]; then LAST_INPUT_N="$count"; LAST_INPUT_STAMP="$(sample_stamp)"; fi
  fi
}

# One poll of the window: the log, and every LOOK_EVERY_TICKS-th time a look at the frontmost application.
poll_window() {
  poll_log
  poll_fresh
}

# Every LOOK_EVERY_TICKS-th poll is a look at the frontmost application (fresh_look).
poll_fresh() {
  POLL_TICK=$((POLL_TICK + 1))
  [ "$((POLL_TICK % LOOK_EVERY_TICKS))" = 0 ] || return 0
  fresh_look window
}

# One look at the system's frontmost application from inside the window ($1 says where: window, or end-read for the read of the stage
# window at the end; it is also the kind of caller the test stub counts): the sampler's last complete sample must name the same pid. One disagreement is the sampler a tick behind a real
# switch (or lsappinfo a tick behind the sampler); STALE_LOOKS in a row are a sampler that has stopped following the system, whatever it
# still prints. The longest run of each kind (disagreement, unreadable) is kept for decide(). A pid that is the agent's is not a
# freshness question at all: record_look keeps it and decide() makes it a FAIL, however many looks agree or disagree.
fresh_look() {
  local mine theirs
  mine="$(sample_front)" || mine=""
  theirs="$(system_front "$1-poll")" || theirs=""
  record_look "$theirs" "$1"
  FRESHW_LOOKS=$((FRESHW_LOOKS + 1))
  if [ -z "$theirs" ]; then
    FRESHW_UNREAD_RUN=$((FRESHW_UNREAD_RUN + 1)); FRESHW_STALE_RUN=0
    [ "$FRESHW_UNREAD_RUN" -le "$FRESHW_UNREAD_MAX" ] || FRESHW_UNREAD_MAX="$FRESHW_UNREAD_RUN"
  elif [ "$mine" != "$theirs" ]; then
    FRESHW_STALE_RUN=$((FRESHW_STALE_RUN + 1)); FRESHW_UNREAD_RUN=0
    if [ "$FRESHW_STALE_RUN" -gt "$FRESHW_STALE_MAX" ]; then FRESHW_STALE_MAX="$FRESHW_STALE_RUN"; FRESHW_DETAIL="sampler=${mine:-none} system=$theirs"; fi
  else
    FRESHW_STALE_RUN=0; FRESHW_UNREAD_RUN=0
  fi
}

# ---------------------------------------------------------------------------------------------------------------
# Menu mode (`--menu`): the window flow, the typing proof and the analysis (design sections 4, 7.2 to 7.5)
# ---------------------------------------------------------------------------------------------------------------

# The Perl program below, with its arguments (key=value words).
menu_perl() { /usr/bin/perl -e "$MENU_PERL" -- "$@"; }

# The files of one menu run, and the seed: the last MENU open/close line and the last GEOM line before the window (the E and D sequences
# start from them).
menu_start() {
  : > "$POLLS_FILE"; : > "$PROMPTS_FILE"; : > "$KEYS_LOG"
  head -c "$LOG_S0" "$LOG" 2>/dev/null | /usr/bin/awk '$2 == "MENU" && ($3 == "open" || $3 == "close") { m = $0 } $2 == "GEOM" { g = $0 } END { if (m != "") print m; if (g != "") print g }' > "$SEED_FILE"
  PSIG1="$WIN_T0"; PSIG2="$WIN_T0"; MENU_LAST_SIZE="$LOG_S0"; MENU_DIRTY=1
  MENU_LAST_INODE="$LOG_I0"; MENU_LAST_RAW="$LOG_S0"; MENU_BASE=0
}

# The lines of the window, in order, from every retained generation of agent.log: the file agent.log was at the start from the start
# offset, then (after a rotation) the file agent.log is at the end up to its end offset. $1 is the file to fill, $2 and $3 the inode and
# the size of agent.log at the end of the window (the frozen facts); the live view passes the current inode and no size (to the end). The generations are found by
# inode, so a rotation after the freeze is followed as well. Sets MENU_GAP to a sentence when a generation the window spans is no longer
# there (rotated away twice, or removed, before it was read); empty when every line of the window was read.
# Bytes of file $1 from byte $2 (1 is the first), at most $3 of them (all when empty).
menu_cut() {
  if [ -n "$3" ]; then tail -c +"$2" "$1" 2>/dev/null | head -c "$3"; else tail -c +"$2" "$1" 2>/dev/null; fi
}
menu_window_lines() {
  local dest="$1" end_i="$2" end_s="$3" cur l1 src
  MENU_GAP=""
  : > "$dest" 2>/dev/null || { MENU_GAP="the window's lines could not be collected ($dest is not writable)"; return 0; }
  cur="$(ck_file_inode "$LOG")"; l1="$(ck_file_inode "$LOG1")"
  if [ "$LOG_I0" = none ]; then
    if [ "$cur" = "$end_i" ]; then menu_cut "$LOG" 1 "$end_s" >> "$dest"; else MENU_GAP="agent.log (inode $end_i at the end of the window) is gone, and no file was there at the start"; fi
  elif [ "$end_i" = "$LOG_I0" ]; then
    src=""
    if [ "$cur" = "$LOG_I0" ]; then src="$LOG"; elif [ "$l1" = "$LOG_I0" ]; then src="$LOG1"; fi
    if [ -z "$src" ]; then MENU_GAP="the file agent.log was at the start of the window (inode $LOG_I0) is gone: it was rotated away before it was read"
    elif [ -z "$end_s" ]; then menu_cut "$src" "$((LOG_S0 + 1))" "" >> "$dest"
    elif [ "$end_s" -gt "$LOG_S0" ]; then menu_cut "$src" "$((LOG_S0 + 1))" "$((end_s - LOG_S0))" >> "$dest"; fi
  else
    if [ "$l1" != "$LOG_I0" ]; then MENU_GAP="the file agent.log was at the start of the window (inode $LOG_I0) is gone: it was rotated away before it was read (agent.log.1 is inode $l1)"
    elif [ "$cur" != "$end_i" ]; then MENU_GAP="the file agent.log was at the end of the window (inode $end_i) is gone: it was rotated away before it was read"
    else
      menu_cut "$LOG1" "$((LOG_S0 + 1))" "" >> "$dest"
      menu_cut "$LOG" 1 "$end_s" >> "$dest"
    fi
  fi
}

# The sampler's last complete stamp (the second-to-last line, as sample_stamp reads it) with one process instead of two.
menu_stamp() {
  local one
  one="$(tail -n 2 "$SAMPLES" 2>/dev/null)"
  set -- $one
  case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# One poll of agent.log for the first-seen record: the size, then the sampler's stamp right after the read. A line first seen at this poll was
# complete before this stamp + STAMP_LAG_MS and was not complete at the previous poll's read, which came after the stamp of two polls ago.
# The sizes of the three files the menu loop watches (agent.log, the sampler's stderr, the typed words) come from one stat.
menu_note_poll() {
  local sizes size ino sig add
  sizes="$(/usr/bin/stat -f '%z %i' "$LOG" "$WORK/sampler.err" "$KEYS_LOG" 2>/dev/null)"
  set -- $sizes
  if [ "$#" = 6 ]; then size="$1"; ino="$2"; NOW_ERR_SIZE="$3"; NOW_KEYS_SIZE="$5"
  else size="$(ck_file_size "$LOG")"; ino="$(ck_file_inode "$LOG")"; NOW_ERR_SIZE="$(ck_file_size "$WORK/sampler.err")"; NOW_KEYS_SIZE="$(ck_file_size "$KEYS_LOG")"; fi
  sig="$(menu_stamp)"
  # The sizes the analysis compares a line's end offset with run on across a rotation: the size of the file that was rotated away is added to
  # the size of the new agent.log, as the window's lines are laid end to end (menu_window_lines).
  if [ "$MENU_LAST_INODE" = none ]; then MENU_LAST_INODE="$ino"
  elif [ "$ino" != none ] && [ "$ino" != "$MENU_LAST_INODE" ]; then
    if [ "$(ck_file_inode "$LOG1")" = "$MENU_LAST_INODE" ]; then add="$(ck_file_size "$LOG1")"; else add="$MENU_LAST_RAW"; fi
    MENU_BASE=$((MENU_BASE + add)); MENU_LAST_INODE="$ino"
  fi
  [ "$ino" = none ] || MENU_LAST_RAW="$size"
  size=$((MENU_BASE + size))
  if [ "$size" != "$MENU_LAST_SIZE" ]; then
    MENU_LAST_SIZE="$size"; MENU_DIRTY=1
    printf '%s %s %s\n' "$size" "$PSIG2" "$sig" >> "$POLLS_FILE"
  fi
  PSIG2="$PSIG1"; PSIG1="$sig"
}

# The live view of the window (Perl, mode=live): the final E state, the open one's declared rectangle, the early end of the countdown, the
# first-seen stamp of the last MENU or et-bearing line and the anchor of the pick wait.
menu_live() {
  local key value
  menu_window_lines "$MENU_WIN_FILE" "$(ck_file_inode "$LOG")" ""
  while IFS='=' read -r key value; do
    case "$key" in
      estate) LV_ESTATE="$value" ;;
      ogen) LV_OGEN="$value" ;;
      orect) LV_OREC="$value" ;;
      ooff) LV_OOFF="$value" ;;
      matched) LV_MATCHED="$value" ;;
      early) LV_EARLY="$value" ;;
      menu_sig) LV_MENU_SIG="$value" ;;
      pend_anchor) LV_PEND="$value" ;;
    esac
  done < <(menu_perl mode=live "log=$MENU_WIN_FILE" "s0=$LOG_S0" "seed=$SEED_FILE" "polls=$POLLS_FILE" "prompts=$PROMPTS_FILE" "keys=$KEYS_LOG" "lastsig=$PSIG1")
}

# The t of the last CLICK line the sampler wrote, in ms.
menu_last_click() {
  if [ "$NOW_ERR_SIZE" != "$CLICKS_SIZE" ]; then
    CLICKS_SIZE="$NOW_ERR_SIZE"
    LAST_CLICK_MS="$(/usr/bin/awk '$1 == "CLICK" { for (i = 2; i <= NF; i++) if ($i ~ /^t=/) t = substr($i, 3) } END { printf "%d", t * 1000 + 0.5 }' "$WORK/sampler.err")"
  fi
}

# Four lowercase letters from /dev/urandom, new for every prompt.
make_word() {
  local b word="" c
  for b in $(od -An -N4 -tu1 /dev/urandom); do
    c=$((b % 26))
    word="$word$(printf "\\$(printf '%03o' $((97 + c)))")"
  done
  printf '%s' "$word"
}

# The typing prompt (7.4). A poll that sees the menu shown for an opening that has no prompt yet reads the window list (X1); when the menu
# window is on it, the check prints a fresh word and records the prompt and the list. The menu window is seen on screen BEFORE the keystrokes.
menu_prompt() {
  local sx1 list ow oh match word n
  [ -n "$READER_PID" ] || return 0
  [ "$LV_ESTATE" = "open" ] || return 0
  [ "$LV_MATCHED" = 0 ] || return 0
  [ "$LV_OGEN" != "-" ] && [ "$LV_OREC" != "-" ] || return 0
  case " $PROMPTED_GENS " in *" $LV_OGEN "*) return 0 ;; esac
  ow="$(printf '%s' "$LV_OREC" | cut -d, -f3)"; oh="$(printf '%s' "$LV_OREC" | cut -d, -f4)"
  sx1="$(menu_stamp)"
  list="$(ck_windows "$SAMPLER")" || return 0
  match="$(printf '%s\n' "$list" | /usr/bin/awk -v pid="$P0" -v w="$ow" -v h="$oh" '$1 == "WINDOW" && $2 == pid && $4 == 1 { dw = $7 - w; dh = $8 - h; if (dw < 0) dw = -dw; if (dh < 0) dh = -dh; if (dw <= 0.5 && dh <= 0.5) { print $7 "x" $8; exit } }')"
  [ -n "$match" ] || return 0
  n=$((PROMPT_N + 1)); word="$(make_word)"
  printf '%s\n' "$list" > "$WORK/x1-$n.txt"
  printf 'PROMPT %s %s sigma=%s open=%s gen=%s wh=%s\n' "$n" "$word" "$sx1" "${LV_OOFF:--}" "$LV_OGEN" "$match" >> "$PROMPTS_FILE"
  PROMPT_N="$n"; PENDING_WORD="$word"; PROMPTED_GENS="$PROMPTED_GENS $LV_OGEN"
  ck_say "attended-check: type $word and press Return (keep the pointer on the menu; do not click this terminal)"
}

# The reader (7.4): for each line, the last word if it is 4 lowercase letters (nothing else is stored), then the window list (X2) and the
# stamp after it. Runs as a background job; reads standard input.
reader_loop() {
  local line word list wins sx
  while IFS= read -r line; do
    line="${line%"${line##*[![:space:]]}"}"
    word="${line##* }"
    case "$word" in [a-z][a-z][a-z][a-z]) ;; *) continue ;; esac
    list="$(ck_windows "$SAMPLER")" || list=""
    sx="$(sample_stamp)"
    wins="$(printf '%s\n' "$list" | /usr/bin/awk -v pid="$P0" '$1 == "WINDOW" && $2 == pid && $4 == 1 { printf "%s%sx%s", sep, $7, $8; sep = "," }')"
    printf 'KEY %s sigma=%s menu_windows=%s\n' "$word" "$sx" "$wins" >> "$KEYS_LOG"
  done
}

# Real mode: the reader takes the terminal (fd 3, duplicated from stdin at the start). A sandbox run takes the lines of the stub the seam names.
start_reader() {
  READER_PID=""
  # The job gives up the script's traps first: a subshell that inherited the TERM trap would not act on a TERM until its pipeline or its
  # read had finished (and, reading the terminal, would run the script's own finish).
  if [ "$CK_SANDBOX_MODE" = 1 ]; then
    ( trap - INT TERM HUP; CLAWD_ATTENDED_WORK="$WORK" "$KEYS_SRC" 2>/dev/null | reader_loop ) &
    READER_PID=$!; READER_STARTED="$READER_PID"
  elif [ -t 3 ]; then
    ( trap - INT TERM HUP; reader_loop <&3 ) &
    READER_PID=$!; READER_STARTED="$READER_PID"
  else
    READER_NOTE="standard input is not a terminal: no word can be read"
  fi
}

stop_reader() {
  [ -n "$READER_PID" ] || return 0
  ck_kill_job "$READER_PID"
  wait "$READER_PID" 2>/dev/null
  READER_PID=""
}

# One poll in menu mode: the first-seen record, the usual poll (the log and a look), the live view when something changed, the prompt.
menu_poll_window() {
  menu_note_poll
  poll_window
  if [ "$MENU_DIRTY" = 1 ] || [ "$NOW_KEYS_SIZE" != "$KEYS_SIZE" ]; then
    MENU_DIRTY=0; KEYS_SIZE="$NOW_KEYS_SIZE"
    menu_live
  fi
  menu_prompt
}

# Deadline A and the pick wait (7.3). $1 is the sampler's stamp now.
menu_quiet() {
  local stamp="$1" anchor="$WIN_T0"
  menu_last_click
  [ "$LAST_CLICK_MS" -le "$anchor" ] || anchor="$LAST_CLICK_MS"
  case "$LV_MENU_SIG" in ''|-) ;; *) [ "$LV_MENU_SIG" -le "$anchor" ] || anchor="$LV_MENU_SIG" ;; esac
  SETTLE_ANCHOR="$anchor"; SETTLE_A_MS="$((anchor + W_MS + SETTLE_MS))"; SETTLE_STAMP="$stamp"
  case "$LV_PEND" in ''|-) SETTLE_PICK_MS="none" ;; *) SETTLE_PICK_MS="$((LV_PEND + PICK_WAIT_MS))" ;; esac
  [ "$((stamp - anchor))" -ge "$((W_MS + SETTLE_MS))" ] || return 1
  case "$LV_PEND" in ''|-) SETTLE_ENDED_BY="deadline-A"; return 0 ;; esac
  [ "$((stamp - LV_PEND))" -ge "$PICK_WAIT_MS" ] || return 1
  SETTLE_ENDED_BY="pick-wait"
  return 0
}

# The settle: keep sampling, polling and looking until every line a click can cause has had its time to arrive.
menu_settle() {
  local stamp prev=-1 frozen=0 polls=0
  while :; do
    stamp="$PSIG1"
    if menu_quiet "$stamp"; then break; fi
    if [ "$stamp" = "$prev" ]; then frozen=$((frozen + 1)); else frozen=0; fi
    prev="$stamp"
    polls=$((polls + 1))
    if [ "$frozen" -ge 20 ] || [ "$polls" -ge 3000 ]; then
      notrun sampler-stalled "the sampler's clock stopped before the settle of the menu window ended"; SETTLE_ENDED_BY="sampler-stalled"; break
    fi
    sleep 0.1
    menu_poll_window
  done
}

# After the settle, while the menu is still shown, wait for its 8 s away close (10 x STEP_S s); a close that arrives restarts deadline A.
menu_end_wait() {
  local tries=0 limit
  limit="$(/usr/bin/awk -v s="$STEP_S" 'BEGIN { n = int(s * 100 + 0.5); if (n < 1) n = 1; print n }')"
  while [ "$LV_ESTATE" = "open" ] && [ "$tries" -lt "$limit" ]; do
    sleep 0.1
    menu_poll_window
    tries=$((tries + 1))
    if [ "$LV_ESTATE" != "open" ]; then menu_settle; fi
  done
}

# The window of a menu run: the user's instructions, the countdown (which stops early once the whole path has been seen), the settle, the end wait.
run_menu_window() {
  local n sub subs
  menu_start
  ck_say "attended-check: menu check, about 30 s. Do these in order:"
  ck_say "  1. Leave this terminal in front. Do not click it again until the check ends (a click on it closes the menu as an outside click)."
  ck_say "  2. Right-click Clawd. The menu opens, and this terminal prints a 4-letter word."
  ck_say "  3. Move the pointer over two different items, and leave it on the menu."
  ck_say "  4. Type the printed word and press Return. The keys go to this terminal because it is in front; do not click it first."
  ck_say "  5. Click the chip that is already highlighted in the Walk row (the value stays the same). The menu closes."
  ck_say "  6. Right-click Clawd again."
  ck_say "  7. Click once (not a double-click) on the desktop or a window of another app that is not in front (not this terminal), away from Clawd and the menu. That app comes to the front; the check ends a few seconds later."
  ck_say "  Any other click (this terminal while no menu is shown, the menu bar, a second click) ends the run NOT RUN click-unaccounted; run it again."
  start_reader
  [ -z "$READER_NOTE" ] || ck_say "attended-check: $READER_NOTE"
  subs="$(/usr/bin/awk -v s="$STEP_S" 'BEGIN { n = int(s * 10 + 0.5); if (n < 1) n = 1; print n }')"
  n="$SECONDS_WINDOW"
  while [ "$n" -ge 1 ]; do
    if [ -n "$PENDING_WORD" ] && [ "$LV_MATCHED" = 0 ]; then ck_say "attended-check: $n s left; type $PENDING_WORD and Return"; else ck_say "attended-check: $n s left"; fi
    sub=0
    while [ "$sub" -lt "$subs" ]; do
      sleep 0.1
      menu_poll_window
      if [ "$LV_EARLY" = 1 ]; then COUNTDOWN_EARLY=1; break 2; fi
      sub=$((sub + 1))
    done
    n=$((n - 1))
  done
  menu_settle
  menu_end_wait
  collect_end
  if ! sampler_still_producing; then
    notrun sampler-stalled "the sampler produced no new sample in the last 200 ms of the window"
  fi
  stop_reader
  stop_sampler
}

# The analysis of a menu run (Perl, mode=analyze) on the frozen files. Its FAIL and NOTRUN rows are kept for decide().
analyze_menu() {
  local kind code detail endwin=0 before after
  MENU_FAILS=""; MENU_NOTRUNS=""; MENU_EVIDENCE=""
  [ -z "$PANEL1" ] || { set -- $PANEL1; endwin="${5:-0}"; }
  # The rows are evaluated from the window's lines in every retained generation (menu_window_lines), read as one generation: a rotation
  # during the reads sends them round again. Only a generation that is truly gone leaves a gap.
  local tries=0
  while :; do
    before="$(log_generation)"
    menu_window_lines "$MENU_WIN_FILE" "$LOG_I1" "$LOG_S1"
    after="$(log_generation)"
    [ "$before" = "$after" ] && break
    tries=$((tries + 1))
    if [ "$tries" -ge "$LOG_READ_TRIES" ]; then MENU_GAP="agent.log was replaced again while each of $LOG_READ_TRIES reads of the window's lines ran, so they were never read as one generation"; break; fi
  done
  menu_perl mode=analyze "log=$MENU_WIN_FILE" "s0=$LOG_S0" "seed=$SEED_FILE" "clicks=$WORK/sampler.err" "samples=$SAMPLES" "polls=$POLLS_FILE" "prompts=$PROMPTS_FILE" \
    "keys=$KEYS_LOG" "x1dir=$WORK" "p0=$P0" "p1=${P1:-$P0}" "endwin=$endwin" "lastsig=${WIN_T1:-0}" "rotated=$([ -n "$MENU_GAP" ] && echo 1 || echo 0)" "early=$COUNTDOWN_EARLY" \
    "settle=$SETTLE_ENDED_BY" "settle_anchor=$SETTLE_ANCHOR" "settle_a=$SETTLE_A_MS" "settle_pick=$SETTLE_PICK_MS" "settle_stamp=$SETTLE_STAMP" \
    "winend=${WIN_T1:-0}" "reader=$READER_NOTE" > "$MENU_RESULT_FILE" 2> "$WORK/menu-analyze.err"
  while IFS=$'\t' read -r kind code detail; do
    case "$kind" in
      FAIL) MENU_FAILS="$MENU_FAILS${MENU_FAILS:+
}$code|$detail" ;;
      NOTRUN) MENU_NOTRUNS="$MENU_NOTRUNS${MENU_NOTRUNS:+
}$code|$detail" ;;
      EVIDENCE) MENU_EVIDENCE="$code" ;;
    esac
  done < "$MENU_RESULT_FILE"
  if [ -z "$MENU_EVIDENCE" ]; then
    MENU_NOTRUNS="$MENU_NOTRUNS${MENU_NOTRUNS:+
}menu-analysis-failed|the menu analysis produced no result ($(head -c 300 "$WORK/menu-analyze.err" 2>/dev/null | tr '\n' ' '))"
  fi
}

# The rows of the analysis, as FAIL or NOT RUN reasons ($1 says which).
menu_add_rows() {
  local list l
  if [ "$1" = FAIL ]; then list="$MENU_FAILS"; else list="$MENU_NOTRUNS"; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$1" = FAIL ]; then fail "${l%%|*}" "${l#*|}"; else notrun "${l%%|*}" "${l#*|}"; fi
  done < <(printf '%s\n' "$list")
}

# Runs inside the sampled window (before the sampler is stopped). The stage window comes first, and the status counters and the log offset
# after it: an event that moved the window before its last read is then always an event that lies inside the counted INPUT bytes, and a
# display change that moved it is always a change of displayChangeCount that this read sees (the re-read of the window below can take up
# to 3 s; a counter read before it would pair the old count with the new position). The start does the reverse (the counters and the offset
# first, the window after them) for the same reason.
collect_end() {
  local rc tries gap
  read_agent || true
  P1="$AGENT_PID"
  # The stage window at the end; a different size is re-read for up to GRACE_RE_READS x 0.2 s = 3 s (a motion that needs more room makes
  # the window taller while it plays: the drop after a drag, which can still be playing when the window ends 1 s after the last INPUT line,
  # lasts up to 1.92 s). A size that never returns is NOT RUN, scene-changed.
  # The looks at the frontmost application go on through all of it: one before the first read, one after every read (a read can be slow
  # on a loaded machine) and one in the middle of each wait between two reads. Were they to stop here, this stretch (3 s and more) is
  # one in which a cached sampler hides the real frontmost app going A -> agent -> A, and the checks at the two ends both match.
  fresh_look end-read
  tries=0
  while :; do
    PANEL1="$(read_panel "${P1:-$P0}")"; rc=$?
    fresh_look end-read
    [ "$rc" -eq 0 ] || break
    set -- $PANEL0; local w0="$3" h0="$4"
    set -- $PANEL1; local w1="$3" h1="$4"
    if [ "$w0" = "$w1" ] && [ "$h0" = "$h1" ]; then break; fi
    tries=$((tries + 1))
    [ "$tries" -le "$GRACE_RE_READS" ] || break
    sleep 0.1
    fresh_look end-read
    sleep 0.1
  done
  case "$rc" in
    0) ;;
    2) notrun window-lister-failed "the window list could not be read at the end"; PANEL1="" ;;
    *) notrun panel-not-found "no on-screen window of the agent at the end of the window"; PANEL1="" ;;
  esac
  read_status 1 || notrun status-unreadable "status.json could not be read at the end of the window"
  LOG_S1="$(ck_file_size "$LOG")"; LOG_I1="$(ck_file_inode "$LOG")"; LOG1_SIG1="$(log1_signature)"
  WIN_T1="$(sample_stamp)"
  prove_fresh end; rc=$?; FRESH1="$FRESH_RESULT"
  case "$rc" in
    0) ;;
    2) notrun sampler-freshness-unproven "the system's frontmost application could not be read at the end of the window ($FRESH1)" ;;
    *) notrun sampler-stale "the sampler's frontmost pid differs from the system's at the end of the window ($FRESH1)" ;;
  esac
  ledger_snapshot 1
  EPOCH_E="$(date +%s)"
  # look-gap at the end: from the last look that saw something to now (when the end proof read nothing, this is that stretch).
  if [ -n "$FRESHW_LAST_MS" ]; then
    gap=$(( $(ck_now_ms) - FRESHW_LAST_MS )); [ "$gap" -le "${FRESHW_GAP_MAX_MS:-0}" ] || FRESHW_GAP_MAX_MS="$gap"
  fi
}

# How many independent looks named the agent's pid (P0, or P1 when its pid changed), out of how many, and where the first one was.
analyze_looks() {
  local line
  line="$(printf '%s' "$LOOK_LOG" | /usr/bin/awk -v a0="$P0" -v a1="${P1:-}" '
    NF >= 2 { n++ }
    NF >= 2 && ((a0 != "" && $1 == a0) || (a1 != "" && $1 == a1)) { hits++; if (first == "") first = $2 }
    END { printf "%d %d %s\n", n, hits, (first == "") ? "-" : first }')"
  set -- $line
  L_TOTAL="$1"; L_AGENT="$2"; L_FIRST="$3"
}

# Whether the jobs this script started are still running at the first read of the samples: one line per job, `<name> <pid>
# running|stopped`, in $WORK/jobs-at-sample-read. The shell's table of running jobs answers (no signal; the table of all jobs is not used
# because bash keeps a job it has already waited for in it while a SIGINT trap runs).
note_jobs_at_sample_read() {
  local name pid state table
  : > "$WORK/jobs-at-sample-read" 2>/dev/null || return 0
  table=" $(jobs -rp | tr '\n' ' ') "
  for name in sampler reader; do
    if [ "$name" = sampler ]; then pid="$SAMPLER_STARTED"; else pid="$READER_STARTED"; fi
    [ -n "$pid" ] || continue
    case "$table" in *" $pid "*) state=running ;; *) state=stopped ;; esac
    printf '%s %s %s\n' "$name" "$pid" "$state" >> "$WORK/jobs-at-sample-read"
  done
}

analyze_samples() {
  local line
  note_jobs_at_sample_read
  if [ ! -s "$SAMPLES" ]; then return 0; fi
  line="$(/usr/bin/awk -v a0="$P0" -v a1="${P1:-$P0}" '
    $0 ~ /^[0-9]+ -?[0-9]+$/ {
      ms = $1 + 0; pid = $2 + 0; n++
      if (n == 1) first = ms; else { gap = ms - prev; if (gap > maxg) maxg = gap }
      prev = ms
      if (pid < 0) { unread++; next }
      if (pid == a0 + 0 || pid == a1 + 0) { hits++; next }
      if (!havestart) { startpid = pid; havestart = 1 }
      else if (pid != startpid) changes++
    }
    END { printf "%d %d %d %d %d %d %d %d\n", n, first, prev, maxg, hits, unread, changes, havestart ? startpid : -1 }' "$SAMPLES")"
  set -- $line
  S_COUNT="$1"; S_FIRST="$2"; S_LAST="$3"; S_MAXGAP="$4"; S_AGENT="$5"; S_UNREAD="$6"; S_CHANGES="$7"; S_STARTPID="$8"
}

# The number of FOCUS_VIOLATION lines in file $1 from byte offset $2 to its end.
fv_count() { tail -c +"$(($2 + 1))" "$1" 2>/dev/null | /usr/bin/awk '$2 == "FOCUS_VIOLATION" { n++ } END { print n + 0 }'; }

# Did agent.log rotate since the window opened, and where is what it held at the start? agent.log is renamed to agent.log.1 by the agent, so
# the rotated file is the one whose inode is the inode agent.log had at the start. The end facts are frozen before the sampler stops and
# before this runs, and a rotation can come at any moment (agent.log reaching its size limit), also in the time between the freeze and the
# read: so agent.log and agent.log.1 are compared with their start facts as they are NOW as well as as they were at the freeze. Sets
# ROTATED (0|1), ROT_FILE (the file agent.log was at the start, or empty when it cannot be identified), ROT_NOTE, and the inode and the
# agent.log.1 signature seen now (ROT_NOW_I, ROT_NOW_L1) for the reason.
analyze_rotation() {
  ROTATED=0; ROT_FILE=""; ROT_NOTE=""
  ROT_NOW_I="$(ck_file_inode "$LOG")"; ROT_NOW_L1="$(log1_signature)"
  if { [ "$LOG_I0" != none ] && { [ "$LOG_I1" != "$LOG_I0" ] || [ "$ROT_NOW_I" != "$LOG_I0" ]; }; } || [ "$LOG_S1" -lt "$LOG_S0" ] || [ "$LOG1_SIG1" != "$LOG1_SIG0" ] || [ "$ROT_NOW_L1" != "$LOG1_SIG0" ]; then ROTATED=1; fi
  [ "$ROTATED" = 1 ] || return 0
  if [ "$LOG_I0" != none ] && [ -f "$LOG1" ] && [ ! -L "$LOG1" ] && [ "$(ck_file_inode "$LOG1")" = "$LOG_I0" ]; then
    ROT_FILE="$LOG1"; ROT_NOTE="agent.log.1 is the file agent.log was at the start (same inode) and was read as well"
  else
    ROT_NOTE="the file agent.log was at the start could not be identified (agent.log.1 has another inode, or is missing), so its lines could not be read"
  fi
}

analyze_log() {
  local line
  # The INPUT lines appended DURING the window, in order: bytes [start offset, end offset) of agent.log; after a rotation, the rotated
  # file from the start offset on, then the new agent.log up to the end offset. Lines before the first sample or after the frozen end do
  # not count toward the sequence or the click count.
  : > "$WINDOW_LINES_FILE"
  if [ "$ROTATED" = 1 ]; then
    if [ -n "$ROT_FILE" ]; then tail -c +"$((LOG_S0 + 1))" "$ROT_FILE" 2>/dev/null | /usr/bin/awk '$2 == "INPUT"' >> "$WINDOW_LINES_FILE"; fi
    head -c "$LOG_S1" "$LOG" 2>/dev/null | /usr/bin/awk '$2 == "INPUT"' >> "$WINDOW_LINES_FILE"
  elif [ "$LOG_S1" -gt "$LOG_S0" ]; then
    tail -c +"$((LOG_S0 + 1))" "$LOG" 2>/dev/null | head -c "$((LOG_S1 - LOG_S0))" | /usr/bin/awk '$2 == "INPUT"' >> "$WINDOW_LINES_FILE"
  fi
  line="$(/usr/bin/awk '
    $2 == "INPUT" && $3 == "kind=mouseDown" { down++; if (state != 3) state = 1 }
    $2 == "INPUT" && $3 == "kind=mouseDragged" { drag++; if (state == 1) state = 2 }
    $2 == "INPUT" && $3 == "kind=mouseUp" { up++; if (state == 2) state = 3 }
    END { printf "%d %d %d %d\n", down, drag, up, (state == 3) ? 1 : 0 }' "$WINDOW_LINES_FILE")"
  set -- $line
  IN_DOWN="$1"; IN_DRAG="$2"; IN_UP="$3"; IN_SEQ="$4"
  # FOCUS_VIOLATION lines are counted to the END of the files, not only to the window's end offset: a violation is a FAIL wherever the
  # script can see it. After a rotation both files are read (the rotated one from the start offset, or from the install offset).
  ROT_FV_WINDOW=0; ROT_FV_HISTORY=0
  if [ "$ROTATED" = 1 ]; then
    FV_WINDOW="$(fv_count "$LOG" 0)"
    if [ -n "$ROT_FILE" ]; then ROT_FV_WINDOW="$(fv_count "$ROT_FILE" "$LOG_S0")"; FV_WINDOW=$((FV_WINDOW + ROT_FV_WINDOW)); fi
    if [ "$HIST_OK" = 1 ]; then
      FV_HISTORY="$(fv_count "$LOG" 0)"
      if [ -n "$ROT_FILE" ]; then ROT_FV_HISTORY="$(fv_count "$ROT_FILE" "$HIST_OFFSET")"; FV_HISTORY=$((FV_HISTORY + ROT_FV_HISTORY)); fi
    fi
  else
    FV_WINDOW="$(fv_count "$LOG" "$LOG_S0")"
    if [ "$HIST_OK" = 1 ]; then FV_HISTORY="$(fv_count "$LOG" "$HIST_OFFSET")"; fi
  fi
  # Every retained log, whole: a violation is a FAIL wherever it is (D5 step 1), whether or not the install-time proof held.
  scan_logs
  LOGS_SCANNED=1
}

# analyze_rotation and analyze_log read the logs by path, one file after the other, so a rotation between two of those reads (the INPUT lines
# read from one generation, the violations from the next) would let a violation that moved into agent.log.1 go unseen. The generation is
# looked at before and after the whole analysis; when it differs, the analysis is done again, now against the rotated state. A log that
# keeps rotating for LOG_READ_TRIES analyses is NOT RUN (it counts as rotated; a violation found in what was read is still a FAIL).
analyze_logs() {
  local tries=0 before after
  while :; do
    before="$(log_generation)"
    analyze_rotation
    analyze_log
    after="$(log_generation)"
    [ "$before" != "$after" ] || return 0
    tries=$((tries + 1))
    if [ "$tries" -ge "$LOG_READ_TRIES" ]; then
      ROTATED=1
      ROT_NOTE="agent.log was replaced again while each of $LOG_READ_TRIES analyses of it ran, so it was never read as one generation"
      return 0
    fi
  done
}

analyze_panel() {
  local x0 y0 x1 y1
  [ -n "$PANEL0" ] && [ -n "$PANEL1" ] || return 0
  set -- $PANEL0; x0="$1"; y0="$2"; local w0="$3" h0="$4"
  set -- $PANEL1; x1="$1"; y1="$2"; local w1="$3" h1="$4"
  if [ "$w0" = "$w1" ] && [ "$h0" = "$h1" ]; then PANEL_SIZE_EQUAL=1; else PANEL_SIZE_EQUAL=0; fi
  # The decision uses the unrounded distance; only the figure printed in the evidence is rounded.
  set -- $(/usr/bin/awk -v x0="$x0" -v y0="$y0" -v x1="$x1" -v y1="$y1" -v min="$MIN_MOVE_PT" 'BEGIN { dx = x1 - x0; dy = y1 - y0; d = sqrt(dx * dx + dy * dy); printf "%.1f %d", d, (d >= min) ? 1 : 0 }')
  PANEL_MOVED="$1"; PANEL_MOVED_OK="$2"
}

# The rows that need a drag. Menu mode skips them (design 6.3).
decide_drag_rows() {
  if [ "$IN_DOWN" -lt "$MIN_MOUSE_DOWNS" ]; then notrun too-few-mousedowns "$IN_DOWN INPUT kind=mouseDown line(s) in the window, $MIN_MOUSE_DOWNS needed"; fi
  if [ "$IN_SEQ" != 1 ]; then notrun no-drag-sequence "no ordered down, drag, up in the window's INPUT lines ($IN_DOWN down, $IN_DRAG drag, $IN_UP up)"; fi
  if [ -n "$PANEL_SIZE_EQUAL" ]; then
    if [ "$PANEL_SIZE_EQUAL" = 0 ]; then
      notrun scene-changed "the stage window's size differs between the two reads ($PANEL0 -> $PANEL1), also after a 3 s re-read: retry"
    elif [ "$PANEL_MOVED_OK" != 1 ]; then
      notrun panel-not-moved "the panel's on-screen origin moved $PANEL_MOVED pt between window start and end (3 pt needed)"
    fi
  fi
}

# The FAIL rows of the ledger and of the agent's own reports of a failed ledger write. Every source is scanned before any outcome is chosen,
# so a violation in one source is a FAIL however much evidence another source lacks.
decide_ledger_fail_rows() {
  local v t b
  # A violation recorded in either read of the ledger counts, whichever read it is in, and whether or not the window ran.
  v="$LD0_VIOL"; [ "$LD1_VIOL" -le "$v" ] || v="$LD1_VIOL"
  t="$LD0_TORN"; [ "$LD1_TORN" -le "$t" ] || t="$LD1_TORN"
  b="$LD0_BEHIND"; [ "$LD1_BEHIND" -le "$b" ] || b="$LD1_BEHIND"
  if [ "$v" -gt 0 ]; then fail ledger-violation "$v VIOLATION line(s) in focus-violations.log"; fi
  if [ "$t" -gt 0 ]; then fail ledger-torn-line "a cut or malformed event line in focus-violations.log (a violation line that was not written whole)"; fi
  if { [ -n "$STATUS_LF0" ] && [ "$STATUS_LF0" -gt 0 ]; } || { [ -n "$STATUS_LF1" ] && [ "$STATUS_LF1" -gt 0 ]; } || { [ "$LOGS_SCANNED" = 1 ] && [ "$LF_RETAINED" -gt 0 ]; }; then
    fail ledger-write-failed "the agent reports it could not append a violation to the ledger (status.json ledgerFailures ${STATUS_LF0:-0}/${STATUS_LF1:-0}; ${LF_RETAINED:-0} FOCUS_VIOLATION_LEDGER_FAILED line(s))"
  fi
  if [ "$b" -gt 0 ]; then fail ledger-behind-counter "a BOOT line records a counter above the VIOLATION lines before it: a past violation the ledger missed"; fi
}

# The NOT RUN rows of the window's required evidence (D5 step 3): every gap is named, none is skipped. Log rotation is not one of them.
decide_ledger_gaps() {
  local f
  [ "$WINDOW_RAN" = 1 ] || return 0
  if [ "$LEDGER_LISTED" != 1 ]; then
    notrun ledger-not-adopted "the manifest has no focus-violation ledger line: this install was made, or last updated, before the ledger existed ('clawd-pet update' adopts it)"
  else
    case "$LD0_STATE" in
      absent) notrun ledger-missing "the ledger $LEDGER is listed in the manifest and does not exist" ;;
      ok) ;;
      *) notrun ledger-unreadable "the ledger could not be read at the start of the window" ;;
    esac
    if [ "$LD0_STATE" = ok ]; then
      case "$LD0_HDR" in
        ok) ;;
        *) notrun ledger-malformed "the ledger's header line is $LD0_HDR (it must be the complete first line LEDGER 1 born=<epoch> how=install|adopt-update|recreate)" ;;
      esac
      if [ "$LD0_HDR" = ok ] && [ "$LD0_UNKNOWN" -gt 0 ]; then notrun ledger-malformed "$LD0_UNKNOWN complete line(s) of an unknown kind in the ledger"; fi
      case "$LD1_STATE" in
        ok) ;;
        *) notrun ledger-final-read-failed "the ledger could not be read at the end of the window ($LD1_STATE)" ;;
      esac
      if [ "$LD1_STATE" = ok ]; then
        if [ "$LD_CONT" = changed ]; then notrun ledger-changed-in-window "the ledger at the end of the window does not begin with the bytes it held at the start (truncated, rewritten or its header changed)"; fi
        if [ "$LD1_HDR" != ok ] && [ "$LD_CONT" != changed ]; then notrun ledger-malformed "the ledger's header line is $LD1_HDR at the end of the window"; fi
        if [ "$LD1_HDR" = ok ] && [ "$LD1_UNKNOWN" -gt 0 ] && [ "$LD0_UNKNOWN" -eq 0 ]; then notrun ledger-malformed "$LD1_UNKNOWN complete line(s) of an unknown kind in the ledger at the end of the window"; fi
        if [ "$LD_CONT" = ok ] && [ "$LD_BOOT_IN_WINDOW" -gt 0 ]; then notrun agent-restarted-in-window "$LD_BOOT_IN_WINDOW BOOT line(s) came into the ledger during the window: the agent restarted, so the sampled pid is not the one that ran at the start"; fi
      fi
      if [ "$LD0_HDR" = ok ]; then
        if [ -z "$STATUS_PID0" ] || ! has_word "$STATUS_PID0" "$LD0_PIDS"; then
          notrun ledger-stale-agent "the running agent (status.json pid ${STATUS_PID0:-none}) wrote no BOOT line in the ledger: a build that does not know the ledger, or its BOOT write failed"
        fi
      fi
      if [ "$LD1_STATE" = ok ] && [ "$LD1_HDR" = ok ] && [ -n "$STATUS_PID1" ] && [ "$STATUS_PID1" != "$STATUS_PID0" ] && ! has_word "$STATUS_PID1" "$LD1_PIDS"; then
        notrun ledger-stale-agent "the agent running at the end of the window (status.json pid $STATUS_PID1) wrote no BOOT line in the ledger"
      fi
    fi
  fi
  for f in $LOG_GAPS; do notrun "log-unreadable:$f" "$f exists and could not be read, so its content could not be scanned for violations"; done
}

decide() {
  local s_changes_seen
  # ---- FAIL rows ----
  if [ -n "$STATUS_FV0" ] && [ "$STATUS_FV0" -gt 0 ]; then fail focusViolations-nonzero "status.json focusViolations is $STATUS_FV0 at the start of the window"; fi
  if [ -n "$STATUS_FV1" ] && [ "$STATUS_FV1" -gt 0 ]; then fail focusViolations-nonzero "status.json focusViolations is $STATUS_FV1 at the end of the window"; fi
  if [ "$LOGS_SCANNED" = 1 ] && [ "$FV_RETAINED" -gt 0 ]; then fail focus-violation-line "$FV_RETAINED FOCUS_VIOLATION line(s) in the retained agent.log files (the whole retained content, whether or not the install-time proof of the logs holds)"; fi
  decide_ledger_fail_rows
  if [ -n "$S_AGENT" ] && [ "$S_AGENT" -gt 0 ]; then fail agent-frontmost "the agent's pid was the frontmost application in $S_AGENT sample(s)"; fi
  if [ -n "$L_AGENT" ] && [ "$L_AGENT" -gt 0 ]; then
    fail agent-frontmost "an independent look at the frontmost application (lsappinfo, not the sampler) named the agent's pid in $L_AGENT of $L_TOTAL look(s), the first one at: $L_FIRST (start, window, end-read or end); the sampler may have missed it"
  fi
  [ "$MENU_MODE" != 1 ] || menu_add_rows FAIL
  [ "$WINDOW_RAN" = 1 ] || return 0
  has_reason "$NOTRUNS" interrupted && return 0
  # ---- NOT RUN rows ----
  if [ -n "$P1" ] && [ "$P1" != "$P0" ]; then notrun agent-pid-changed "the agent's pid was $P0 at the start and $P1 at the end"; fi
  if [ -z "$P1" ]; then notrun agent-pid-changed "the agent had no pid at the end of the window (it was $P0 at the start)"; fi
  s_changes_seen="$S_CHANGES"
  [ "$MENU_MODE" != 1 ] || S_CHANGES=0   # menu mode: a transition of the frontmost application is judged against the clicks (the menu rows below)
  if [ -n "$S_COUNT" ]; then
    if [ "$S_COUNT" -lt 1 ]; then notrun sampler-failed "the sampler wrote no readable sample"; fi
    if [ "$S_UNREAD" -gt 0 ]; then notrun frontmost-read-failed "$S_UNREAD sample(s) could not read the frontmost application"; fi
    if [ "$S_COUNT" -gt 1 ] && [ "$S_MAXGAP" -gt "$MAX_GAP_MS" ]; then notrun sampler-gap "the longest gap between two samples was $S_MAXGAP ms (limit $MAX_GAP_MS ms)"; fi
    if [ "$S_CHANGES" -gt 0 ]; then notrun frontmost-changed "the frontmost application changed $S_CHANGES time(s) to an app other than the agent: retry without switching apps"; fi
  else
    notrun sampler-failed "the sampler left no samples"
  fi
  S_CHANGES="$s_changes_seen"
  if [ -n "$STATUS_DC0" ] && [ -n "$STATUS_DC1" ] && [ "$STATUS_DC0" != "$STATUS_DC1" ]; then
    notrun display-changed "displayChangeCount went from $STATUS_DC0 to $STATUS_DC1 during the window"
  fi
  if [ -n "$FRESHW_STALE_MAX" ] && [ "$FRESHW_STALE_MAX" -ge "$STALE_LOOKS" ]; then
    notrun sampler-stale "the sampler's frontmost pid differed from the system's in $FRESHW_STALE_MAX looks in a row inside the window ($FRESHW_DETAIL; $STALE_LOOKS in a row are stale)"
  fi
  if [ -n "$FRESHW_UNREAD_MAX" ] && [ "$FRESHW_UNREAD_MAX" -ge "$STALE_LOOKS" ]; then
    notrun sampler-freshness-unproven "the system's frontmost application could not be read in $FRESHW_UNREAD_MAX looks in a row inside the window ($STALE_LOOKS in a row are unproven)"
  fi
  if [ -n "$FRESHW_GAP_MAX_MS" ] && [ "$FRESHW_GAP_MAX_MS" -gt "$LOOK_GAP_MAX_MS" ]; then
    notrun look-gap "nothing independent saw the frontmost application for $FRESHW_GAP_MAX_MS ms (from the window start, between two looks, or to the end) (more than $LOOK_GAP_MAX_MS ms: a switch to the agent and back inside it, with a cached sampler, would not be seen)"
  fi
  decide_ledger_gaps
  # agent.log rotating in the window is an expected event and never a gap of the focus verdict (the ledger is its primary record); it is
  # noted in the evidence (window.log_window_rotated). A MENU run reads its rows from the window's lines in every retained generation, so a
  # rotation does not leave them unevaluated either; only a generation that is gone before it was read is a gap (menu-log-gap), and it is
  # named.
  if [ -n "$MENU_GAP" ]; then notrun menu-log-gap "$MENU_GAP: the menu rows could not be evaluated, retry"; fi
  [ "$MENU_MODE" = 1 ] || decide_drag_rows
  [ "$MENU_MODE" != 1 ] || menu_add_rows NOTRUN
}

# ---------------------------------------------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------------------------------------------

jreasons() { # comma-separated reasons -> a JSON array of strings
  local first=1 r
  printf '['
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$first" = 1 ]; then first=0; else printf ', '; fi
    printf '"%s"' "$(ck_json_escape "$r")"
  done < <(printf '%s\n' "$1" | /usr/bin/awk -F', ' '{ for (i = 1; i <= NF; i++) print $i }')
  printf ']'
}
jwords() { # space-separated words -> a JSON array of strings
  local first=1 w
  printf '['
  for w in $1; do
    if [ "$first" = 1 ]; then first=0; else printf ', '; fi
    printf '"%s"' "$(ck_json_escape "$w")"
  done
  printf ']'
}
write_evidence() {
  local commit
  commit="$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "check": "attended-check",\n'
    printf '  "verdict": "%s",\n' "$VERDICT"
    printf '  "exit_code": %s,\n' "$EXIT_CODE"
    printf '  "scope": %s,\n' "$(jstr "$SCOPE")"
    printf '  "started_at_epoch": %s,\n' "$START_EPOCH"
    printf '  "repo_commit": %s,\n' "$(jstr "$commit")"
    printf '  "sandbox": %s,\n' "$(jbool "$CK_SANDBOX_MODE")"
    printf '  "window_seconds": %s,\n' "$SECONDS_WINDOW"
    printf '  "window_ran": %s,\n' "$(jbool "$WINDOW_RAN")"
    printf '  "fail_codes": %s,\n' "$(jcodes "$FAILS")"
    printf '  "notrun_codes": %s,\n' "$(jcodes "$NOTRUNS")"
    printf '  "fail_reasons": %s,\n' "$(jlist "$FAILS")"
    printf '  "notrun_reasons": %s,\n' "$(jlist "$NOTRUNS")"
    printf '  "agent_pid": {"start": %s, "end": %s},\n' "$(jnum "$P0")" "$(jnum "$P1")"
    printf '  "status_json": {"focusViolations_start": %s, "focusViolations_end": %s, "displayChangeCount_start": %s, "displayChangeCount_end": %s},\n' \
      "$(jnum "$STATUS_FV0")" "$(jnum "$STATUS_FV1")" "$(jnum "$STATUS_DC0")" "$(jnum "$STATUS_DC1")"
    printf '  "history": {"proved": %s, "since_install_offset_bytes": %s, "agent_log": %s, "agent_log_1": %s, "focus_violation_lines_since_install": %s,\n' \
      "$(jbool "$HIST_OK")" "$(jnum "$HIST_OFFSET")" "$(jstr "$HIST_D_LOG")" "$(jstr "$HIST_D_LOG1")" "$(jnum "$FV_HISTORY")"
    printf '              "note": "the install-time proof of the logs (proved, offset, agent_log, agent_log_1) is supporting detail; it never changes the verdict",\n'
    printf '              "since_ledger_birth": {"born_epoch": %s, "how": %s, "complete": %s, "reasons": %s, "boot_lines": %s, "violation_lines": %s, "text": %s, "limits": %s}},\n' \
      "$(jnum "$HIST_BORN")" "$(jstr "$HIST_HOW")" "$(jbool "$([ -n "$HIST_TEXT" ] && echo "$HIST_COMPLETE")")" "$(jreasons "$HIST_REASONS")" "$(jnum "$HIST_BOOTS")" "$(jnum "$HIST_VIOL")" "$(jstr "$HIST_TEXT")" "$(jstr "$HIST_LIMITS")"
    printf '  "ledger": {"path": %s, "listed_in_manifest": %s, "start_state": %s, "end_state": %s, "start_header": %s, "end_header": %s, "continuity": %s,\n' \
      "$(jstr "$LEDGER")" "$(jbool "$LEDGER_LISTED")" "$(jstr "$LD0_STATE")" "$(jstr "$LD1_STATE")" "$(jstr "$LD0_HDR")" "$(jstr "$LD1_HDR")" "$(jstr "$LD_CONT")"
    printf '             "violation_lines_start": %s, "violation_lines_end": %s, "torn_lines_end": %s, "boot_lines_end": %s, "boot_lines_in_window": %s, "behind_counter_boots": %s,\n' \
      "$(jnum "$LD0_VIOL")" "$(jnum "$LD1_VIOL")" "$(jnum "$LD1_TORN")" "$(jnum "$LD1_BOOTS")" "$(jnum "$LD_BOOT_IN_WINDOW")" "$(jnum "$LD1_BEHIND")"
    printf '             "status_pid_start": %s, "status_pid_end": %s, "status_ledgerFailures_start": %s, "status_ledgerFailures_end": %s,\n' \
      "$(jnum "$STATUS_PID0")" "$(jnum "$STATUS_PID1")" "$(jnum "$STATUS_LF0")" "$(jnum "$STATUS_LF1")"
    printf '             "retained_logs": {"focus_violation_lines": %s, "ledger_failed_lines": %s, "boot_sync_failed_lines": %s, "unreadable": %s}},\n' \
      "$(jnum "$FV_RETAINED")" "$(jnum "$LF_RETAINED")" "$(jnum "$SYNC_RETAINED")" "$(jwords "$LOG_GAPS")"
    printf '  "window": {"agent_log_bytes_start": %s, "agent_log_bytes_end": %s, "agent_log_inode_start": %s, "agent_log_inode_end": %s, "rotated": %s, "log_window_rotated": %s,\n' \
      "$(jnum "$LOG_S0")" "$(jnum "$LOG_S1")" "$(jstr "$LOG_I0")" "$(jstr "$LOG_I1")" "$(jbool "$ROTATED")" "$(jstr "$([ "$ROTATED" = 1 ] && echo "agent.log rotated or was replaced during the window; the ledger is the window's primary record, so this is a note and not a gap")")"
    printf '             "sampled_ms_start": %s, "sampled_ms_end": %s, "input_bytes_start": %s, "input_bytes_end": %s,\n' \
      "$(jnum "$WIN_T0")" "$(jnum "$WIN_T1")" "$(jnum "$LOG_S0")" "$(jnum "$LOG_S1")"
    printf '             "rotated_file": %s, "rotated_file_focus_violation_lines": %s, "rotation_note": %s,\n' "$(jstr "$ROT_FILE")" "$(jnum "$ROT_FV_WINDOW")" "$(jstr "$ROT_NOTE")"
    printf '             "input_mouseDown": %s, "input_mouseDragged": %s, "input_mouseUp": %s, "drag_sequence_completed": %s, "focus_violation_lines": %s},\n' \
      "$(jnum "$IN_DOWN")" "$(jnum "$IN_DRAG")" "$(jnum "$IN_UP")" "$(jbool "$IN_SEQ")" "$(jnum "$FV_WINDOW")"
    printf '  "sampler_freshness": {"start": %s, "end": %s, "window_looks": %s, "window_longest_disagreement_looks": %s, "window_longest_unreadable_looks": %s, "window_disagreement": %s,\n' \
      "$(jstr "$FRESH0")" "$(jstr "$FRESH1")" "$(jnum "$FRESHW_LOOKS")" "$(jnum "$FRESHW_STALE_MAX")" "$(jnum "$FRESHW_UNREAD_MAX")" "$(jstr "$FRESHW_DETAIL")"
    printf '                         "independent_looks": %s, "independent_looks_naming_the_agent": %s, "longest_gap_between_looks_ms": %s},\n' "$(jnum "$L_TOTAL")" "$(jnum "$L_AGENT")" "$(jnum "$FRESHW_GAP_MAX_MS")"
    printf '  "panel": {"start": %s, "end": %s, "size_equal": %s, "origin_moved_pt": %s},\n' \
      "$(jpanel "$PANEL0")" "$(jpanel "$PANEL1")" "$(jbool "$PANEL_SIZE_EQUAL")" "$(jnum "$PANEL_MOVED")"
    printf '  "samples": {"count": %s, "first_ms": %s, "last_ms": %s, "max_gap_ms": %s, "agent_frontmost": %s, "unreadable": %s, "frontmost_changes": %s, "start_frontmost_pid": %s},\n' \
      "$(jnum "$S_COUNT")" "$(jnum "$S_FIRST")" "$(jnum "$S_LAST")" "$(jnum "$S_MAXGAP")" "$(jnum "$S_AGENT")" "$(jnum "$S_UNREAD")" "$(jnum "$S_CHANGES")" "$(jnum "$S_STARTPID")"
    if [ "$MENU_MODE" = 1 ]; then
      printf '  "files": {"samples": %s, "window_input_lines": %s, "clicks": %s, "keys": %s, "prompts": %s, "x1": %s, "log_polls": %s},\n' "$(jstr "${SAMPLES:-}")" \
        "$(jstr "${WINDOW_LINES_FILE:-}")" "$(jstr "$WORK/sampler.err")" "$(jstr "$KEYS_LOG")" "$(jstr "$PROMPTS_FILE")" "$(jstr "$WORK")" "$(jstr "$POLLS_FILE")"
      printf '  "mode": "menu",\n'
      printf '  "menu": %s\n' "${MENU_EVIDENCE:-null}"
    else
      printf '  "files": {"samples": %s, "window_input_lines": %s}\n' "$(jstr "${SAMPLES:-}")" "$(jstr "${WINDOW_LINES_FILE:-}")"
    fi
    printf '}\n'
  } | ck_publish "$EVIDENCE_FILE"
}

window_label() { /bin/date -r "${1:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "${1:-?}"; }
finish() {
  local more
  trap '' INT TERM HUP
  stop_reader
  stop_sampler
  analyze_looks
  if [ "$WINDOW_RAN" = 1 ]; then
    # Interrupted inside the window: the end facts were never frozen. Read them now; the verdict stays NOT RUN (interrupted), and a
    # FOCUS_VIOLATION line found in either log file is still a FAIL.
    [ -n "$LOG_S1" ] || { LOG_S1="$(ck_file_size "$LOG")"; LOG_I1="$(ck_file_inode "$LOG")"; LOG1_SIG1="$(log1_signature)"; }
    analyze_samples
    analyze_logs
    [ -n "$LD1_STATE" ] || ledger_snapshot 1
    analyze_ledger
    compute_history
    analyze_panel
    [ "$MENU_MODE" != 1 ] || analyze_menu
  else
    collect_unrun_sources
    compute_history
  fi
  decide
  if [ -n "$FAILS" ]; then VERDICT="FAIL"; EXIT_CODE=1
  elif [ -n "$NOTRUNS" ]; then VERDICT="NOT RUN"; EXIT_CODE=3
  else VERDICT="PASS"; EXIT_CODE=0; fi
  if ! write_evidence; then ck_warn "attended-check: could not write the evidence file $EVIDENCE_FILE"; fi
  ck_say "attended-check: scope: $SCOPE"
  if [ -n "$HIST_TEXT" ]; then
    ck_say "attended-check: history: $HIST_TEXT"
    ck_say "attended-check: history limits: $HIST_LIMITS"
  fi
  [ "$ROTATED" != 1 ] || ck_say "attended-check: note log-window-rotated: agent.log rotated during the window; the ledger is the window's record, so this is not a gap"
  case "$VERDICT" in
    PASS) ck_say "attended-check: PASS: no focus violation in window $(window_label "$EPOCH_S")..$(window_label "$EPOCH_E"): frontmost-pid sampling clean, ledger intact at both ends, counter 0, agent.log clean ($IN_DOWN mouseDown, $IN_DRAG mouseDragged, $IN_UP mouseUp; panel moved $PANEL_MOVED pt; $S_COUNT samples, longest gap $S_MAXGAP ms) -> $EVIDENCE_FILE" ;;
    FAIL) ck_say "attended-check: FAIL ($(printf '%s\n' "$FAILS" | head -n 1)) -> $EVIDENCE_FILE" ;;
    *)
      more=$(( $(printf '%s\n' "$NOTRUNS" | wc -l | tr -d ' ') - 1 ))
      ck_say "attended-check: NOT RUN ($(printf '%s\n' "$NOTRUNS" | head -n 1)$([ "$more" -gt 0 ] && printf '; +%s more' "$more")) -> $EVIDENCE_FILE" ;;
  esac
  exit "$EXIT_CODE"
}

on_signal() {
  # A signal that lands inside `while IFS='=' read` (the live view reads Perl's output that way every poll) runs this handler with the read's
  # temporary IFS still in force, and the analysis below splits with the default one ("0 0 -" read as one word ends the run on `set -u`).
  IFS=$' \t\n'
  notrun interrupted "the check was interrupted before it finished"
  # A signal that lands while a function runs with its output redirected (menu_window_lines appends to a work file) runs this handler with
  # that redirection in force, and the verdict would go into the work file instead of the terminal. fd 4 and 5 are the script's own stdout
  # and stderr, saved before the trap was set.
  if { : >&4; } 2>/dev/null; then finish >&4 2>&5; else finish; fi
}

# The analysis of a menu run: one Perl program (mode=live for the waiting loop, mode=analyze for the verdict rows and the evidence).
IFS= read -r -d '' MENU_PERL <<'PERL' || true
use strict;
use warnings;
use JSON::PP;

# The menu analysis of scripts/attended-check.sh --menu. mode=live prints what the waiting loop needs; mode=analyze prints the verdict rows
# (FAIL / NOTRUN lines) and writes the evidence object. Times are milliseconds on the sampler's clock; et values are seconds.
my %A;
for my $arg (@ARGV) { $A{$1} = $2 if $arg =~ /^([a-z0-9_]+)=(.*)$/s; }
my $MODE = $A{mode} // 'analyze';
my $W = 2000; my $LAG = 100; my $SETTLE = 2000; my $BAND = 1.0; my $TOL = 0.0005; my $EARLY = 100; my $LATE = 500;
my $S0 = $A{s0} // 0;
my $P0 = $A{p0} // ''; my $P1 = $A{p1} // '';
my $LASTSIG = $A{lastsig} // 0;

sub rd { my ($f) = @_; return () unless defined $f && length $f && -f $f; local @ARGV = ($f); my @l; while (my $x = <>) { push @l, $x; } return @l; }
sub kv { my ($t) = @_; my %h; while ($t =~ /(?:^|\s)([A-Za-z_]+)=(\S*)/g) { $h{$1} = $2 unless exists $h{$1}; } return \%h; }
sub num { my $x = shift; return (defined $x && $x =~ /^-?\d+(?:\.\d+)?$/) ? $x + 0 : undef; }
sub rect { my $s = shift; return undef unless defined $s && $s ne 'none'; my @v = split /,/, $s; return undef unless @v == 4; for my $n (@v) { return undef unless defined num($n); } return [map { $_ + 0 } @v]; }
sub clear_in { my ($r, $x, $y) = @_; return 0 unless $r && defined $x && defined $y; return ($x >= $r->[0] + $BAND && $x < $r->[0] + $r->[2] - $BAND && $y >= $r->[1] + $BAND && $y < $r->[1] + $r->[3] - $BAND) ? 1 : 0; }
sub clear_out { my ($r, $x, $y) = @_; return 1 unless $r; return 0 unless defined $x && defined $y; return ($x < $r->[0] - $BAND || $x >= $r->[0] + $r->[2] + $BAND || $y < $r->[1] - $BAND || $y >= $r->[1] + $r->[3] + $BAND) ? 1 : 0; }
sub one_line { my $s = shift; $s =~ s/[\t\r\n]+/ /g; return $s; }

my %MENUKINDS = map { $_ => 1 } ('open', 'close', 'hover', 'pick', 'drop', 'write', 'stale');
sub parse_line {
  my ($txt) = @_;
  my %l = (txt => $txt, t => 'OTHER');
  if ($txt =~ /^\S+ MENU (\S+)(?: (.*))?$/) {
    my ($k, $rest) = ($1, defined $2 ? $2 : '');
    $l{t} = 'MENU'; $l{k} = $k; $l{f} = $MENUKINDS{$k} ? kv($rest) : {};
  } elsif ($txt =~ /^\S+ GEOM t=(\S+) (.*)$/) {
    $l{t} = 'GEOM'; $l{g} = $2; $l{f} = kv($2); $l{body} = rect($l{f}{body}); $l{menu} = rect($l{f}{menu}); $l{mgen} = $l{f}{menugen};
    $l{shown} = (defined $l{f}{menu} && $l{f}{menu} ne 'none') ? 1 : 0;
  } elsif ($txt =~ /^\S+ (INPUT|MOUSE-IGNORED) (.*)$/) {
    $l{t} = $1; $l{f} = kv($2);
  }
  return \%l;
}

# ---- the window's lines, the seed (the last MENU-open/close line and the last GEOM line before the window), the polls
my @L; my $off = $S0;
for my $raw (rd($A{log})) {
  my $len = length($raw); my $txt = $raw; chomp $txt;
  my $l = parse_line($txt); $l->{i} = scalar(@L); $l->{off} = $off; $l->{end} = $off + $len; $off += $len;
  push @L, $l;
}
my ($seedE, $seedD);
for my $raw (rd($A{seed})) {
  my $txt = $raw; chomp $txt; my $l = parse_line($txt); $l->{i} = -1;
  if ($l->{t} eq 'MENU' && ($l->{k} eq 'open' || $l->{k} eq 'close')) { $seedE = $l; }
  elsif ($l->{t} eq 'GEOM') { $seedD = $l; }
}
my @P;
for my $raw (rd($A{polls})) { my @f = split ' ', $raw; push @P, [@f] if @f == 3; }
sub seen {
  my ($l) = @_;
  for my $p (@P) { if ($p->[0] >= $l->{end}) { return { lo => $p->[1], sig => $p->[2], hi => $p->[2] + $LAG }; } }
  return { lo => $LASTSIG, sig => $LASTSIG, hi => $LASTSIG + $LAG };
}
for my $l (@L) { $l->{seen} = seen($l); }

# ---- the sequences E (MENU-open/close) and D (GEOM menu none <-> rect), seeded
my @E; my @D;
if ($seedE && $seedE->{k} eq 'open') { push @E, { t => 'open', gen => $seedE->{f}{gen}, i => -1, seed => 1, line => $seedE }; }
for my $l (@L) { next unless $l->{t} eq 'MENU' && ($l->{k} eq 'open' || $l->{k} eq 'close'); push @E, { t => $l->{k}, gen => $l->{f}{gen}, i => $l->{i}, line => $l }; }
my $dshown = 0;
if ($seedD && $seedD->{shown}) { push @D, { t => 'open', gen => $seedD->{mgen}, i => -1, seed => 1, line => $seedD }; $dshown = 1; }
for my $l (@L) {
  next unless $l->{t} eq 'GEOM';
  if (!$dshown && $l->{shown}) { push @D, { t => 'open', gen => $l->{mgen}, i => $l->{i}, line => $l }; $dshown = 1; }
  elsif ($dshown && !$l->{shown}) { push @D, { t => 'close', gen => $l->{mgen}, i => $l->{i}, line => $l }; $dshown = 0; }
}
my $efinal = 'close'; for my $e (@E) { $efinal = $e->{t}; }
my $dfinal = $dshown ? 'open' : 'close';

# ---- the live view for the waiting loop: the E state, the open one's declared rectangle, the pick wait, the quiet anchor
my %PICK; my %WRITES; my %DROPS; my @PICKS;
for my $l (@L) {
  next unless $l->{t} eq 'MENU';
  my $f = $l->{f};
  if ($l->{k} eq 'pick' && defined num($f->{id})) { my $p = { id => $f->{id} + 0, key => $f->{key}, gen => $f->{gen}, line => $l, f => $f }; $PICK{$p->{id}} = $p; push @PICKS, $p; }
  elsif ($l->{k} eq 'write' && defined num($f->{id})) { push @{$WRITES{$f->{id} + 0}}, $l; }
  elsif ($l->{k} eq 'drop' && defined num($f->{id})) { push @{$DROPS{$f->{id} + 0}}, $l; }
}
my %CNT;
sub completions {
  my ($id) = @_;
  return $CNT{$id} if exists $CNT{$id};
  $CNT{$id} = 0;
  my $n = scalar(@{$WRITES{$id} || []});
  for my $d (@{$DROPS{$id} || []}) {
    my $by = num($d->{f}{by});
    next unless defined $by && $by > $id && $PICK{$by} && $PICK{$id} && ($PICK{$by}{key} // '') eq ($PICK{$id}{key} // '');
    $n++ if completions($by) >= 1;
  }
  $CNT{$id} = $n; return $n;
}

if ($MODE eq 'live') {
  my ($ogen, $orect, $ooff) = ('-', '-', '-');
  if ($efinal eq 'open') {
    my $eo; for my $e (reverse @E) { if ($e->{t} eq 'open') { $eo = $e; last; } }
    if ($eo) {
      $ogen = $eo->{gen} // '-'; $ooff = $eo->{seed} ? 'seed' : $eo->{line}{off};
      for my $l (reverse @L) { if ($l->{t} eq 'GEOM' && $l->{shown} && defined $l->{mgen} && $l->{mgen} eq $ogen) { $orect = $l->{f}{menu}; last; } }
    }
  }
  my ($lastsig, $pend) = ('-', '-');
  for my $l (reverse @L) { if ($l->{t} eq 'MENU' || defined num($l->{f} ? $l->{f}{et} : undef)) { $lastsig = $l->{seen}{sig}; last; } }
  my @pending = grep { completions($_->{id}) == 0 } @PICKS;
  if (@pending) {
    my $a = $pending[0]{line}{seen}{sig};
    for my $p (@pending) { $a = $p->{line}{seen}{sig} if $p->{line}{seen}{sig} < $a; }
    for my $l (reverse @L) { if ($l->{t} eq 'MENU' && ($l->{k} eq 'write' || $l->{k} eq 'drop')) { $a = $l->{seen}{sig} if $l->{seen}{sig} > $a; last; } }
    $pend = $a;
  }
  # the early end of the countdown: a typed word matched with the menu window seen, a pick written with exit 0, and an outside close after it
  my ($typed, $writeok, $outside) = (0, 0, 0);
  my %PW; for my $r (rd($A{prompts})) { my @f = split ' ', $r; next unless @f >= 3 && $f[0] eq 'PROMPT'; my $wh = ''; for my $x (@f) { $wh = $1 if $x =~ /^wh=(.*)$/; } $PW{$f[2]} = $wh; }
  my %MATCHED;
  for my $r (rd($A{keys})) { my @f = split ' ', $r; next unless @f >= 2 && $f[0] eq 'KEY' && exists $PW{$f[1]}; $MATCHED{$f[1]} = 1; my $mw = ''; for my $x (@f) { $mw = $1 if $x =~ /^menu_windows=(.*)$/; } $typed = 1 if grep { $_ eq $PW{$f[1]} } split /,/, $mw; }
  my $pickline = -1;
  for my $p (@PICKS) { my @w = @{$WRITES{$p->{id}} || []}; if (grep { ($_->{f}{exit} // '') eq '0' } @w) { $writeok = 1; $pickline = $p->{line}{i} if $pickline < 0; } }
  if ($writeok) { for my $l (@L) { if ($l->{i} > $pickline && $l->{t} eq 'MENU' && $l->{k} eq 'close' && ($l->{f}{reason} // '') eq 'outside') { $outside = 1; last; } } }
  print "estate=$efinal\nogen=$ogen\norect=$orect\nooff=$ooff\nmatched=" . (scalar(keys %MATCHED) ? 1 : 0) . "\nearly=" . (($typed && $writeok && $outside) ? 1 : 0) . "\nmenu_sig=$lastsig\npend_anchor=$pend\n";
  exit 0;
}

# ---- analysis ---------------------------------------------------------------------------------------------------------------
# The cause window of a transition (N13): a click can have caused the transition at T if it was handled by the sampler (t_s) no earlier than
# W + 500 ms + STAMP_LAG before T (its own handling delay, the 500 ms of spec 7b, the stamp that first shows the transition) and no later
# than W after T (the sampler stamps a click at most W after it happens).
sub in_cause { my ($T, $ts) = @_; return ($ts >= $T - $W - $LATE - $LAG && $ts <= $T + $W) ? 1 : 0; }
if ($MODE eq 'cause') {
  for my $case (split /,/, ($A{cases} // '')) { my ($T, $ts) = split /:/, $case; print "$case=" . in_cause($T, $ts) . "\n"; }
  exit 0;
}
my @FAIL; my @NOTRUN;
sub fail { push @FAIL, [$_[0], one_line($_[1])]; }
sub notrun { push @NOTRUN, [$_[0], one_line($_[1])]; }
my %EV;

# F3 reads the lines of the window in every case, also after a rotation
my @bad_writes;
for my $l (@L) {
  next unless $l->{t} eq 'MENU' && $l->{k} eq 'write';
  my $x = $l->{f}{exit} // 'none';
  push @bad_writes, "id=" . ($l->{f}{id} // '?') . " exit=$x" unless $x eq '0' || $x eq '3';
}
if (@bad_writes) { fail('menu-write-failed', scalar(@bad_writes) . " menu write(s) ended with an exit other than 0 and 3: " . join('; ', @bad_writes[0 .. ($#bad_writes > 4 ? 4 : $#bad_writes)])); }

if (($A{rotated} // 0) == 1) {
  $EV{evaluated} = 'only the menu writes (the log rotated in the window)';
  finish_output();
  exit 0;
}

# ---- clicks of the sampler
my @C; my $clickson = '';
for my $raw (rd($A{clicks})) {
  my $x = $raw; chomp $x;
  if ($x =~ /^CLICKS-(ON|FAILED)/) { $clickson = $x; next; }
  next unless $x =~ /^CLICK t=(\S+) et=(\S+) button=(\S+) ctrl=(\d) x=(\S+) y=(\S+) target=(\S+)/;
  my $t = num($1);
  push @C, { n => scalar(@C) + 1, ts => int(($t // 0) * 1000 + 0.5), et => num($2), etraw => $2, button => $3, ctrl => $4, x => num($5), y => num($6), target => $7, lines => [] };
}

# ---- pairing of the agent's et-bearing lines with the clicks (by et, within 0.5 ms, same button class)
sub pair_click {
  my ($et, $btn) = @_;
  my ($best, $bd);
  for my $c (@C) {
    next unless defined $c->{et};
    next if defined $btn && $c->{button} ne $btn;
    my $d = abs($c->{et} - $et);
    next if $d > $TOL + 1e-9;
    if (!defined $bd || $d < $bd) { $best = $c; $bd = $d; }
  }
  return ($best, $bd);
}
my %DOWNBTN = (mouseDown => 'left', rightMouseDown => 'right', otherMouseDown => 'other');
my @ETLINES;
for my $l (@L) {
  my ($et, $btn, $role);
  if ($l->{t} eq 'MENU') {
    my $f = $l->{f};
    if ($l->{k} eq 'open') { $et = num($f->{et}); $btn = (($f->{how} // '') eq 'right') ? 'right' : 'left'; $role = 'open'; }
    elsif ($l->{k} eq 'pick') { $et = num($f->{et}); $btn = 'left'; $role = 'pick'; }
    elsif ($l->{k} eq 'close' && defined num($f->{et})) { $et = num($f->{et}); $role = (($f->{reason} // '') eq 'toggle') ? 'close-toggle' : 'close-outside'; }
    elsif ($l->{k} eq 'stale') { $et = num($f->{et}); $role = 'stale'; }
  } elsif ($l->{t} eq 'INPUT' || $l->{t} eq 'MOUSE-IGNORED') {
    $et = num($l->{f}{et}); $btn = $DOWNBTN{$l->{f}{kind} // ''};
    $role = ($l->{t} eq 'MOUSE-IGNORED' && ($l->{f}{why} // '') =~ /^menu-/) ? 'delivery-menu' : 'delivery-body';
    $role = undef unless defined $btn;
  }
  next unless defined $et && defined $role;
  $l->{role} = $role; $l->{et} = $et; push @ETLINES, $l;
  my ($c) = pair_click($et, $btn);
  if ($c) { $l->{click} = $c; push @{$c->{lines}}, $l; } else { $l->{noclick} = 1; }
}
my %TAKING = map { $_ => 1 } ('open', 'pick', 'close-toggle', 'delivery-body', 'delivery-menu');
sub taken { my $c = shift; return scalar(grep { $TAKING{$_->{role}} } @{$c->{lines}}) ? 1 : 0; }
sub named { my $c = shift; return scalar(grep { $_->{role} ne 'stale' } @{$c->{lines}}) ? 1 : 0; }

# ---- state proof (N11) and the intervals keyed by gen
my @n11;
{
  my $prev = 'close';
  for my $e (@E) { if ($e->{t} eq $prev) { push @n11, "two " . $e->{t} . "s in a row in the MENU lines (gen " . ($e->{gen} // '?') . ")"; } $prev = $e->{t}; }
  my $ek = join('', map { substr($_->{t}, 0, 1) } @E); my $dk = join('', map { substr($_->{t}, 0, 1) } @D);
  push @n11, "the MENU lines (E: $ek) and the GEOM menu= changes (D: $dk) differ in count or kind" if $ek ne $dk;
  my $kinds_equal = ($ek eq $dk);
  my $limit = @E < @D ? scalar(@E) : scalar(@D);
  for my $p (0 .. $limit - 1) { last if $E[$p]{t} ne $D[$p]{t}; $E[$p]{pair} = $D[$p]; $D[$p]{pair} = $E[$p]; }
  my $pe;
  for my $e (@E) {
    if ($e->{t} eq 'open') {
      if ($pe && defined $pe->{gen} && defined $e->{gen} && num($e->{gen}) <= num($pe->{gen})) { push @n11, "an opening's gen " . $e->{gen} . " is not above the previous opening's " . $pe->{gen}; }
      $pe = $e;
    }
  }
}
my %IV; my @IVS; my %GENS;
for my $e (@E) { $GENS{$e->{gen}} = 1 if $e->{t} eq 'open' && defined $e->{gen}; }
for my $p (0 .. $#E) {
  my $eo = $E[$p]; next unless $eo->{t} eq 'open';
  my $ec = ($p < $#E && $E[$p + 1]{t} eq 'close') ? $E[$p + 1] : undef;
  my $do = $eo->{pair}; my $dc = $ec ? $ec->{pair} : undef;
  my $iv = { gen => $eo->{gen}, eopen => $eo, eclose => $ec, dopen => $do, dclose => $dc, seedopen => $eo->{seed} ? 1 : 0 };
  my @why;
  if (!$do) { push @why, "no GEOM menu= change pairs with the MENU-open of gen " . ($eo->{gen} // '?'); }
  else {
    push @why, "the GEOM line that shows the menu names menugen " . ($do->{gen} // 'none') . " but the MENU-open names gen " . ($eo->{gen} // 'none') if ($do->{gen} // 'none') ne ($eo->{gen} // 'none');
    push @why, "the GEOM line that shows the menu comes after the MENU-open of gen " . ($eo->{gen} // '?') if $do->{i} > $eo->{i};
  }
  if ($ec) {
    push @why, "the MENU close names gen " . ($ec->{gen} // 'none') . " but follows the opening of gen " . ($eo->{gen} // 'none') if ($ec->{gen} // 'none') ne ($eo->{gen} // 'none');
    if (!$dc) { push @why, "no GEOM line without a menu pairs with the MENU close of gen " . ($eo->{gen} // '?'); }
    elsif ($dc->{i} < $ec->{i}) { push @why, "the GEOM line without a menu comes before the MENU close of gen " . ($eo->{gen} // '?'); }
  }
  $iv->{sound} = @why ? 0 : 1; $iv->{why} = [@why];
  push @n11, @why;
  if ($iv->{sound}) {
    my $g = $do->{line}{g}; $iv->{G} = $g; $iv->{body} = $do->{line}{body}; $iv->{menu} = $do->{line}{menu};
    my $from = $do->{i}; my $to = $dc ? $dc->{i} : 1e12; my $moved = 0; my @changes; my @inside;
    for my $l (@L) {
      next unless $l->{t} eq 'GEOM' && $l->{i} > $from && $l->{i} < $to;
      push @inside, { line => $l->{i}, differs => ($l->{g} ne $g ? 1 : 0), text => $l->{g} };
      if ($l->{g} ne $g) { $moved++; push @changes, $l->{g}; }
    }
    $iv->{frozen} = ($moved == 0 && !$eo->{seed}) ? 1 : 0; $iv->{inside_geoms} = $moved; $iv->{geoms_inside} = \@inside;
  } else { $iv->{frozen} = 0; $iv->{inside_geoms} = 0; $iv->{geoms_inside} = []; }
  $iv->{judged} = ($iv->{sound} && $iv->{frozen}) ? 1 : 0;
  $IV{$eo->{gen}} = $iv if defined $eo->{gen};
  push @IVS, $iv;
}
# lines naming a gen no opening of the window or its seed carries
for my $l (@L) {
  next unless ($l->{t} eq 'MENU' && ($l->{k} eq 'hover' || $l->{k} eq 'pick')) || ($l->{t} eq 'MOUSE-IGNORED' && ($l->{f}{why} // '') =~ /^menu-/);
  my $g = $l->{f}{gen};
  push @n11, "a " . ($l->{t} eq 'MENU' ? $l->{k} : 'menu delivery') . " line names gen " . ($g // 'none') . ", which no opening of the window carries" unless defined $g && $GENS{$g};
}
my $opened_in_window = scalar(grep { $_->{t} eq 'open' && !$_->{seed} } @E);

# ---- N8: an interval that is not frozen, or was already shown at the start
my @n8;
for my $iv (@IVS) {
  if ($iv->{seedopen}) { push @n8, "gen " . ($iv->{gen} // '?') . " was already shown when the window began"; }
  elsif ($iv->{sound} && !$iv->{frozen}) { push @n8, "gen " . ($iv->{gen} // '?') . ": " . $iv->{inside_geoms} . " GEOM line(s) inside the interval differ from the one that showed the menu"; }
}

# ---- calibration (5.5), picks only
my ($cal_ok, $cal_miss, $cal_n) = (0, 0, 0); my @cal;
for my $p (@PICKS) {
  my $iv = $IV{$p->{gen} // ''}; next unless $iv && $iv->{judged};
  my $c = $p->{line}{click}; next unless $c;
  $cal_n++;
  my $m = $iv->{menu}; my $dist;
  if (defined $c->{x} && defined $c->{y}) {
    my ($dx, $dy) = (0, 0);
    $dx = $m->[0] - $c->{x} if $c->{x} < $m->[0]; $dx = $c->{x} - ($m->[0] + $m->[2]) if $c->{x} > $m->[0] + $m->[2];
    $dy = $m->[1] - $c->{y} if $c->{y} < $m->[1]; $dy = $c->{y} - ($m->[1] + $m->[3]) if $c->{y} > $m->[1] + $m->[3];
    $dist = sprintf('%.2f', sqrt($dx * $dx + $dy * $dy));
  }
  if (clear_in($iv->{menu}, $c->{x}, $c->{y})) { $cal_ok++; push @cal, { id => $p->{id}, result => 'success', outside_distance_pt => $dist }; }
  elsif (clear_out($iv->{menu}, $c->{x}, $c->{y})) { $cal_miss++; push @cal, { id => $p->{id}, result => 'miss', outside_distance_pt => $dist }; }
  else { push @cal, { id => $p->{id}, result => 'boundary', outside_distance_pt => $dist }; }
}
my $cal_proven = ($cal_ok >= 1 && $cal_miss == 0) ? 1 : 0;

# ---- X1's frame cross-check (5.6), one prompted interval
my @PROMPTS; my $xmis = 0; my @xdetail;
for my $r (rd($A{prompts})) {
  my @f = split ' ', $r; next unless @f >= 3 && $f[0] eq 'PROMPT';
  my %pf; for my $x (@f[3 .. $#f]) { $pf{$1} = $2 if $x =~ /^([a-z]+)=(.*)$/; }
  push @PROMPTS, { n => $f[1] + 0, word => $f[2], sigma => num($pf{sigma}), gen => $pf{gen}, wh => $pf{wh} };
}
my @xcheck;
for my $pr (@PROMPTS) {
  my $iv = $IV{$pr->{gen} // ''}; next unless $iv && $iv->{judged};
  my @w;
  for my $r (rd(($A{x1dir} // '') . "/x1-" . $pr->{n} . ".txt")) {
    my @f = split ' ', $r; next unless @f >= 8 && $f[0] eq 'WINDOW' && $f[1] eq $P0 && $f[3] eq '1';
    push @w, { x => $f[4] + 0, y => $f[5] + 0, w => $f[6] + 0, h => $f[7] + 0 };
  }
  my $res = 'matched'; my $why = '';
  if (@w != 3) { $res = 'mismatch'; $why = "the agent has " . scalar(@w) . " on-screen windows in X1's list, three expected (stage, body, menu)"; }
  else {
    my @s = sort { $b->{w} * $b->{h} <=> $a->{w} * $a->{h} } @w; shift @s;
    my $m = $iv->{menu}; my $b = $iv->{body};
    my ($menuw) = grep { abs($_->{w} - $m->[2]) <= 0.5 && abs($_->{h} - $m->[3]) <= 0.5 } @s;
    my ($bodyw) = grep { !$menuw || $_ != $menuw } @s;
    if (!$menuw) { $res = 'mismatch'; $why = "no window of the menu's size in X1's list"; }
    elsif (abs($menuw->{x} - $m->[0]) > 0.5) { $res = 'mismatch'; $why = "the menu window's x is " . $menuw->{x} . ", menu= says " . $m->[0]; }
    elsif (!$b || !$bodyw) { $res = 'mismatch'; $why = "no body rectangle to compare"; }
    elsif (abs($bodyw->{x} - $b->[0]) > 0.5 || abs($bodyw->{w} - $b->[2]) > 0.5 || abs($bodyw->{h} - $b->[3]) > 0.5) { $res = 'mismatch'; $why = "the body window is x=" . $bodyw->{x} . " w=" . $bodyw->{w} . " h=" . $bodyw->{h} . ", body= says " . join(',', @$b); }
  }
  push @xcheck, { prompt => $pr->{n}, gen => $pr->{gen}, result => $res, why => $why };
  if ($res eq 'mismatch') { $xmis = 1; push @xdetail, "prompt $pr->{n}: $why"; }
}

# ---- transitions of the frontmost application
my @S; for my $raw (rd($A{samples})) { push @S, [$1 + 0, $2 + 0] if $raw =~ /^(\d+) (-?\d+)\s*$/; }
my @TR;
for my $i (1 .. $#S) {
  my ($pid, $was) = ($S[$i][1], $S[$i - 1][1]);
  next if $pid < 0 || $was < 0 || $pid == $was;
  next if $pid eq $P0 || ($P1 ne '' && $pid eq $P1);
  push @TR, { T => $S[$i][0], pid => $pid };
}
sub landing {
  my ($c) = @_;
  for my $tr (@TR) { next if $tr->{T} < $c->{ts} - $EARLY; my $d = $tr->{T} - $c->{ts}; return ($d <= $LATE ? 1 : 0, $d, $tr); }
  return (0, undef, undef);
}

# ---- kind 1: right-click
my ($k1, @k1why) = (0);
for my $iv (@IVS) {
  my $eo = $iv->{eopen};
  if (!$iv->{judged}) { next; }
  my $c = $eo->{line}{click}; my $how = $eo->{line}{f}{how} // '';
  if (!$c) { push @k1why, "gen $iv->{gen}: no CLICK pairs with its MENU-open"; next; }
  my $consistent = ($how eq 'right' && $c->{button} eq 'right') || ($how eq 'control' && $c->{button} eq 'left' && $c->{ctrl} == 1);
  if ($consistent) { $k1++; $iv->{k1} = 1; } else { push @k1why, "gen $iv->{gen}: MENU-open says how=$how, the CLICK is button=$c->{button} ctrl=$c->{ctrl}"; }
}

# ---- kind 2: hover
my ($k2, @k2why) = (0);
for my $iv (@IVS) {
  next unless $iv->{judged};
  my %seenkv; my $to = $iv->{eclose} ? $iv->{eclose}{i} : 1e12;
  for my $l (@L) { next unless $l->{t} eq 'MENU' && $l->{k} eq 'hover' && ($l->{f}{gen} // '') eq $iv->{gen} && $l->{i} > $iv->{eopen}{i} && $l->{i} < $to; $seenkv{($l->{f}{key} // '') . '=' . ($l->{f}{value} // '')} = 1; }
  $iv->{hovers} = scalar(keys %seenkv);
  if (scalar(keys %seenkv) >= 2) { $k2++; } else { push @k2why, "gen $iv->{gen}: " . scalar(keys %seenkv) . " distinct hovered item(s)"; }
}

# ---- kind 3: item click
my ($k3, @k3why) = (0); my @pickrows;
for my $p (@PICKS) {
  my $iv = $IV{$p->{gen} // ''}; my $c = $p->{line}{click}; my $why = '';
  my @w = @{$WRITES{$p->{id}} || []}; my $wexit = @w ? ($w[0]{f}{exit} // 'none') : undef;
  my $done = completions($p->{id});
  if (!$iv || !$iv->{judged}) { $why = "its interval proves nothing"; }
  elsif (!$c) { $why = "no CLICK pairs with it"; }
  elsif ($c->{button} ne 'left' || $c->{ctrl} != 0) { $why = "its CLICK is not a plain left click"; }
  elsif (!clear_in($iv->{menu}, $c->{x}, $c->{y})) { $why = "its CLICK is not clearly inside menu="; }
  elsif (!$cal_proven) { $why = "calibration is not proven, so no item click counts"; }
  elsif (!defined $wexit) { $why = $done ? "dropped by a newer pick of its key" : "no completion"; }
  elsif ($wexit ne '0') { $why = "its write exited $wexit"; }
  if ($why eq '') { $k3++; } else { push @k3why, "pick $p->{id}: $why"; }
  my $delay = @w ? $w[0]{seen}{sig} - $p->{line}{seen}{sig} : undef;
  push @pickrows, { id => $p->{id}, key => $p->{key}, gen => $p->{gen}, completions => $done, write_exit => $wexit, counted => ($why eq '' ? 1 : 0), why => $why, pick_to_write_ms => $delay };
}

# ---- kind 4: outside click
my ($k4, @k4why) = (0);
for my $l (@L) {
  next unless $l->{t} eq 'MENU' && $l->{k} eq 'close' && ($l->{f}{reason} // '') eq 'outside';
  my $g = $l->{f}{gen} // ''; my $iv = $IV{$g}; my $c = $l->{click}; my $why = '';
  if (!$iv || !$iv->{judged}) { $why = "gen $g proves nothing"; }
  elsif (!$iv->{eclose} || $iv->{eclose}{line} != $l) { $why = "it is not the close of the opening it names (gen $g)"; }
  elsif (!$c) { $why = "no CLICK pairs with it"; }
  else {
    # later than both the MENU open line's et and the et of the CLICK that opened the interval (a pairing is within 0.5 ms, not an
    # equality): the opening CLICK alone could let a click within the tolerance count that the MENU line rejects (Codex round 3)
    my $oc = $iv->{eopen}{line}{click};
    my $eto = num($iv->{eopen}{line}{f}{et}); $eto = $oc->{et} if $oc && defined $eto && $oc->{et} > $eto;
    my ($ok, $d) = landing($c);
    if (!defined $eto || !($c->{et} > $eto + $TOL)) { $why = "its et is not later than both the MENU open's et and the et of the click that opened gen $g by more than the tolerance"; }
    elsif (taken($c)) { $why = "an agent window took the click"; }
    elsif (!clear_out($iv->{body}, $c->{x}, $c->{y}) || !clear_out($iv->{menu}, $c->{x}, $c->{y})) { $why = "the click is not clearly outside body= and menu="; }
    elsif (!$ok) { $why = defined $d ? "no landing within [t_s-100, t_s+500] ms (signed delay $d ms)" : "no other application came to the front"; }
    elsif (!$cal_proven) { $why = "calibration is not proven"; }
    $c->{landing_delay} = $d;
  }
  if ($why eq '') { $k4++; } else { push @k4why, "close of gen $g: $why"; }
}

# ---- kind 5: typing
my ($k5, @k5why) = (0); my @keyrows;
for my $r (rd($A{keys})) {
  my @f = split ' ', $r; next unless @f >= 2 && $f[0] eq 'KEY';
  my %kf; for my $x (@f[2 .. $#f]) { $kf{$1} = $2 if $x =~ /^([a-z_]+)=(.*)$/s; }
  my ($pr) = grep { $_->{word} eq $f[1] } @PROMPTS; my $why = ''; my $clause = '';
  my $sx2 = num($kf{sigma});
  if (!$pr) { $why = "the word is not one the check printed"; }
  else {
    my $iv = $IV{$pr->{gen} // ''};
    if (!$iv || !$iv->{judged}) { $why = "the interval it was printed for proves nothing"; }
    else {
      my $m = $iv->{menu}; my $seenwin = 0;
      for my $wh (split /,/, ($kf{menu_windows} // '')) { my ($w, $h) = split /x/, $wh; $seenwin = 1 if defined $w && defined $h && abs($w - $m->[2]) <= 0.5 && abs($h - $m->[3]) <= 0.5; }
      if (!$seenwin) { $why = "the menu window was not on screen at X2"; }
      else {
        my $lo = $pr->{sigma}; my $hi = (defined $sx2 ? $sx2 : $LASTSIG) + $LAG + $SETTLE;
        # clause (a): no other opening has a CLICK stamped between the prompt and the end of the read's margin
        for my $e (@E) { next unless $e->{t} eq 'open' && !$e->{seed} && $e->{gen} ne $iv->{gen}; my $c = $e->{line}{click}; next unless $c; if ($c->{ts} >= $lo && $c->{ts} <= $hi) { $why = "clause (a): a reopening click (gen $e->{gen}) lies between the prompt and the end of the read's margin"; $clause = 'a'; last; } }
        # clause (b) (R-TYPE): the opening the word was printed for has a CLICK that pairs with its MENU open
        if ($why eq '' && !$iv->{eopen}{line}{click}) { $why = "clause (b): no CLICK pairs with the MENU-open line of gen $iv->{gen}, the opening the word was printed for"; $clause = 'b'; }
        # clause (c) (R-TYPE): no opening numbered after the one the word was printed for (its gen above the PROMPT line's) has a CLICK stamped by the end of the read's margin, whatever the order of the clicks
        if ($why eq '') {
          for my $e (@E) { next unless $e->{t} eq 'open' && !$e->{seed} && defined num($e->{gen}) && defined num($pr->{gen}) && num($e->{gen}) > num($pr->{gen}); my $c = $e->{line}{click}; next unless $c; if ($c->{ts} <= $hi) { $why = "clause (c): the opening of gen $e->{gen} came after gen $pr->{gen}, the opening the word was printed for, and its click was stamped by the end of the read's margin"; $clause = 'c'; last; } }
        }
      }
    }
  }
  if ($why eq '') { $k5++; } else { push @k5why, "word $f[1]: $why"; }
  push @keyrows, { word => $f[1], sigma => $sx2, menu_windows => $kf{menu_windows}, counted => ($why eq '' ? 1 : 0), why => $why, rejected_by_clause => $clause };
}
if (!@keyrows) { push @k5why, (scalar(@PROMPTS) ? "the prompted word was never read" : "no word was prompted (the menu window was never seen on screen at X1, or stdin is not a terminal)") . (length($A{reader} // '') ? " [" . $A{reader} . "]" : ''); }

# ---- F1, F2
my (@f1, @f2);
my $gate = ($cal_proven && !$xmis) ? 1 : 0;
for my $l (@L) {
  my $is_pick = ($l->{t} eq 'MENU' && $l->{k} eq 'pick');
  my $is_menu = ($l->{t} eq 'MOUSE-IGNORED' && ($l->{f}{why} // '') =~ /^menu-/);
  next unless $is_pick || $is_menu;
  my $iv = $IV{$l->{f}{gen} // ''}; my $c = $l->{click};
  next unless $iv && $iv->{judged} && $c;
  if ($gate && clear_out($iv->{body}, $c->{x}, $c->{y}) && clear_out($iv->{menu}, $c->{x}, $c->{y}) && defined $c->{x}) {
    push @f1, "click $c->{n} at ($c->{x},$c->{y}) was taken by the menu window (gen $iv->{gen}), outside body=" . join(',', @{$iv->{body} || []}) . " and menu=" . join(',', @{$iv->{menu}});
    $c->{f1} = 1;
  }
}
sub place_click {
  my ($c) = @_;
  for my $iv (@IVS) {
    next unless $iv->{judged};
    my $so = $iv->{eopen}{line}{seen};
    next unless $c->{ts} - $W >= $so->{hi};
    my $sclose = $iv->{eclose} ? $iv->{eclose}{line}{seen}{lo} : $LASTSIG;
    next unless $c->{ts} + 2 * $W <= $sclose;
    my $near = 0;
    for my $e (@E) {
      next if $e->{seed}; next if $e == $iv->{eopen} || (defined $iv->{eclose} && $e == $iv->{eclose});
      my $s = $e->{line}{seen}; if ($s->{lo} - $W < $c->{ts} && $c->{ts} < $s->{hi} + $W) { $near = 1; last; }
    }
    next if $near;
    return $iv;
  }
  return undef;
}
# why a click no agent line names was left unclassified (evidence only): for every judged interval, the inequalities of 5.3 that failed, with their numbers
sub place_why {
  my ($c) = @_; my @w;
  for my $iv (@IVS) {
    next unless $iv->{judged};
    my $so = $iv->{eopen}{line}{seen};
    my $sclose = $iv->{eclose} ? $iv->{eclose}{line}{seen}{lo} : $LASTSIG;
    my @f;
    push @f, "t_s - W = " . ($c->{ts} - $W) . " is before the open's first-seen bound " . $so->{hi} if !($c->{ts} - $W >= $so->{hi});
    push @f, "t_s + 2W = " . ($c->{ts} + 2 * $W) . " is after the close's first-seen bound " . $sclose if !($c->{ts} + 2 * $W <= $sclose);
    for my $e (@E) {
      next if $e->{seed}; next if $e == $iv->{eopen} || (defined $iv->{eclose} && $e == $iv->{eclose});
      my $s = $e->{line}{seen};
      push @f, "within W of the " . $e->{t} . " of gen " . ($e->{gen} // '?') . " (first seen between " . $s->{lo} . " and " . $s->{hi} . ")" if $s->{lo} - $W < $c->{ts} && $c->{ts} < $s->{hi} + $W;
    }
    push @w, "gen $iv->{gen}: " . (@f ? join(' and ', @f) : 'every inequality holds');
  }
  push @w, 'no interval of the window can be judged' unless @w;
  return \@w;
}
# the placement of a click an agent line names (5.3): a menu-window delivery or a pick is placed by its line's gen, an outside close by its own gen; a body-window delivery and a MENU open are not placed
for my $c (@C) {
  next unless named($c);
  my $gen;
  for my $l (@{$c->{lines}}) { next unless $l->{role} eq 'pick' || $l->{role} eq 'delivery-menu' || $l->{role} eq 'close-outside'; $gen = $l->{f}{gen} // 'none'; last; }
  if (defined $gen) { $c->{placed} = $gen; $c->{placed_by} = 'the gen its agent line names'; }
  else { $c->{placed} = 'not-placed'; $c->{placed_by} = 'a body-window delivery or the opening click is not placed (5.3)'; }
}
for my $c (@C) {
  next if named($c);
  my $iv = place_click($c); $c->{placed} = $iv ? $iv->{gen} : 'unclassified';
  $c->{placed_by} = $iv ? "the sampler's time band (5.3)" : 'no agent line names it'; $c->{placed_why} = place_why($c) unless $iv;
  next unless $iv && $gate && defined $c->{x};
  if (clear_out($iv->{body}, $c->{x}, $c->{y}) && clear_out($iv->{menu}, $c->{x}, $c->{y})) {
    push @f2, "click $c->{n} at ($c->{x},$c->{y}) came while gen $iv->{gen} was shown and no agent line names it; the menu stayed open";
    $c->{f2} = 1;
  }
}

# ---- the landing of every click (evidence): the first transition at or after t_s - 100 ms and its signed delay
for my $c (@C) { my ($ok, $d, $tr) = landing($c); $c->{landing_ok} = $ok; $c->{landing_delay} = $d if defined $d; $c->{landing_pid} = $tr ? $tr->{pid} : undef; }

# ---- N13: every click accounted by a line or by a transition
my @cand = grep { !taken($_) } @C;
my @unacc; my %acc_by;
# the transition a click owns as the only candidate of its cause window (undef when it owns none)
sub tr_account {
  my ($c) = @_;
  for my $tr (@TR) {
    next unless $tr->{T} >= $c->{ts} - $EARLY && $tr->{T} <= $c->{ts} + $LATE;
    my @in = grep { in_cause($tr->{T}, $_->{ts}) } @cand;
    if (@in == 1 && $in[0] == $c) { return "transition at $tr->{T}"; }
  }
  return undef;
}
# for a click nothing accounts for (7.5): the nearest MENU open and close by the sampler's time, and every transition its landing band holds with the candidates of that transition's cause window
sub n13_evidence {
  my ($c) = @_; my %near;
  for my $e (@E) {
    next if $e->{seed};
    my $s = $e->{line}{seen}{sig}; my $d = $c->{ts} - $s;
    if (!$near{$e->{t}} || abs($d) < abs($near{$e->{t}}{delta_ms})) { $near{$e->{t}} = { gen => $e->{gen}, line => $e->{i}, first_seen_sigma_ms => $s, delta_ms => $d }; }
  }
  my @bands;
  for my $tr (@TR) {
    next unless $tr->{T} >= $c->{ts} - $EARLY && $tr->{T} <= $c->{ts} + $LATE;
    push @bands, { t_ms => $tr->{T}, pid => $tr->{pid}, candidates_in_cause_window => [ map { $_->{n} } grep { in_cause($tr->{T}, $_->{ts}) } @cand ] };
  }
  return { nearest_open => $near{open}, nearest_close => $near{close}, transitions_in_landing_band => \@bands };
}
sub n13_text {
  my ($e) = @_; my @p;
  for my $k ('nearest_open', 'nearest_close') { my $n = $e->{$k}; push @p, ($k eq 'nearest_open' ? 'nearest open' : 'nearest close') . ($n ? " gen " . ($n->{gen} // '?') . " (click t_s " . ($n->{delta_ms} >= 0 ? '+' : '') . $n->{delta_ms} . " ms from its first-seen stamp)" : ' none'); }
  push @p, scalar(@{$e->{transitions_in_landing_band}}) ? "transition(s) in its landing band: " . join(', ', map { "$_->{t_ms} ms shared with clicks [" . join(',', @{$_->{candidates_in_cause_window}}) . "]" } @{$e->{transitions_in_landing_band}}) : 'no transition in its landing band';
  return join('; ', @p);
}
for my $c (@C) {
  $c->{acc_tr} = tr_account($c);
  if (scalar(@{$c->{lines}})) { $acc_by{$c->{n}} = 'line'; next; }
  if (defined $c->{acc_tr}) { $acc_by{$c->{n}} = $c->{acc_tr}; next; }
  push @unacc, $c;
  $acc_by{$c->{n}} = 'none';
  $c->{n13} = n13_evidence($c);
}

# ---- frontmost-changed in menu mode: a transition no click without a delivery line explains
my @unexplained;
for my $tr (@TR) {
  my @why = grep { $tr->{T} >= $_->{ts} - $EARLY && $tr->{T} <= $_->{ts} + $LATE } @cand;
  push @unexplained, $tr unless @why;
}

# ---- N7
my @n7 = grep { $_->{noclick} && $_->{role} ne 'stale' } @ETLINES;

# ---- N12
my @n12;
for my $p (@PICKS) { my $n = completions($p->{id}); push @n12, "pick $p->{id} has $n completion(s)" if $n != 1; }

# ---- the rows
my $has_open = $opened_in_window;
if (!$has_open) { notrun('menu-not-used', "no MENU-open line in the window: the menu was not used"); }
else {
  notrun('right-click-unobserved', "no right-click was observed: " . (join('; ', @k1why) || 'no counted interval')) unless $k1;
  notrun('hover-unobserved', "hover was not observed on two different items: " . (join('; ', @k2why) || 'no counted interval')) unless $k2;
  notrun('item-click-unobserved', "no counted item click: " . (join('; ', @k3why) || 'no pick')) unless $k3;
  notrun('outside-click-unobserved', "no counted outside click: " . (join('; ', @k4why) || 'no outside close')) unless $k4;
  notrun('typing-unobserved', "typing was not observed: " . (join('; ', @k5why) || 'no word')) unless $k5;
}
notrun('click-monitor-missed', scalar(@n7) . " agent line(s) carry an et with no CLICK of that et: " . join('; ', map { "line " . $_->{i} . " (" . $_->{role} . " et=" . $_->{et} . ")" } @n7[0 .. ($#n7 > 4 ? 4 : $#n7)])) if @n7;
notrun('menu-geometry-unfrozen', "an interval of the window cannot be judged: " . join('; ', @n8)) if @n8;
notrun('geometry-unproven', join('; ', (($cal_n && !$cal_proven) ? ("calibration: $cal_ok success(es), $cal_miss miss(es) of $cal_n pick(s)") : ()), @xdetail)) if ($cal_n && !$cal_proven) || $xmis;
notrun('menu-open-at-end', "the last MENU line leaves the menu shown after the settle and the end wait") if $efinal eq 'open';
notrun('menu-state-unproven', join('; ', @n11)) if @n11;
notrun('menu-write-missing', join('; ', @n12)) if @n12;
notrun('click-unaccounted', scalar(@unacc) . " CLICK(s) are named by no agent line and owned by no transition: " . join('; ', map { "click $_->{n} at ($_->{x},$_->{y}) t=$_->{ts} et=$_->{etraw} [" . n13_text($_->{n13}) . "]" } @unacc[0 .. ($#unacc > 4 ? 4 : $#unacc)])) if @unacc;
notrun('frontmost-changed', scalar(@unexplained) . " transition(s) of the frontmost application to another app follow no click: " . join('; ', map { "pid $_->{pid} at $_->{T} ms" } @unexplained[0 .. ($#unexplained > 4 ? 4 : $#unexplained)])) if @unexplained;
fail('click-taken-outside-hit-region', scalar(@f1) . " click(s) were taken by the menu window outside the declared rectangles: " . join('; ', @f1)) if @f1;
fail('menu-stayed-open', scalar(@f2) . " click(s) outside the menu left it open: " . join('; ', @f2)) if @f2;
if ($efinal eq 'close' && ($dfinal eq 'open' || ($A{endwin} // 0) > 2)) {
  fail('menu-left-after-close', "the last MENU line closed the menu, but " . ($dfinal eq 'open' ? "the last GEOM line still declares it" : "the end read shows " . $A{endwin} . " on-screen windows of the agent"));
}

# ---- evidence
$EV{counts} = { right_click => $k1, hover => $k2, item_click => $k3, outside_click => $k4, typing => $k5 };
$EV{why_not_counted} = { right_click => \@k1why, hover => \@k2why, item_click => \@k3why, outside_click => \@k4why, typing => \@k5why };
$EV{calibration} = { successes => $cal_ok, misses => $cal_miss, picks => $cal_n, proven => $cal_proven, picks_detail => \@cal };
$EV{x1_cross_check} = { prompts => \@xcheck, mismatched => $xmis };
$EV{intervals} = [ map { +{ gen => $_->{gen}, sound => $_->{sound}, frozen => $_->{frozen}, judged => $_->{judged}, shown_at_start => $_->{seedopen}, geoms_inside_that_differ => $_->{inside_geoms}, geoms_inside_total => scalar(@{$_->{geoms_inside}}), geoms_inside => $_->{geoms_inside}, why_unsound => $_->{why}, geometry => $_->{G}, k1 => ($_->{k1} // 0), hovers => ($_->{hovers} // 0) } } @IVS ];
$EV{e_sequence} = [ map { +{ t => $_->{t}, gen => $_->{gen}, line => $_->{i}, seed => ($_->{seed} // 0) } } @E ];
$EV{d_sequence} = [ map { +{ t => $_->{t}, gen => $_->{gen}, line => $_->{i}, seed => ($_->{seed} // 0) } } @D ];
$EV{picks} = \@pickrows;
$EV{clicks_on} = $clickson;
$EV{clicks} = [ map { +{ n => $_->{n}, t_ms => $_->{ts}, et => $_->{etraw}, button => $_->{button}, ctrl => $_->{ctrl} + 0, x => $_->{x}, y => $_->{y}, target => $_->{target},
  lines => [ map { $_->{role} . '@' . $_->{i} } @{$_->{lines}} ], accounted_by => ($acc_by{$_->{n}} // 'none'), accounted_by_transition => ($_->{acc_tr} // undef), n13 => ($_->{n13} // undef), placed => ($_->{placed} // undef), placed_by => ($_->{placed_by} // undef), placed_why => ($_->{placed_why} // undef), landing_delay_ms => ($_->{landing_delay} // undef), landing_pid => ($_->{landing_pid} // undef), landed => ($_->{landing_ok} // 0) } } @C ];
$EV{transitions} = [ map { +{ t_ms => $_->{T}, pid => $_->{pid} } } @TR ];
$EV{unaccounted_clicks} = [ map { $_->{n} } @unacc ];
{
  my @swap; my @byts = sort { $a->{ts} <=> $b->{ts} } grep { defined $_->{et} } @C;
  for my $i (0 .. $#byts - 1) { for my $j ($i + 1 .. $#byts) { push @swap, "clicks $byts[$i]{n} and $byts[$j]{n}" if $byts[$i]{et} > $byts[$j]{et}; } }
  my $maxd = 0; for my $l (@ETLINES) { next unless $l->{click}; my $d = abs($l->{click}{et} - $l->{et}) * 1000; $maxd = $d if $d > $maxd; }
  $EV{et_order_differs_from_ts_order} = \@swap; $EV{largest_et_delta_ms} = $maxd + 0;
}
$EV{prompts} = \@PROMPTS; $EV{keys} = \@keyrows;
$EV{stale_lines} = [ map { $_->{txt} } grep { $_->{t} eq 'MENU' && $_->{k} eq 'stale' } @L ];
$EV{writes_and_drops} = [ map { $_->{txt} } grep { $_->{t} eq 'MENU' && ($_->{k} eq 'write' || $_->{k} eq 'drop') } @L ];
$EV{final_state} = { e => $efinal, d => $dfinal, agent_windows_at_end => ($A{endwin} // undef) };
$EV{end_cross_check_gate_open} = $gate;
$EV{window} = { countdown_ended_early => ($A{early} // 0) + 0, settle_ended_by => ($A{settle} // ''), window_end_ms => ($A{winend} // 0) + 0, reader_note => ($A{reader} // ''),
  settle => { anchor_ms => num($A{settle_anchor}), deadline_a_ms => num($A{settle_a}), pick_wait_deadline_ms => num($A{settle_pick}), stamp_at_the_last_test_ms => num($A{settle_stamp}) } };
finish_output();

sub finish_output {
  print "FAIL\t$_->[0]\t$_->[1]\n" for @FAIL;
  print "NOTRUN\t$_->[0]\t$_->[1]\n" for @NOTRUN;
  print "EVIDENCE\t" . JSON::PP->new->canonical->allow_nonref->encode(\%EV) . "\n";
}
PERL

main() {
  local real=0 arg seconds="$DEFAULT_SECONDS" given=0 menu=0
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --real) real=1 ;;
      --menu) menu=1 ;;
      --seconds)
        shift
        seconds="${1:-}"
        given=1
        if ! ck_is_uint "$seconds" || [ "$seconds" -lt 1 ] || [ "$seconds" -gt 600 ]; then usage; return 64; fi ;;
      *) usage; return 64 ;;
    esac
    shift
  done
  MENU_MODE="$menu"
  if [ "$menu" = 1 ]; then
    [ "$given" = 1 ] || seconds="$DEFAULT_MENU_SECONDS"
    SCOPE="$SCOPE$SCOPE_MENU"
    # the reader of the typed word takes the terminal through fd 3 (a background job of a non-interactive shell gets /dev/null as stdin)
    { exec 3<&0; } 2>/dev/null || exec 3</dev/null
  fi
  if [ -z "${CLAWD_ATTENDED_SANDBOX:-}" ]; then
    if [ "$real" != 1 ]; then
      ck_warn "attended-check: refused (64): real mode needs the explicit flag --real. Nothing was read or touched."
      return 64
    fi
  elif [ "$real" = 1 ]; then
    ck_warn "attended-check: refused (64): --real cannot be combined with a sandbox run. Nothing was touched."
    return 64
  fi
  resolve_mode || return $?
  SECONDS_WINDOW="$seconds"
  START_EPOCH="$(date +%s)"
  mkdir -p "$EVID" || { ck_warn "attended-check: cannot create $EVID"; return 64; }
  EVIDENCE_FILE="$EVID/attended-check-$START_EPOCH-$$.json"
  WORK="$EVID/attended-check-work/$START_EPOCH-$$"
  SAMPLES="$WORK/samples.txt"
  WINDOW_LINES_FILE="$WORK/window-input-lines.txt"
  POLLS_FILE="$WORK/log-polls.txt"; PROMPTS_FILE="$WORK/prompts.txt"; KEYS_LOG="$WORK/keys.log"; SEED_FILE="$WORK/seed-lines.txt"
  MENU_WIN_FILE="$WORK/menu-window-lines.txt"; MENU_RESULT_FILE="$WORK/menu-result.txt"
  exec 4>&1 5>&2
  trap on_signal INT TERM HUP
  if preflight; then
    run_window || true
  fi
  finish
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
