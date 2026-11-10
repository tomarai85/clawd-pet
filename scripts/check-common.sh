# check-common.sh: shared by scripts/attended-check.sh, scripts/post-install-check.sh and scripts/pre-install-snapshot.sh.
# Sourced, never run. The sourcing script sets CK_REPO (the repo root) first.
#
# Mode. Real mode reads the real HOME and the real launchd domain and needs the explicit flag `--real`. Without `--real`, and outside a
# sandbox run, a script refuses with 64 before it reads anything but its arguments, so no test, loop or stray call reaches real mode by
# accident. Tests run a script in a sandbox: <sandbox> is a directory under $CK_REPO/.build that holds a marker file, HOME is
# <sandbox>/home, and EVERY external effect (launchctl, the window lister and frontmost sampler, lsappinfo, the clocks) comes from a stub
# named by a seam variable. Outside a sandbox any seam variable that is set is a refusal (64), so a stub value can never reach the real
# machine, and a sandbox run never takes `--real`.

ck_say() { printf '%s\n' "$*"; }
ck_warn() { printf '%s\n' "$*" >&2; }
ck_is_number() { case "${1:-}" in ''|*[!0-9.]*|.*|*.|*.*.*) return 1 ;; *) return 0 ;; esac; }
ck_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ck_now_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)'; }
ck_json_escape() { printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
ck_file_size() { /usr/bin/stat -f %z "$1" 2>/dev/null || printf '0'; }
ck_file_inode() { /usr/bin/stat -f %i "$1" 2>/dev/null || printf 'none'; }

# ck_resolve_mode NAME SANDBOX_VAR MARKER "SEAM VARS" "SEAMS THAT MUST BE EXECUTABLE"
# Sets CK_SANDBOX_MODE (0 real, 1 sandbox) and CK_SANDBOX. Returns 64 (and says why) when the mode cannot be trusted.
ck_resolve_mode() {
  local name="$1" sandbox_var="$2" marker="$3" seams="$4" executables="$5" v phys value
  value="${!sandbox_var:-}"
  CK_SANDBOX_MODE=0; CK_SANDBOX=""
  if [ -z "$value" ]; then
    for v in $seams; do
      if [ -n "${!v:-}" ]; then
        ck_warn "$name: refused: $v is set but this is not a sandbox run ($sandbox_var unset). Test seams never reach the real machine."
        return 64
      fi
    done
    return 0
  fi
  CK_SANDBOX_MODE=1
  if ! CK_SANDBOX="$(cd -P "$value" 2>/dev/null && pwd -P)"; then ck_warn "$name: refused: sandbox directory missing"; return 64; fi
  phys="$(cd -P "$CK_REPO/.build" 2>/dev/null && pwd -P)"
  case "$CK_SANDBOX" in "$phys"/*) ;; *) ck_warn "$name: refused: the sandbox must live under $CK_REPO/.build/"; return 64 ;; esac
  [ -f "$CK_SANDBOX/$marker" ] || { ck_warn "$name: refused: $CK_SANDBOX has no $marker marker"; return 64; }
  case "$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" in "$CK_SANDBOX/home") ;; *) ck_warn "$name: refused: HOME is not <sandbox>/home"; return 64 ;; esac
  for v in $seams; do
    [ -n "${!v:-}" ] || { ck_warn "$name: refused: sandbox run without the seam $v (every external effect must be stubbed)"; return 64; }
  done
  for v in $executables; do
    [ -x "${!v}" ] || { ck_warn "$name: refused: seam $v is not an executable file"; return 64; }
  done
  return 0
}

# ck_publish FINAL: reads stdin into FINAL through a .partial file and a rename, so a reader never sees half a file.
ck_publish() {
  local final="$1" tmp
  tmp="$(dirname "$final")/.$(basename "$final").partial.$$"
  cat > "$tmp" || return 1
  /bin/mv "$tmp" "$final"
}

# ck_windows LISTER: runs `LISTER windows` and prints its WINDOW lines, only when the output ends with its WINDOWS footer.
# Returns 2 when the lister failed or its output is truncated; a failed read is never an empty list.
ck_windows() {
  local out rc
  out="$("$1" windows 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 2
  case "$(printf '%s\n' "$out" | tail -n 1)" in "WINDOWS "[0-9]*) ;; *) return 2 ;; esac
  printf '%s\n' "$out" | /usr/bin/awk '$1 == "WINDOW"'
}

# ck_panel_of_pid PID WINDOW_LINES: "x y w h count" of the largest on-screen window owned by PID (count = how many there are), or nothing.
# That is the pet's STAGE window (since Sprint 4c the pet is two windows: the stage window, the largest, and a smaller body window), which
# the checks call "the panel"; its size can change while a motion plays.
ck_panel_of_pid() {
  printf '%s\n' "$2" | /usr/bin/awk -v pid="$1" '
    $1 == "WINDOW" && $2 == pid && $4 == 1 {
      count++; area = $7 * $8
      if (!found || area > best) { best = area; found = 1; x = $5; y = $6; w = $7; h = $8 }
    }
    END { if (found) print x, y, w, h, count }'
}

# ck_find_tool NAME: prefers the release build, falls back to the debug build. Prints the release path (which may not exist) when neither exists.
ck_find_tool() {
  local candidate
  for candidate in "$CK_REPO/.build/release/$1" "$CK_REPO/.build/debug/$1"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  printf '%s' "$CK_REPO/.build/release/$1"
  return 1
}

# ---- reasons: a verdict is FAIL when any FAIL reason exists, else NOT RUN when any NOT RUN reason exists, else PASS ----
FAILS=""
NOTRUNS=""
fail() { FAILS="$FAILS${FAILS:+
}$1: $2"; }
notrun() { NOTRUNS="$NOTRUNS${NOTRUNS:+
}$1: $2"; }
has_reason() { printf '%s\n' "$1" | grep -q "^$2:"; }

# ---- JSON writers (values are numbers, fixed words or single-line text) ----
jnum() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf 'null'; fi; }
jstr() { if [ -n "${1:-}" ]; then printf '"%s"' "$(ck_json_escape "$1")"; else printf 'null'; fi; }
jlist() { # newline-separated reasons -> a JSON array of strings
  local first=1 l
  printf '['
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$first" = 1 ]; then first=0; else printf ', '; fi
    printf '"%s"' "$(ck_json_escape "$l")"
  done < <(printf '%s\n' "$1")
  printf ']'
}
jcodes() { # newline-separated "code: detail" reasons -> a JSON array of the distinct codes, in order
  local first=1 c
  printf '['
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ "$first" = 1 ]; then first=0; else printf ', '; fi
    printf '"%s"' "$c"
  done < <(printf '%s\n' "$1" | /usr/bin/awk 'NF { i = index($0, ": "); c = i ? substr($0, 1, i - 1) : $0; if (!seen[c]++) print c }')
  printf ']'
}
jbool() { case "${1:-}" in 1) printf 'true' ;; 0) printf 'false' ;; *) printf 'null' ;; esac; }
jpanel() { # "x y w h count" -> an object, or null
  if [ -z "${1:-}" ]; then printf 'null'; return; fi
  set -- $1
  printf '{"x": %s, "y": %s, "w": %s, "h": %s, "windows_of_the_agent": %s}' "$1" "$2" "$3" "$4" "$5"
}

# ck_kill_job PID: sends TERM to PID only while it is a running background job of THIS shell (the shell's own job table answers, so a pid
# reused after the job ended is never signalled). `jobs -rp` prints one pid per line; they are joined first, so that a table of two jobs
# (the attended check's menu mode runs the sampler and a reader of the typed word) still finds either one.
ck_kill_job() {
  case " $(jobs -rp | tr '\n' ' ') " in *" $1 "*) kill -TERM "$1" 2>/dev/null ;; esac
  return 0
}
