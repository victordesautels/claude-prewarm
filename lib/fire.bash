# ---- ping plumbing -----------------------------------------------------------
# Hold a no-sleep assertion until this process exits, so the Mac cannot drop
# back to sleep mid-ping or while a tick waits for TIME. -s holds on AC power
# even with the lid closed; -i covers idle sleep on battery.
hold_awake() {
  [ -n "${AWAKE_HELD:-}" ] && return 0
  AWAKE_HELD=1
  caffeinate -i -s -w $$ </dev/null >/dev/null 2>&1 &
}

# Run a ping, killing it after $1 seconds (macOS has no coreutils `timeout`). A
# hung ping would otherwise stall every later tick: launchd never starts a new
# instance of the agent while the previous one is still running. Callers send
# the output to a file, not $(...): a killed ping's orphaned children can hold a
# pipe open and hang the substitution anyway. rc 124 on timeout.
# The watchdog's sleeps run in the background so its TERM trap fires at once
# when the ping ends — a foreground sleep would defer the trap and keep the
# caller's stdout open. nap() parks a TERM that lands between forking a sleep
# and learning its PID, and stops the sleep with KILL (a just-forked child
# still runs the inherited TERM trap until it execs), so a cancelled watchdog
# never leaves a sleep behind.
# The watchdog flags a timeout in a marker file; elapsed wall time would also
# count a Mac asleep mid-ping.
run_with_timeout() {  # $1 = seconds, then the command
  local secs="$1" pid wd rc mark
  shift
  mark="$(mktemp "$STATE_DIR/timeout.XXXXXX")"; rm -f "$mark"
  "$@" & pid=$!
  ( stop=""; s=""
    nap() {
      trap 'stop=1' TERM
      sleep "$1" & s=$!
      trap 'kill -KILL "$s"; exit 0' TERM
      [ -n "$stop" ] && { kill -KILL "$s"; exit 0; }
      wait "$s"
    }
    nap "$secs"
    : > "$mark"; kill -TERM "$pid"
    nap 5
    kill -KILL "$pid" ) </dev/null >/dev/null 2>&1 & wd=$!
  # 2>/dev/null on both waits drops bash's "Terminated: 15" job notices (the
  # ping's, and the watchdog's when it is cancelled before its trap is set);
  # the ping's own stderr is already redirected by the caller. Reaping the
  # watchdog before reading the marker also settles a ping that ends just as
  # the timeout fires.
  if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [ -f "$mark" ]; then
    rm -f "$mark"
    if [ "$rc" -ne 0 ]; then echo "ping timed out after ${secs}s"; rc=124; fi
  fi
  return "$rc"
}

# The overnight pmset wake lands a minute before TIME and macOS idles back to
# sleep within seconds (pmset log 2026-10-20: woke 05:59:00, asleep 06:00:27).
# The tick that runs on that wake was too early to fire, so the morning anchor
# waited for the lid to open (fired 06:18 and 06:20). Instead, a tick in the
# last few minutes before TIME holds the Mac awake and waits for TIME — but only
# when the tick at TIME would really fire: not on a skip day, during a limit
# pause or failure back-off, once the cadence has nothing due, or inside a
# window that is already open.
wait_for_time() {
  [ "$MODE" = "manual" ] && return 0
  local t s anchor
  t=$(today_epoch "$TIME"); s=$(( t - $(date +%s) ))
  { [ "$s" -gt 0 ] && [ "$s" -le "$TICK_SECONDS" ]; } || return 0
  current_skip_reason "$(to_min "$TIME")" >/dev/null && return 0
  claude_due "$t" || return 0
  anchor=$(window_anchor)
  [ "${anchor:-0}" -gt 0 ] 2>/dev/null && [ $(( anchor + INTERVAL * 60 )) -gt "$t" ] && return 0
  hold_awake
  printf '%s  WAIT    %ss until %s (holding the Mac awake)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$s" "$TIME" >> "$LOG"
  sleep $(( s + 1 ))   # one second past TIME, so the tick reads TIME:00, not TIME-1
}

