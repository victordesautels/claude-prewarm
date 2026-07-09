# ---- time helpers ------------------------------------------------------------
to_min() { local h=${1%%:*} m=${1##*:}; echo $((10#$h * 60 + 10#$m)); }
to_hm()  { printf '%02d:%02d\n' $(( $1 / 60 )) $(( $1 % 60 )); }
now_min() { to_min "$(date '+%H:%M')"; }
today_epoch() { date -j -f '%Y-%m-%d %H:%M' "$(date +%F) $1" +%s; }   # epoch of today @ HH:MM
date_epoch() { date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null || true; }
date_dow() { date -j -f '%Y-%m-%d' "$1" +%w 2>/dev/null || echo 9; }
epoch_day() { date -r "$1" '+%F'; }
json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
json_bool() { [ "${1:-}" = "true" ] && printf true || printf false; }
mode_interval_min() {
  echo "$INTERVAL"
}
mode_label() {
  case "$MODE" in
    daily)   echo "daily: one prewarm per day" ;;
    standard) echo "standard: back-to-back 5h windows, no gaps, during active hours" ;;
    manual)     echo "manual: no scheduled pings" ;;
    *)          echo "$MODE" ;;
  esac
}
read_lf() {   # sanitized last-fire epoch — 0 if absent/empty/corrupt (never crashes arithmetic)
  local v; v="$( [ -f "$LAST_FIRE" ] && cat "$LAST_FIRE" 2>/dev/null || echo 0 )"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}
read_codex_lf() {
  local v; v="$( [ -f "$CODEX_LAST_FIRE" ] && cat "$CODEX_LAST_FIRE" 2>/dev/null || echo 0 )"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

# ---- real-usage awareness (reads Claude Code's local session logs) -----------
# The 5-hour window anchors to your FIRST message and is shared across Claude Code /
# claude.ai / Desktop. Claude Code appends to ~/.claude/projects/*.jsonl per turn, so
# these logs are a local, offline record of when you used Claude — the same source
# ccusage reads. We use them to skip a redundant ping when a window is already open
# from your own work, and to show the real window in `status`.

# Newest mtime across the logs — a cheap proxy for "when did I last touch Claude".
# Informational only (used for the status "activity" row), NOT for window math.
last_activity() {   # epoch of most recent activity; 0 if none (~10ms for 600 files)
  local dir="$CLAUDE_PROJECTS" m=0
  [ -d "$dir" ] || { echo 0; return; }
  m="$(find "$dir" -type f -name '*.jsonl' -print0 2>/dev/null \
       | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)" || true
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  echo "$m"
}

# Convert an ISO-8601 UTC timestamp ("2026-07-08T19:46:38.888Z") to epoch seconds.
iso_to_epoch() {   # $1 = iso string; empty output on failure
  local iso="${1%%.*}"; iso="${iso%Z}"
  date -u -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null || true
}

# Epoch at which the CURRENT usage window opened (its FIRST message), or 0 if no
# window is open right now. We must find the window's *first* message, not the last:
# the window closes exactly INTERVAL after it opens regardless of later messages.
# So we segment activity into windows — a session that starts >= INTERVAL after the
# current anchor opens a NEW window — and report the latest anchor if still open.
# Sources: the first message of each recent session log + our own last ping. Cheap:
# one `grep -m1` (stops at the first timestamp) + one date call per recent file.
# Any parse trouble degrades to "no open window", so we err toward firing, not gaps.
window_anchor() {
  local interval_s=$(( INTERVAL * 60 )) dir="$CLAUDE_PROJECTS" f iso ep
  local starts="" lf anchor=0 t nowE
  lf=$(read_lf); nowE=$(date +%s)
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      iso="$(grep -m1 -oE '"timestamp":"[^"]*"' "$f" 2>/dev/null | sed -E 's/.*"timestamp":"([^"]*)".*/\1/')" || true
      [ -n "$iso" ] || continue
      ep="$(iso_to_epoch "$iso")"
      [[ "$ep" =~ ^[0-9]+$ ]] && starts="${starts}${ep}"$'\n'
    done < <(find "$dir" -type f -name '*.jsonl' -mmin -720 2>/dev/null)
  fi
  [ "$lf" -gt 0 ] && starts="${starts}${lf}"$'\n'
  # walk starts ascending; a start >= anchor+INTERVAL opens a new window
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    { [ "$anchor" -eq 0 ] || [ "$t" -ge $(( anchor + interval_s )) ]; } && anchor="$t"
  done < <(printf '%s' "$starts" | sort -n)
  if [ "$anchor" -gt 0 ] && [ "$nowE" -lt $(( anchor + interval_s )) ]; then echo "$anchor"; else echo 0; fi
}

read_limit_until() {   # epoch to pause firing until (usage limit); 0 if none/corrupt
  local v; v="$( [ -f "$LIMIT_UNTIL" ] && cat "$LIMIT_UNTIL" 2>/dev/null || echo 0 )"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}
read_codex_limit_until() {
  local v; v="$( [ -f "$CODEX_LIMIT_UNTIL" ] && cat "$CODEX_LIMIT_UNTIL" 2>/dev/null || echo 0 )"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}
