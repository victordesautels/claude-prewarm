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

# Epochs of the API requests in the last day of Claude Code session logs: one
# per real model reply (synthetic error/limit replies, "model":"<synthetic>",
# excluded), dated by when its request was SENT — the user record before it in
# the file. A reply's own timestamp is when it streamed back, which can fall just
# past a window boundary for a request sent inside the window. Records, as
# Claude Code writes them (checked against jq on 56k real records):
#   user:      {…,"type":"user","message":{…},"uuid":"…","timestamp":"…",…}
#   assistant: {…,"message":{"model":"…","type":"message",…},…,"type":"assistant","uuid":"…","timestamp":"…",…}
# So a reply is the "type":"assistant","uuid","timestamp" run (its type sits
# right before its uuid, after a message full of nested "type"s), and a request
# is a record whose first "type" is "user", timed by its first uuid,timestamp
# pair (toolUseResult, which may nest more, comes after). Nothing later than now.
session_requests() {  # $1 = now epoch
  local dir="$CLAUDE_PROJECTS"
  [ -d "$dir" ] || return 0
  # "path:line:token" per match, in file order. -a: a NUL-damaged log must not
  # read as "Binary file matches".
  find "$dir" -type f -name '*.jsonl' -mmin -1440 -exec env LC_ALL=C grep -aHnoE \
    '"type":"user"|"model":"<synthetic>"|("type":"assistant",)?"uuid":"[0-9a-f-]{36}","timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' {} + \
    | awk -v cut=$(( $1 - 86400 )) -v now="$1" '
      function epoch(s,  p, y, mp, era, yoe, doe) {   # ISO-8601 UTC -> epoch (BSD awk has no mktime)
        split(s, p, /[-T:]/)
        y = p[1] - (p[2] <= 2); mp = (p[2] > 2) ? p[2] - 3 : p[2] + 9
        era = int(y / 400); yoe = y - era * 400
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + int((153 * mp + 2) / 5) + p[3] - 1
        return (era * 146097 + doe - 719468) * 86400 + p[4] * 3600 + p[5] * 60 + p[6]
      }
      function flush(  e) {
        if (kind == "user" && ts != "") req = ts
        else if (kind == "assistant" && !synth && ts != "") {
          e = epoch(req != "" ? req : ts)
          if (e >= cut && e <= now) print e
        }
        kind = ""; synth = 0; ts = ""
      }
      {
        if (!match($0, /:[0-9]+:"/)) next              # path (may hold ":") : line : token
        f = substr($0, 1, RSTART - 1); r = substr($0, RSTART + 1)
        j = index(r, ":"); key = f ":" substr(r, 1, j - 1); tok = substr(r, j + 1)
        if (key != last) { flush(); if (f != lastf) req = ""; last = key; lastf = f }
        t = tok; sub(/.*"timestamp":"/, "", t)
        if (tok ~ /^"type":"assistant"/) { kind = "assistant"; ts = t }
        else if (tok ~ /^"type":"user"/) { if (kind == "") kind = "user" }
        else if (tok ~ /^"model":/) synth = 1
        else if (ts == "") ts = t
      }
      END { flush() }' || true
}

# Epoch at which the CURRENT usage window opened (its FIRST message), or 0 if no
# window is open right now. We must find the window's *first* message, not the last:
# the window closes exactly INTERVAL after it opens regardless of later messages.
# So we replay the last day of activity in order — a request >= INTERVAL after the
# current anchor opens a NEW window — and report the latest anchor if still open.
# Activity is every request that got a real model reply (session_requests). Our
# own pings leave no session log (--no-session-persistence), so they come from
# ping_history; without them the replay drifts off the real window boundaries.
# This greps a day of logs (~4s on a heavy day), so callers check the cheap
# cadence conditions first (and use window_anchor_cached). Any parse trouble
# degrades to "no open window", so we err toward firing, not gaps.
window_anchor() {
  local interval_s=$(( INTERVAL * 60 )) nowE
  nowE=$(date +%s)
  { session_requests "$nowE"; ping_history; read_lf; } 2>/dev/null \
    | awk -v cut=$(( nowE - 86400 )) '/^[0-9]+$/ { if ($0 + 0 >= cut) print $0 + 0 }' \
    | sort -n | awk -v iv="$interval_s" -v now="$nowE" '
    { if (a == 0 || $1 >= a + iv) a = $1 }
    END { print (a > 0 && now < a + iv) ? a : 0 }' || true
}
# window_anchor for the tick, which may ask every 5 minutes for hours while your
# own work holds a window open past our cadence. Later activity inside an open
# window opens nothing, so its anchor holds — except that a reply arriving late
# can reveal an earlier request (another session's long generation), moving the
# anchor, and so the window's end, earlier by up to that reply's latency. So
# reuse the anchor (instead of re-grepping a day of logs, ~4s) until the window's
# last 30 minutes, and rescan from there (the slowest reply in two weeks of real
# logs came 15 minutes after its request).
window_anchor_cached() {
  local interval_s=$(( INTERVAL * 60 )) nowE c a="" re='^([0-9]+) ([0-9]+)$'
  nowE=$(date +%s)
  c="$(cat "$WINDOW_CACHE" 2>/dev/null || true)"            # "anchor interval_s"
  if [[ "$c" =~ $re ]] && [ "${BASH_REMATCH[2]}" = "$interval_s" ] \
     && [ "${BASH_REMATCH[1]}" -le "$nowE" ] && [ "$nowE" -lt $(( BASH_REMATCH[1] + interval_s - 1800 )) ]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  a=$(window_anchor)
  if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -gt 0 ]; then
    { echo "$a $interval_s" > "$WINDOW_CACHE"; } 2>/dev/null || true
  fi
  echo "${a:-0}"
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