# Remember when the previous tick ran (PREV_TICK, 0 if unknown) and stamp this
# one. A late fire is only "Mac was asleep" if the ticks stopped; if they kept
# running, an open window or a guardrail held it back instead.
note_tick() {
  local v; v="$(cat "$LAST_TICK" 2>/dev/null || true)"
  if [[ "$v" =~ ^[0-9]+$ ]]; then PREV_TICK="$v"; else PREV_TICK=0; fi
  date +%s > "$LAST_TICK"
}
late_kind() {  # $1 = now epoch; prints held (ticks ran on), asleep, or unknown
  if [ "${PREV_TICK:-0}" -eq 0 ]; then
    echo unknown     # first tick since install or upgrade: no evidence of sleep
  elif [ $(( $1 - PREV_TICK )) -le $(( GRACE_MIN * 60 )) ]; then
    echo held
  else
    echo asleep
  fi
}
late_note() {  # $1 = late_kind (held|unknown): the log's reason for a late, alert-free fire
  if [ "$1" = "held" ]; then echo "window open or skipped"; else echo "first tick, cause unknown"; fi
}

# Failure alert tail: a retry past the day's last possible prewarm (END less the
# MIN_REMAINING_MIN guardrail) is not happening today.
retry_text() {  # $1 = retry HH:MM
  local r cutoff
  r=$(to_min "$1"); cutoff=$(( $(to_min "$END") - MIN_REMAINING_MIN ))
  [ "$cutoff" -ge 0 ] || cutoff=0
  if [ "$r" -le "$cutoff" ] && [ "$r" -ge "$(to_min "$TIME")" ]; then
    echo "Retrying at $1."
  else
    echo "No retry today (last prewarm by $(to_hm "$cutoff"))."
  fi
}

