# ---- the actual ping ---------------------------------------------------------
do_fire() {  # $1 = tick | manual
  local mode="${1:-tick}" claude_bin ts nowE win_start win_end out rc
  local lf elapsed today lf_day sched=0 delay=0 delayed=0 kind="" reanchor=1 win_open=0 margs=()
  local anchor=0 reset_epoch="" step
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
  # Is a real usage window open right now (from your work OR our pings)? Its true
  # start is the current window's FIRST message — not our last ping.
  anchor=$(window_anchor); [ "$anchor" -gt 0 ] && win_open=1

  if [ "$mode" = "tick" ]; then
    # delay = how late THIS fire is vs. when our cadence expected it (sleep detection),
    # measured against our own last fire — orthogonal to your interactive activity.
    if [ "$lf" -eq 0 ] || [ "$lf_day" != "$today" ]; then
      kind="anchor";   sched=$(today_epoch "$TIME")            # first fire of the day
    else
      kind="boundary"; sched=$(( lf + step * 60 ))             # previous planned cadence
    fi
    delay=$(( (nowE - sched) / 60 ))
    [ "$delay" -gt "$GRACE_MIN" ] && delayed=1
  fi

  # A manual ping INSIDE an open window does NOT move Claude's real anchor,
  # so don't advance LAST_FIRE (that would push the next boundary fire late).
  [ "$mode" = "manual" ] && [ "$win_open" -eq 1 ] && reanchor=0

  [ -n "$MODEL" ] && margs=(--model "$MODEL")
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if out="$("$claude_bin" -p "$PROMPT" ${margs[@]+"${margs[@]}"} 2>&1)"; then rc=0; else rc=$?; fi
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
    echo "$resume" > "$LIMIT_UNTIL"
    printf '%s  LIMIT   usage limit; pausing until %s  msg=%s\n' "$ts" "$until_txt" "${out:0:120}" >> "$LOG"
    notify alert "Claude prewarm - usage limit" "Limit reached. Pausing prewarms until $until_txt."
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    printf '%s  FAILED  rc=%s  %s\n' "$ts" "$rc" "${out:0:140}" >> "$LOG"
    notify alert "Claude prewarm - FAILED" "Ping failed (rc=$rc) at $win_start."
    return 0
  fi

  rm -f "$LIMIT_UNTIL"                                  # a clean ping means we're unblocked
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
  else
    printf '%s  ok  %s on-time        window~%s-%s\n' "$ts" "$kind" "$win_start" "$win_end" >> "$LOG"
    notify routine "Claude prewarm" "Window anchored at $win_start (until $win_end)."
  fi
  return 0
}

do_codex_fire() {  # $1 = tick | manual
  local mode="${1:-tick}" codex_bin ts nowE ping_start ping_end out rc
  local lf today lf_day sched=0 delay=0 delayed=0 kind="" reset_epoch="" cargs=() step
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
    delay=$(( (nowE - sched) / 60 ))
    [ "$delay" -gt "$GRACE_MIN" ] && delayed=1
  fi

  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -z "$codex_bin" ]; then
    printf '%s  CODEX FAILED  codex binary not found\n' "$ts" >> "$LOG"
    notify alert "Codex prewarm - FAILED" "codex binary not found."
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  cargs=(exec --skip-git-repo-check --ephemeral --sandbox read-only)
  [ -n "$CODEX_MODEL" ] && cargs+=(--model "$CODEX_MODEL")
  if out="$("$codex_bin" "${cargs[@]}" "$CODEX_PROMPT" </dev/null 2>&1)"; then rc=0; else rc=$?; fi
  out="${out//$'\n'/ }"

  if reset_epoch="$(detect_limit "$out")"; then
    local resume until_txt fmt='+%H:%M'
    if [ "$reset_epoch" -gt 0 ]; then resume="$reset_epoch"
    else resume=$(( nowE + INTERVAL * 60 )); fi
    [ "$(date -r "$resume" '+%Y%m%d')" != "$(date '+%Y%m%d')" ] && fmt='+%b %-d %H:%M'
    until_txt="$(date -r "$resume" "$fmt")"
    [ "$reset_epoch" -gt 0 ] || until_txt="~$until_txt"
    echo "$resume" > "$CODEX_LIMIT_UNTIL"
    printf '%s  CODEX LIMIT   usage limit; pausing until %s  msg=%s\n' "$ts" "$until_txt" "${out:0:120}" >> "$LOG"
    notify alert "Codex prewarm - usage limit" "Limit reached. Pausing Codex prewarms until $until_txt."
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  if [ "$rc" -ne 0 ]; then
    printf '%s  CODEX FAILED  rc=%s  %s\n' "$ts" "$rc" "${out:0:140}" >> "$LOG"
    notify alert "Codex prewarm - FAILED" "Codex ping failed (rc=$rc) at $ping_start."
    rmdir "$lockdir" 2>/dev/null || true
    return 0
  fi

  rm -f "$CODEX_LIMIT_UNTIL"
  echo "$nowE" > "$CODEX_LAST_FIRE"

  if [ "$mode" = "manual" ]; then
    printf '%s  ok  codex manual          ping~%s-%s\n' "$ts" "$ping_start" "$ping_end" >> "$LOG"
    notify routine "Codex prewarm" "Codex ping sent at $ping_start."
  elif [ "$delayed" -eq 1 ]; then
    local due; due="$(date -r "$sched" '+%H:%M')"
    record_recovery "codex" "$sched" "$nowE" "$delay" "$(( nowE + step * 60 ))"
    printf '%s  ok  codex %s DELAYED due=%s +%dm  ping~%s-%s\n' "$ts" "$kind" "$due" "$delay" "$ping_start" "$ping_end" >> "$LOG"
    notify alert "Codex prewarm - delayed" "Due ~$due but Mac was asleep. Fired $ping_start."
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
  local n nowE lu clu anchor today lf lf_day clf clf_day skip step
  n=$(now_min); nowE=$(date '+%s')
  today=$(date '+%Y%m%d')
  step=$(mode_interval_min)
  if skip="$(current_skip_reason)"; then
    record_skip_once "all" "$skip"
    exit 0
  fi

  lu=$(read_limit_until)
  if [ "$lu" -gt "$nowE" ]; then
    record_skip_once "claude" "usage limit until $(date -r "$lu" '+%H:%M')"
  else
    # A window is open iff its FIRST message was < INTERVAL ago (your work OR our ping).
    anchor=$(window_anchor)
    if [ "$MODE" = "daily" ]; then
      lf=$(read_lf)                              # once/day: fire only if we haven't today
      lf_day=$( [ "$lf" -gt 0 ] && date -r "$lf" '+%Y%m%d' 2>/dev/null || echo 0 )
      { [ "$anchor" -eq 0 ] && [ "$lf_day" != "$today" ]; } && do_fire tick
    else
      lf=$(read_lf)
      lf_day=$( [ "$lf" -gt 0 ] && date -r "$lf" '+%Y%m%d' 2>/dev/null || echo 0 )
      { [ "$anchor" -eq 0 ] && { [ "$lf" -eq 0 ] || [ "$lf_day" != "$today" ] || [ "$nowE" -ge $(( lf + step * 60 )) ]; }; } && do_fire tick
    fi
  fi

  if [ "$CODEX" = "true" ]; then
    clu=$(read_codex_limit_until)
    if [ "$clu" -gt "$nowE" ]; then
      record_skip_once "codex" "usage limit until $(date -r "$clu" '+%H:%M')"
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
