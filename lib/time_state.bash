# ---- time helpers ------------------------------------------------------------
to_min() { local h=${1%%:*} m=${1##*:}; echo $((10#$h * 60 + 10#$m)); }
to_hm()  { printf '%02d:%02d\n' $(( $1 / 60 )) $(( $1 % 60 )); }
now_min() { to_min "$(date '+%H:%M')"; }
today_epoch() { date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%F) $1:00" +%s; }   # epoch of today @ HH:MM:00
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

# Epoch at which the CURRENT usage window opened (its FIRST message), or 0 if no
# window is open right now. We must find the window's *first* message, not the last:
# the window closes exactly INTERVAL after it opens regardless of later messages.
# So we replay the last day of activity in order — a message >= INTERVAL after the
# current anchor opens a NEW window — and report the latest anchor if still open.
# Activity is every real model reply in the session logs (synthetic error/limit
# replies excluded), not just each file's first line: that missed a resumed
# session and one that ran across a window boundary. Our own pings leave no
# session log (--no-session-persistence), so they come from ping_history; without
# them the replay drifts off the real window boundaries. This greps a day of logs
# (~2s on a heavy day), so callers check the cheap cadence conditions first. Any
# parse trouble degrades to "no open window", so we err toward firing, not gaps.
window_anchor() {
  local interval_s=$(( INTERVAL * 60 )) dir="$CLAUDE_PROJECTS" nowE
  nowE=$(date +%s)
  {
    if [ -d "$dir" ]; then
      # -a: a NUL-damaged log must not read as "Binary file matches"
      find "$dir" -type f -name '*.jsonl' -mmin -1440 -exec env LC_ALL=C grep -ah '"type":"assistant"' {} + \
        | LC_ALL=C grep -av '"model":"<synthetic>"' \
        | LC_ALL=C grep -aoE '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' || true
    fi
    ping_history
    read_lf
  } 2>/dev/null | awk -v cut=$(( nowE - 86400 )) '
    /^"timestamp":"/ {   # ISO-8601 UTC -> epoch via days-from-civil (BSD awk has no mktime)
      split(substr($0, 14), p, /[-T:]/)
      y = p[1] - (p[2] <= 2); mp = (p[2] > 2) ? p[2] - 3 : p[2] + 9
      era = int(y / 400); yoe = y - era * 400
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + int((153 * mp + 2) / 5) + p[3] - 1
      e = (era * 146097 + doe - 719468) * 86400 + p[4] * 3600 + p[5] * 60 + p[6]
      if (e >= cut) print e
      next
    }
    /^[0-9]+$/ { if ($0 + 0 >= cut) print $0 + 0 }' \
    | sort -n | awk -v iv="$interval_s" -v now="$nowE" '
    { if (a == 0 || $1 >= a + iv) a = $1 }
    END { print (a > 0 && now < a + iv) ? a : 0 }' || true
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
# Failure back-off file: "streak|retry_epoch|last_failure_epoch" (record_failure).
read_fail_until() {   # $1 = backoff file; epoch to hold retries until after a failed ping; 0 if none/corrupt
  local n v=0 rest
  [ -f "$1" ] && IFS='|' read -r n v rest < "$1" 2>/dev/null || true
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}
# A retry counts as due up to a minute early. The failing ping stamped its retry
# a second or two into its tick (after window_anchor), while a later tick checks
# at its start — taken exactly, the tick backoff-minutes on would see the retry
# a hair ahead and skip it, so every retry ran a tick late and one at the
# guardrail cutoff never ran. Ticks are 5 minutes apart, so a minute of slack
# never lets an earlier tick through.
retry_pending() {  # $1 = backoff file  $2 = epoch; true while the retry is still ahead
  [ "$(read_fail_until "$1")" -gt $(( $2 + 60 )) ]
}
read_fail_streak() {  # $1 = backoff file; consecutive failed pings; 0 if none/corrupt
  local n=0 rest
  [ -f "$1" ] && IFS='|' read -r n rest < "$1" 2>/dev/null || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}
