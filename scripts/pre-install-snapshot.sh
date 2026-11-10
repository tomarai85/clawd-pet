#!/bin/bash
# pre-install-snapshot.sh: read-only listing of the places `clawd-pet install` writes, for done-bar item 6 (c) (round brief r4 B.3).
#
# The main session runs it immediately before the user's real install. It writes .evidence/pre-install-listing-<epoch>.txt:
#   line 1   "pre-install listing <date> commit <short hash>" (a header; the comparison skips it)
#   then, for each install root ($ROOT, the marker, the plist, the CLI, in that order), either "absent: <path>" or the recursive listing
#     "dir: <path>", "file: <path> <bytes> <sha256>", "link: <path> -> <target>"
#   then "parent exists: <dir>" (or "parent missing: <dir>") for the three shared parents, and "label: loaded | not loaded".
# A later real uninstall (only when the user asks for one) is compared against that file with `--compare <file>`: both sides are listed, the
# retained logs (agent.log, agent.log.1) are left out and a $ROOT that holds nothing else counts as absent, and the script prints "equal"
# (exit 0) or the differences (exit 1).
#
# Real mode needs the flag `--real`; without it (and outside a sandbox run) the script refuses with 64 before reading anything. Tests run
# it in a sandbox with launchctl stubbed (see check-common.sh). Seams: CLAWD_SNAPSHOT_SANDBOX, CLAWD_LAUNCHCTL.
# It reads the file system and runs `launchctl list` only; it writes the one listing file.
#
# Usage: scripts/pre-install-snapshot.sh --real [--compare FILE]
# `source` this file to get the functions without running anything.

set -u
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CK_REPO="$REPO"
. "$REPO/scripts/check-common.sh"

LABEL="com.tomtim.clawd-pet"
SEAM_VARS="CLAWD_LAUNCHCTL"

resolve_mode() {
  ck_resolve_mode pre-install-snapshot CLAWD_SNAPSHOT_SANDBOX .snapshot-sandbox "$SEAM_VARS" "CLAWD_LAUNCHCTL" || return $?
  if [ "$CK_SANDBOX_MODE" = 1 ]; then LAUNCHCTL="$CLAWD_LAUNCHCTL"; EVID="$CK_SANDBOX/evidence"
  else LAUNCHCTL="/bin/launchctl"; EVID="$REPO/.evidence"; fi
  ROOT="$HOME/Library/Application Support/clawd-pet"
  MARKER="$HOME/Library/Application Support/clawd-pet.installing"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  CLI_PATH="$HOME/bin/clawd-pet"
  return 0
}

# describe PATH: one line for PATH, and for a directory one line for everything below it, sorted.
describe() {
  local p="$1" entry
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf 'absent: %s\n' "$p"; return 0; fi
  if [ -L "$p" ]; then printf 'link: %s -> %s\n' "$p" "$(/usr/bin/readlink "$p")"; return 0; fi
  if [ -d "$p" ]; then
    printf 'dir: %s\n' "$p"
    while IFS= read -r entry; do
      [ "$entry" != "$p" ] || continue
      describe_one "$entry"
    done < <(find "$p" -print | LC_ALL=C sort)
    return 0
  fi
  describe_one "$p"
}
describe_one() {
  local e="$1" size hash
  if [ -L "$e" ]; then printf 'link: %s -> %s\n'  "$e" "$(/usr/bin/readlink "$e")"
  elif [ -d "$e" ]; then printf 'dir: %s\n' "$e"
  elif [ -f "$e" ]; then
    size="$(ck_file_size "$e")"
    hash="$(/usr/bin/shasum -a 256 < "$e" 2>/dev/null | cut -d' ' -f1)"
    printf 'file: %s %s %s\n' "$e" "$size" "${hash:-unreadable}"
  else printf 'other: %s\n' "$e"; fi
}

# The body of a listing, exactly as the file holds it after its header.
listing_body() {
  local p
  for p in "$ROOT" "$MARKER" "$PLIST" "$CLI_PATH"; do describe "$p"; done
  for p in "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support"; do
    if [ -d "$p" ]; then printf 'parent exists: %s\n' "$p"; else printf 'parent missing: %s\n' "$p"; fi
  done
  if "$LAUNCHCTL" list "$LABEL" >/dev/null 2>&1; then echo "label: loaded"; else echo "label: not loaded"; fi
}

# Leaves the retained logs out of a body read from stdin, and turns a $ROOT that held nothing else into "absent".
without_retained_logs() {
  /usr/bin/awk -v root="$ROOT" '
    { line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        l = line[i]
        if (index(l, "file: " root "/agent.log ") == 1 || index(l, "file: " root "/agent.log.1 ") == 1) continue
        keep[++k] = l
      }
      others = 0
      for (i = 1; i <= k; i++) if (keep[i] != "dir: " root && index(keep[i], ": " root "/") > 0) others++
      for (i = 1; i <= k; i++) {
        if (keep[i] == "dir: " root && others == 0) print "absent: " root
        else print keep[i]
      }
    }'
}

main() {
  local real=0 compare="" arg out header now_body saved_body
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --real) real=1 ;;
      --compare) shift; compare="${1:-}"; [ -n "$compare" ] || { ck_warn "usage: scripts/pre-install-snapshot.sh --real [--compare FILE]"; return 64; } ;;
      *) ck_warn "usage: scripts/pre-install-snapshot.sh --real [--compare FILE]"; return 64 ;;
    esac
    shift
  done
  if [ -z "${CLAWD_SNAPSHOT_SANDBOX:-}" ]; then
    if [ "$real" != 1 ]; then
      ck_warn "pre-install-snapshot: refused (64): real mode needs the explicit flag --real. Nothing was read or touched."
      return 64
    fi
  elif [ "$real" = 1 ]; then
    ck_warn "pre-install-snapshot: refused (64): --real cannot be combined with a sandbox run. Nothing was touched."
    return 64
  fi
  resolve_mode || return $?
  if [ -n "$compare" ]; then
    [ -f "$compare" ] || { ck_warn "pre-install-snapshot: refused: $compare is not a file"; return 64; }
    mkdir -p "$EVID" || { ck_warn "pre-install-snapshot: cannot create $EVID"; return 64; }
    saved_body="$EVID/.pre-install-compare-saved.$$"; now_body="$EVID/.pre-install-compare-now.$$"
    /usr/bin/sed '/^pre-install listing /d' "$compare" | without_retained_logs > "$saved_body"
    listing_body | without_retained_logs > "$now_body"
    if diff "$saved_body" "$now_body" > "$now_body.diff"; then
      ck_say "pre-install-snapshot: equal (the retained logs agent.log and agent.log.1 are not compared)"
      rm -- "$saved_body" "$now_body" "$now_body.diff"
      return 0
    fi
    ck_say "pre-install-snapshot: DIFFERENT from $compare (< is the saved listing, > is now):"
    cat "$now_body.diff"
    rm -- "$saved_body" "$now_body" "$now_body.diff"
    return 1
  fi
  mkdir -p "$EVID" || { ck_warn "pre-install-snapshot: cannot create $EVID"; return 64; }
  out="$EVID/pre-install-listing-$(date +%s).txt"
  [ ! -e "$out" ] || out="$EVID/pre-install-listing-$(date +%s)-$$.txt"
  header="pre-install listing $(date '+%Y-%m-%d %H:%M:%S %Z') commit $(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  { printf '%s\n' "$header"; listing_body; } | ck_publish "$out" || { ck_warn "pre-install-snapshot: could not write $out"; return 64; }
  ck_say "pre-install-snapshot: wrote $out"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