# ---- the actual ping ---------------------------------------------------------
do_fire() {  # $1 = tick | manual
  local mode="${1:-tick}" claude_bin ts nowE win_start win_end out rc tmp
  local lf elapsed today lf_day sched=0 delay=0 delayed=0 kind="" reanchor=1 win_open=0 margs=()
  local anchor=0 reset_epoch="" step streak retry_at fails=0 fu late=""
  local lockdir="$STATE_DIR/fire.lock"

  # Guard against overlapping fires (e.g. a hung `claude -p`); auto-clear a stale lock.
  if [ -d "$lockdir" ]; then
    if [ -z "$(find "$lockdir" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      [ "$mode" = "manual" ] && echo "(another prewarm is in progress; skipped)"
      return 0
    fi
    rmdir "$lockdir" 2>/dev/null || true
  fi
  mkdir "$lockdir" 2>/dev/null || return 0
  trap 'rmdir "'"$lockdir"'" 2>/dev/null' EXIT

  claude_bin="$(command -v claude || echo "$HOME/.local/bin/claude")"
  nowE=$(date '+%s'); win_start="$(date '+%H:%M')"
  win_end="$(to_hm $(( ($(now_min) + INTERVAL) % 1440 )))"
  lf=$(read_lf)
  step=$(mode_interval_min)
  today=$(date '+%Y%m%d'); lf_day=$( [ "$lf" -gt 0 ] && date -r "$lf" '+%Y%m%d' 2>/dev/null || echo 0 )
  if [ "$lf" -gt 0 ]; then elapsed=$(( (nowE - lf) / 60 )); else elapsed=-1; fi
  # Manual only (a tick fires only when cmd_tick found no open window): is a real
  # usage window open right now (from your work OR our pings)? Its true start is
  # the current window's FIRST message — not our last ping.
  if [ "$mode" = "manual" ]; then anchor=$(window_anchor); [ "$anchor" -gt 0 ] && win_open=1; fi

  if [ "$mode" = "tick" ]; then
    # delay = how late THIS fire is vs. when our cadence expected it (sleep detection),
    # measured against our own last fire — orthogonal to your interactive activity.
    if [ "$lf" -eq 0 ] || [ "$lf_day" != "$today" ]; then
      kind="anchor";   sched=$(today_epoch "$TIME")            # first fire of the day
    else
      kind="boundary"; sched=$(( lf + step * 60 ))             # previous planned cadence
    fi
    # A retry after a failed ping was due at its back-off time, not at the slot
    # that failed — else every recovered failure reads as "Mac was asleep".
    fu=$(read_fail_until "$FAIL_BACKOFF")
    if [ "$fu" -gt "$sched" ]; then sched="$fu"; fails=$(read_fail_streak "$FAIL_BACKOFF"); fi
    delay=$(( (nowE - sched) / 60 ))
    if [ "$delay" -gt "$GRACE_MIN" ]; then
      late=$(late_kind "$nowE")
      if [ "$late" = "asleep" ]; then delayed=1; fi
    fi
  fi

  # A manual ping INSIDE an open window does NOT move Claude's real anchor,
  # so don't advance LAST_FIRE (that would push the next boundary fire late).
  [ "$mode" = "manual" ] && [ "$win_open" -eq 1 ] && reanchor=0

  [ -n "$MODEL" ] && margs=(--model "$MODEL")
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  hold_awake
  # --no-session-persistence: keep the ping out of $CLAUDE_PROJECTS (resume list,
  # window detection) — record_ping tracks our own pings instead.
  tmp="$(mktemp "$STATE_DIR/ping.XXXXXX")"
  if run_with_timeout "$PING_TIMEOUT" "$claude_bin" -p "$PROMPT" --no-session-persistence ${margs[@]+"${margs[@]}"} >"$tmp" 2>&1; then rc=0; else rc=$?; fi
  out="$(cat "$tmp")"; rm -f "$tmp"
  out="${out//$'\n'/ }"

  # Usage limit hit? Back off — pinging a maxed-out account just wastes fires and
  # spams notifications. Record when to resume so ticks stay quiet until then.
  if reset_epoch="$(detect_limit "$out")"; then
    local resume until_txt fmt='+%H:%M'
    if [ "$reset_epoch" -gt 0 ]; then resume="$reset_epoch"
    else resume=$(( nowE + INTERVAL * 60 )); fi
    # spell out the day when the reset is not today, so "until 15:00" can't read as "soon"
    [ "$(date -r "$resume" '+%Y%m%d')" != "$(date '+%Y%m%d')" ] && fmt='+%b %-d %H:%M'
    until_txt="$(date -r "$resume" "$fmt")"
    [ "$reset_epoch" -gt 0 ] || until_txt="~$until_txt"
    echo "$resume" > "$LIMIT_UNTIL"; rm -f "$FAIL_BACKOFF"   # the limit pause supersedes a failure back-off
    printf '%s  LIMIT   usage limit; pausing until %s  msg=%s\n' "$ts" "$until_txt" "${out:0:120}" >> "$LOG"
    notify alert "Claude prewarm - usage limit" "Limit reached. Pausing prewarms until $until_txt."
    return 0
  fi

  if [ "$rc" -ne 0 ] && [ "$mode" = "manual" ]; then
    # you are at the terminal; the schedule's own retries are not this ping's business
    printf '%s  FAILED  rc=%s  manual  %s\n' "$ts" "$rc" "${out:0:140}" >> "$LOG"
    notify alert "Claude prewarm - FAILED" "Manual ping failed (rc=$rc) at $win_start."
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    streak=$(record_failure "$FAIL_BACKOFF" "$nowE")
    retry_at="$(date -r "$(read_fail_until "$FAIL_BACKOFF")" '+%H:%M')"
    printf '%s  FAILED  rc=%s  retry %s  %s\n' "$ts" "$rc" "$retry_at" "${out:0:140}" >> "$LOG"
    if [ "$streak" -eq 1 ]; then
      notify alert "Claude prewarm - FAILED" "Ping failed (rc=$rc) at $win_start. $(retry_text "$retry_at")"
    fi
    return 0
  fi

  rm -f "$LIMIT_UNTIL" "$FAIL_BACKOFF"                  # a clean ping means we're unblocked
  record_ping "$nowE"
  [ "$reanchor" -eq 1 ] && echo "$nowE" > "$LAST_FIRE"

  if [ "$mode" = "manual" ] && [ "$reanchor" -eq 0 ]; then
    local openend; openend="$(date -r "$(( anchor + INTERVAL * 60 ))" '+%H:%M')"
    printf '%s  ok  manual (window already open until %s; anchor unchanged)\n' "$ts" "$openend" >> "$LOG"
    notify routine "Claude prewarm" "Ping sent; window already open until $openend (anchor unchanged)."
  elif [ "$mode" = "manual" ]; then
    printf '%s  ok  manual            window~%s-%s\n' "$ts" "$win_start" "$win_end" >> "$LOG"
    notify routine "Claude prewarm" "Fired manually at $win_start. Window $win_start-$win_end."
  elif [ "$delayed" -eq 1 ]; then
    local due; due="$(date -r "$sched" '+%H:%M')"
    record_recovery "claude" "$sched" "$nowE" "$delay" "$(( nowE + step * 60 ))"
    printf '%s  ok  %s DELAYED due=%s +%dm  window~%s-%s\n' "$ts" "$kind" "$due" "$delay" "$win_start" "$win_end" >> "$LOG"
    notify alert "Claude prewarm - delayed" "Due ~$due but Mac was asleep. Fired $win_start. Window $win_start-$win_end."
  elif [ "$fails" -gt 0 ]; then
    printf '%s  ok  %s recovered after %d failed  window~%s-%s\n' "$ts" "$kind" "$fails" "$win_start" "$win_end" >> "$LOG"
    notify alert "Claude prewarm - recovered" "Ping worked after $fails failed. Window $win_start-$win_end."
  elif [ -n "$late" ]; then
    printf '%s  ok  %s held +%dm (%s)  window~%s-%s\n' "$ts" "$kind" "$delay" "$(late_note "$late")" "$win_start" "$win_end" >> "$LOG"
    notify routine "Claude prewarm" "Window anchored at $win_start (until $win_end)."
  else
    printf '%s  ok  %s on-time        window~%s-%s\n' "$ts" "$kind" "$win_start" "$win_end" >> "$LOG"
    notify routine "Claude prewarm" "Window anchored at $win_start (until $win_end)."
  fi
  return 0
}

do_codex_fire() {  # $1 = tick | manual
  local mode="${1:-tick}" codex_bin ts nowE ping_start ping_end out rc tmp
  local lf today lf_day sched=0 delay=0 delayed=0 kind="" reset_epoch="" cargs=() step streak retry_at fails=0 fu late=""
  local lockdir="$STATE_DIR/codex.fire.lock"

  [ "$CODEX" = "true" ] || return 0

  # Separate lock: Codex should not block Claude, and Claude should not block Codex.
  if [ -d "$lockdir" ]; then
    if [ -z "$(find "$lockdir" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      [ "$mode" = "manual" ] && echo "(another Codex prewarm is in progress; skipped)"
      return 0
    fi
    rmdir "$lockdir" 2>/dev/null || true
  fi
  mkdir "$lockdir" 2>/dev/null || return 0

  codex_bin="$(command -v codex || true)"
  [ -z "$codex_bin" ] && [ -x /opt/homebrew/bin/codex ] && codex_bin="/opt/homebrew/bin/codex"
  [ -z "$codex_bin" ] && [ -x "$HOME/.local/bin/codex" ] && codex_bin="$HOME/.local/bin/codex"

  nowE=$(date '+%s'); ping_start="$(date '+%H:%M')"
  ping_end="$(to_hm $(( ($(now_min) + INTERVAL) % 1440 )))"
  lf=$(read_codex_lf)
  step=$(mode_interval_min)
  today=$(date '+%Y%m%d'); lf_day=$( [ "$lf" -gt 0 ] && date -r "$lf" '+%Y%m%d' 2>/dev/null || echo 0 )

  if [ "$mode" = "tick" ]; then
    if [ "$lf" -eq 0 ] || [ "$lf_day" != "$today" ]; then
      kind="anchor";   sched=$(today_epoch "$TIME")
    else
      kind="boundary"; sched=$(( lf + step * 60 ))
    fi
    fu=$(read_fail_until "$CODEX_FAIL_BACKOFF")              # a retry is due at its back-off time
    if [ "$fu" -gt "$sched" ]; then sched="$fu"; fails=$(read_fail_streak "$CODEX_FAIL_BACKOFF"); fi
    delay=$(( (nowE - sched) / 60 ))
    if [ "$delay" -gt "$GRACE_MIN" ]; then
      late=$(late_kind "$nowE")
      if [ "$late" = "asleep" ]; then delayed=1; fi
    fi
  fi

  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -z "$codex_bin" ]; then
    rc=127; out="codex binary not found"      # backs off like any other failure
  else
    cargs=(exec --skip-git-repo-check --ephemeral --sandbox read-only)
    [ -n "$CODEX_MODEL" ] && cargs+=(--model "$CODEX_MODEL")
    hold_awake
    tmp="$(mktemp "$STATE_DIR/codex_ping.XXXXXX")"
    if run_with_timeout "$PING_TIMEOUT" "$codex_bin" "${cargs[@]}" "$CODEX_PROMPT" </dev/null >"$tmp" 2>&1; then rc=0; else rc=$?; fi
    out="$(cat "$tmp")"; rm -f "$tmp"
    out="${out//$'\n'/ }"
  fi

  if reset_epoch="$(detect_limit "$out")"; then
    local resume until_txt fmt='+%H:%M'
    if [ "$reset_epoch" -gt 0 ]; then resume="$reset_epoch"
    else resume=$(( nowE + INTERVAL * 60 )); fi
    [ "$(date -r "$resume" '+%Y%m%d')" != "$(date '+%Y%m%d')" ] && fmt='+%b %-d %H:%M'
    until_txt="$(date -r "$resume" "$fmt")"
    [ "$reset_epoch" -gt 0 ] || until_txt="~$until_txt"
    echo "$resume" > "$CODEX_LIMIT_UNTIL"; rm -f "$CODEX_FAIL_BACKOFF"
    printf '%s  CODEX LIMIT   usage limit; pausing until %s  msg=%s\n' "$ts" "$until_txt" "${out:0:120}" >> "$LOG"
    notify alert "Codex prewarm - usage limit" "Limit reached. Pausing Codex prewarms until $until_txt."
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  if [ "$rc" -ne 0 ] && [ "$mode" = "manual" ]; then
    printf '%s  CODEX FAILED  rc=%s  manual  %s\n' "$ts" "$rc" "${out:0:140}" >> "$LOG"
    notify alert "Codex prewarm - FAILED" "Manual Codex ping failed (rc=$rc) at $ping_start."
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    streak=$(record_failure "$CODEX_FAIL_BACKOFF" "$nowE")
    retry_at="$(date -r "$(read_fail_until "$CODEX_FAIL_BACKOFF")" '+%H:%M')"
    printf '%s  CODEX FAILED  rc=%s  retry %s  %s\n' "$ts" "$rc" "$retry_at" "${out:0:140}" >> "$LOG"
    if [ "$streak" -eq 1 ]; then
      notify alert "Codex prewarm - FAILED" "Codex ping failed (rc=$rc) at $ping_start. $(retry_text "$retry_at")"
    fi
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  rm -f "$CODEX_LIMIT_UNTIL" "$CODEX_FAIL_BACKOFF"
  echo "$nowE" > "$CODEX_LAST_FIRE"

  if [ "$mode" = "manual" ]; then
    printf '%s  ok  codex manual          ping~%s-%s\n' "$ts" "$ping_start" "$ping_end" >> "$LOG"
    notify routine "Codex prewarm" "Codex ping sent at $ping_start."
  elif [ "$delayed" -eq 1 ]; then
    local due; due="$(date -r "$sched" '+%H:%M')"
    record_recovery "codex" "$sched" "$nowE" "$delay" "$(( nowE + step * 60 ))"
    printf '%s  ok  codex %s DELAYED due=%s +%dm  ping~%s-%s\n' "$ts" "$kind" "$due" "$delay" "$ping_start" "$ping_end" >> "$LOG"
    notify alert "Codex prewarm - delayed" "Due ~$due but Mac was asleep. Fired $ping_start."
  elif [ "$fails" -gt 0 ]; then
    printf '%s  ok  codex %s recovered after %d failed  ping~%s-%s\n' "$ts" "$kind" "$fails" "$ping_start" "$ping_end" >> "$LOG"
    notify alert "Codex prewarm - recovered" "Codex ping worked after $fails failed."
  elif [ -n "$late" ]; then
    printf '%s  ok  codex %s held +%dm (%s)  ping~%s-%s\n' "$ts" "$kind" "$delay" "$(late_note "$late")" "$ping_start" "$ping_end" >> "$LOG"
    notify routine "Codex prewarm" "Codex ping sent at $ping_start."
  else
    printf '%s  ok  codex %s on-time      ping~%s-%s\n' "$ts" "$kind" "$ping_start" "$ping_end" >> "$LOG"
    notify routine "Codex prewarm" "Codex ping sent at $ping_start."
  fi

  rmdir "$lockdir" 2>/dev/null || true
  return 0
}

# ---- tick: decide whether a fire is due (the self-healing core) --------------
cmd_tick() {
  ( validate_config ) 2>>"$LOG" || exit 0    # bad on-disk config → log why, don't fire
  check_wake_ac                              # before the skip exit: evening/overnight ticks land here
  note_tick                                  # so a late fire can tell asleep from held back
  wait_for_time                              # a tick just before TIME waits for it instead of skipping
  local n nowE lu fu clu cfu anchor today clf clf_day skip step
  n=$(now_min); nowE=$(date '+%s')
  today=$(date '+%Y%m%d')
  step=$(mode_interval_min)
  if skip="$(current_skip_reason)"; then
    record_skip_once "all" "$skip"
    exit 0
  fi

  lu=$(read_limit_until); fu=$(read_fail_until "$FAIL_BACKOFF")
  if [ "$lu" -gt "$nowE" ]; then
    record_skip_once "claude" "usage limit until $(date -r "$lu" '+%H:%M')"
  elif [ "$fu" -gt "$nowE" ]; then
    record_skip_once "claude" "retrying failed ping at $(date -r "$fu" '+%H:%M')"
  elif claude_due "$nowE"; then
    # Cadence first: window_anchor greps a day of session logs, so only look for
    # an open window (its FIRST message < INTERVAL ago, your work OR our ping)
    # once a fire is due.
    anchor=$(window_anchor)
    [ "${anchor:-0}" -gt 0 ] 2>/dev/null || do_fire tick
  fi

  if [ "$CODEX" = "true" ]; then
    clu=$(read_codex_limit_until); cfu=$(read_fail_until "$CODEX_FAIL_BACKOFF")
    if [ "$clu" -gt "$nowE" ]; then
      record_skip_once "codex" "usage limit until $(date -r "$clu" '+%H:%M')"
    elif [ "$cfu" -gt "$nowE" ]; then
      record_skip_once "codex" "retrying failed ping at $(date -r "$cfu" '+%H:%M')"
    else
      clf=$(read_codex_lf)
      clf_day=$( [ "$clf" -gt 0 ] && date -r "$clf" '+%Y%m%d' 2>/dev/null || echo 0 )
      if [ "$MODE" = "daily" ]; then
        [ "$clf_day" != "$today" ] && do_codex_fire tick
      else
        { [ "$clf" -eq 0 ] || [ "$clf_day" != "$today" ] || [ "$nowE" -ge $(( clf + step * 60 )) ]; } && do_codex_fire tick
      fi
    fi
  fi
  exit 0
}

# ---- keep-awake (caffeinate wrapper that always stops at END) ----------------
cmd_keepawake() {
  ( validate_config ) 2>>"$LOG" || exit 0
  local n end dur skip
  if skip="$(current_skip_reason)"; then
    printf '%s  keepawake skipped (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$skip" >> "$LOG"
    exit 0
  fi
  n=$(now_min); end=$(to_min "$END"); dur=$(( (end - n) * 60 ))
  if [ "$dur" -le 0 ]; then
    printf '%s  keepawake skipped (past END %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$END" >> "$LOG"; exit 0
  fi
  printf '%s  keepawake until %s (%ds)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$END" "$dur" >> "$LOG"
  exec caffeinate -s -i -t "$dur"
}
