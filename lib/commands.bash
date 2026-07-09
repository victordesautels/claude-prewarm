# ---- subcommands -------------------------------------------------------------
apply_flags() {
  while [ $# -gt 0 ]; do case "$1" in
    --time|--days|--interval|--workstart|--end|--mode|--prompt|--model|--codex-prompt|--codex-model|--calendar|--skip-dates|--min-battery|--min-remaining|--keepalive|--notify)
      [ $# -ge 2 ] || die "flag $1 needs a value"
      case "$1" in
        --time) TIME="$2";; --days) DAYS="$2";; --interval) INTERVAL="$2";;
        --workstart) WORKSTART="$2";; --end) END="$2";; --mode) MODE="$2";;
        --prompt) PROMPT="$2";;
        --model) MODEL="$2";; --codex-prompt) CODEX_PROMPT="$2";; --codex-model) CODEX_MODEL="$2";;
        --calendar) CALENDAR="$2";; --skip-dates) SKIP_DATES="$2";;
        --min-battery) MIN_BATTERY_PERCENT="$2";; --min-remaining) MIN_REMAINING_MIN="$2";;
        --keepalive) KEEPALIVE="$2";; --notify) NOTIFY="$2";;
      esac; shift 2;;
    --no-keepalive)  KEEPALIVE="false"; shift;;
    --codex)         CODEX="true"; shift;;
    --no-codex)      CODEX="false"; shift;;
    --low-battery-skip)    LOW_BATTERY_SKIP="true"; shift;;
    --no-low-battery-skip) LOW_BATTERY_SKIP="false"; shift;;
    --no-notify)     NOTIFY="false"; shift;;
    --wake)          WAKE="true"; shift;;
    --no-wake)       WAKE="false"; shift;;
    --stay-awake)    STAYAWAKE="true"; shift;;
    --no-stay-awake) STAYAWAKE="false"; shift;;
    *) die "unknown flag: $1";;
  esac; done
}

cmd_install() {
  apply_flags "$@"; validate_config; save_config; apply_agents
  printf '%s %s %s\n' "$(green "$S_OK")" "$(bold Installed)" "$(dim "— self-healing; checks every $((TICK_SECONDS/60))m")"
  row "days"     "$DAYS"
  case "$MODE" in aggressive|coverage) KEEPALIVE="true";; conserve|manual) KEEPALIVE="false";; esac
  row "active"   "${TIME}-${END}  $(dim "mode=$MODE · cadence $(mode_interval_min)m")"
  row "prewarms" "$(fire_times | tr '\n' ' ')"
  row "calendar" "$CALENDAR"
  [ "$CODEX" = "true" ] && row "codex" "on $(dim "model=${CODEX_MODEL:-default}")" || row "codex" "$(dim off)"
  [ "$STAYAWAKE" = "true" ] && row "awake" "caffeinate ${WORKSTART}-${END}" || row "awake" "$(dim off)"
  row "notify"   "$NOTIFY"
  reconcile_wake
  notifier_setup
  printf '%s\n' "$(dim "Next: 'claude-prewarm status' to check state.")"
}

cmd_setup() {
  { [ -t 0 ] && [ -t 1 ]; } || die "guided install needs an interactive terminal" \
    "use flags instead, e.g.: claude-prewarm install-default --time 05:00 --end 17:00"
  welcome_banner "claude-prewarm   v$VERSION" \
                 "Keep Claude's 5-hour windows aligned to your workday."
  printf '\n%s\n'  "$(yellow '☀') $(bold 'Welcome!') $(dim "Let's set up when your Claude usage windows should open.")"
  printf '%s\n'    "$(dim '  This takes about a minute. Nothing is applied until you confirm at the end.')"
  printf '%s\n\n'  "$(dim '  ↵ enter accepts each [default] · esc / ctrl-c cancels anytime')"

  while :; do TIME=$(ask_text "Morning prewarm time (HH:MM)" "$TIME")
    valid_hhmm "$TIME" && break; printf '  %s\n' "$(red 'Enter a time as HH:MM.')" >&2; done

  menu_select "Which days?" 0 "Weekdays (Mon-Fri)" "Every day" "Weekends" "Custom letters…" || true
  [ "$REPLY_IDX" -lt 0 ] && { printf '%s\n' "$(dim cancelled)"; exit 0; }
  case "$REPLY_IDX" in
    0) DAYS=weekdays;; 1) DAYS=daily;; 2) DAYS=weekends;;
    3) while :; do DAYS=$(ask_text "Day letters (M T W R F S U)" "MWF")
         [ -n "$(weekday_nums 2>/dev/null)" ] && break; printf '  %s\n' "$(red 'Use letters M T W R F S U.')" >&2; done;;
  esac

  while :; do END=$(ask_text "End of workday (HH:MM)" "$END")
    { valid_hhmm "$END" && [ "$(to_min "$END")" -gt "$(to_min "$TIME")" ]; } && break
    printf '  %s\n' "$(red "Enter HH:MM after $TIME.")" >&2; done

  menu_select "Prewarm mode?" 0 "Aggressive (tile active windows)" "Coverage (every 6h)" "Conserve (once/day)" "Manual (no automatic pings)" || true
  [ "$REPLY_IDX" -lt 0 ] && { printf '%s\n' "$(dim cancelled)"; exit 0; }
  case "$REPLY_IDX" in
    0) MODE=aggressive;; 1) MODE=coverage;; 2) MODE=conserve;; 3) MODE=manual;;
  esac
  case "$MODE" in aggressive|coverage) KEEPALIVE=true;; conserve|manual) KEEPALIVE=false;; esac

  menu_select "Calendar skips?" 1 "None" "US holidays" "Canada holidays" "US + Canada holidays" || true
  [ "$REPLY_IDX" -lt 0 ] && { printf '%s\n' "$(dim cancelled)"; exit 0; }
  case "$REPLY_IDX" in
    0) CALENDAR=none;; 1) CALENDAR=us;; 2) CALENDAR=canada;; 3) CALENDAR=north-america;;
  esac

  if ask_yesno "Also ping Codex on this cadence (uses Codex turns)?" n; then
    CODEX=true
    CODEX_PROMPT=$(ask_text "Codex ping prompt" "$CODEX_PROMPT")
  else CODEX=false; fi

  if ask_yesno "Keep the Mac awake during the workday (no sudo, lid open)?" n; then
    STAYAWAKE=true
    while :; do WORKSTART=$(ask_text "Workday start — caffeinate begins (HH:MM)" "$WORKSTART")
      { valid_hhmm "$WORKSTART" && [ "$(to_min "$END")" -gt "$(to_min "$WORKSTART")" ]; } && break
      printf '  %s\n' "$(red "Enter HH:MM before $END.")" >&2; done
  else STAYAWAKE=false; fi

  ask_yesno "Wake the Mac overnight for the morning prewarm (asks admin once)?" y && WAKE=true || WAKE=false

  menu_select "Notifications?" 0 "All fires" "Only delayed or failed" "Off" || true
  [ "$REPLY_IDX" -lt 0 ] && { printf '%s\n' "$(dim cancelled)"; exit 0; }
  case "$REPLY_IDX" in 0) NOTIFY=true;; 1) NOTIFY=delayed;; 2) NOTIFY=false;; esac

  printf '\n%s\n' "$(bold Review)"
  row "days"   "$DAYS"
  row "active" "${TIME}-${END}  $(dim "mode=$MODE · cadence $(mode_interval_min)m")"
  row "calendar" "$CALENDAR"
  [ "$CODEX" = "true" ] && row "codex" "on $(dim "model=${CODEX_MODEL:-default}")" || row "codex" "$(dim off)"
  [ "$STAYAWAKE" = "true" ] && row "awake" "caffeinate ${WORKSTART}-${END}" || row "awake" "$(dim off)"
  row "wake"   "$WAKE"
  row "notify" "$NOTIFY"
  echo
  if ask_yesno "Apply this setup now?" y; then
    validate_config; save_config; apply_agents
    printf '%s %s\n' "$(green "$S_OK")" "$(bold Installed.)"
    reconcile_wake
    notifier_setup
    echo; cmd_status
  else
    printf '%s\n' "$(dim "Not applied. Re-run anytime: claude-prewarm install")"
  fi
}

cmd_uninstall() {
  local yes=0 purge=0
  while [ $# -gt 0 ]; do case "$1" in
    -y|--yes) yes=1; shift;;
    --purge)  purge=1; shift;;
    *) die "unknown argument: $1" "usage: claude-prewarm uninstall [-y] [--purge]";;
  esac; done
  if [ "$yes" != 1 ]; then
    if [ -t 0 ]; then
      local what="claude-prewarm's agents"
      [ -f "$WAKE_MARK" ] && what="$what and wake schedule"
      [ "$purge" = 1 ] && what="$what, plus every installed file (binary, libs, notifier app, config, logs)"
      printf '%s ' "Remove $what? [y/N]"
      local ans=""; read -r ans || true
      case "$ans" in y|Y|yes|YES) ;; *) printf '%s\n' "$(dim aborted)"; exit 0;; esac
    else
      die "refusing to uninstall without confirmation" "pass -y to confirm (add --purge to also delete files): claude-prewarm uninstall -y"
    fi
  fi
  unload_agent "$LABEL" "$PLIST";             rm -f "$PLIST"
  unload_agent "$AWAKE_LABEL" "$AWAKE_PLIST"; rm -f "$AWAKE_PLIST"
  printf '%s %s\n' "$(green "$S_OK")" "Removed launchd agent(s)."
  clear_wake
  if [ "$purge" = 1 ]; then
    # Remove installed files last. Delete the known artifacts explicitly, then
    # remove the share dir only if that emptied it (rmdir, not rm -rf) — so a
    # non-standard CLAUDE_PREWARM_LIB_DIR pointing at a shared/populated dir can
    # never trigger a wide recursive delete. Both CONFIG_DIR and STATE_DIR always
    # carry a literal suffix, so they are safe to remove recursively. Removing the
    # running script's own file is fine on macOS (its inode is held open until
    # this process exits, and the libs are already sourced into memory).
    local share; share="$(dirname "$LIB_DIR")"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    rm -rf "$LIB_DIR" "$share/assets" "$share/Claude Prewarm.app"
    rmdir "$share" 2>/dev/null || true    # removes the share dir iff now empty
    rm -f "$SELF"
    printf '%s %s\n' "$(green "$S_OK")" "Purged all claude-prewarm files."
  else
    printf '%s\n' "$(dim "config + logs kept in $CONFIG_DIR")"
  fi
}

cmd_now() {
  printf '%s\n' "$(dim "Firing prewarm ping (prompt: \"$PROMPT\")…")"
  do_fire manual
  local last; last="$(tail -n1 "$LOG")"
  print_fire_result "$last"
  if [ "$CODEX" = "true" ]; then
    printf '%s\n' "$(dim "Firing Codex ping (prompt: \"$CODEX_PROMPT\")…")"
    do_codex_fire manual
    last="$(tail -n1 "$LOG")"
    print_fire_result "$last"
  fi
}

print_fire_result() {
  local last="$1"
  case "$last" in
    *FAILED*) printf '%s %s\n' "$(red "$S_NO")"    "$(printf '%s' "$last" | sed -E 's/^[0-9:. -]+//')";;
    *LIMIT*)  printf '%s %s\n' "$(yellow "$S_WARN")" "$(printf '%s' "$last" | sed -E 's/^[0-9:. -]+//')";;
    *)        printf '%s %s\n' "$(green "$S_OK")"   "$(printf '%s' "$last" | sed -E 's/^.*  ok  //')";;
  esac
}

cmd_status() {
  local json=0
  case "${1:-}" in --json|json) json=1;; "") ;; *) die "usage: claude-prewarm status [--json]";; esac
  local loaded="no" awake_loaded="no" lf clf act anchor n nowE elapsed lu clu skip="" next_due=0 cnext_due=0 binfo bsrc bpct rec="" lskip=""
  agent_loaded "$LABEL"       && loaded="yes"
  agent_loaded "$AWAKE_LABEL" && awake_loaded="yes"
  lf=$(read_lf); clf=$(read_codex_lf); act=$(last_activity); anchor=$(window_anchor)
  n=$(now_min); nowE=$(date '+%s'); lu=$(read_limit_until); clu=$(read_codex_limit_until)
  next_due=$(next_due_epoch "$lf")
  cnext_due=$(next_due_epoch "$clf")
  [ "$CODEX" = "true" ] || cnext_due=0
  binfo="$(battery_info)"; bsrc="${binfo%%|*}"; bpct="${binfo##*|}"
  if skip="$(current_skip_reason)"; then :; else skip=""; fi
  rec="$(recovery_summary 2>/dev/null || true)"
  lskip="$(last_skip_summary 2>/dev/null || true)"
  [ "$anchor" -gt 0 ] && elapsed=$(( (nowE - anchor) / 60 )) || elapsed=-1

  if [ "$json" = 1 ]; then
    COLOR=0
    printf '{'
    printf '"version":"%s",' "$(json_escape "$VERSION")"
    printf '"installed":%s,' "$([ "$loaded" = "yes" ] && echo true || echo false)"
    printf '"mode":"%s",' "$(json_escape "$MODE")"
    printf '"mode_label":"%s",' "$(json_escape "$(mode_label)")"
    printf '"calendar":"%s",' "$(json_escape "$CALENDAR")"
    printf '"skip_reason":"%s",' "$(json_escape "$skip")"
    printf '"last_skip":"%s",' "$(json_escape "$lskip")"
    printf '"last_recovery":"%s",' "$(json_escape "$rec")"
    printf '"schedule":{"days":"%s","time":"%s","end":"%s","cadence_minutes":%s},' "$(json_escape "$DAYS")" "$(json_escape "$TIME")" "$(json_escape "$END")" "$(mode_interval_min)"
    printf '"claude":{"window_anchor":%s,"window_end":%s,"last_fire":%s,"next_due":%s,"limit_until":%s},' \
      "$(json_num_or_null "$anchor")" \
      "$( [ "$anchor" -gt 0 ] && echo $(( anchor + INTERVAL * 60 )) || echo null )" \
      "$(json_num_or_null "$lf")" \
      "$(json_num_or_null "$next_due")" \
      "$(json_num_or_null "$lu")"
    printf '"codex":{"enabled":%s,"last_fire":%s,"next_due":%s,"limit_until":%s},' \
      "$(json_bool "$CODEX")" "$(json_num_or_null "$clf")" "$(json_num_or_null "$cnext_due")" "$(json_num_or_null "$clu")"
    printf '"guardrails":{"low_battery_skip":%s,"battery_source":"%s","battery_percent":%s,"min_battery_percent":%s,"min_remaining_minutes":%s},' \
      "$(json_bool "$LOW_BATTERY_SKIP")" "$(json_escape "$bsrc")" "$([ -n "$bpct" ] && echo "$bpct" || echo null)" "$MIN_BATTERY_PERCENT" "$MIN_REMAINING_MIN"
    printf '"paths":{"log":"%s","config":"%s"}}\n' "$(json_escape "$LOG")" "$(json_escape "$CONFIG")"
    return 0
  fi

  printf '  %s  %s\n' "$(bold '☀ claude-prewarm')" "$(dim "v$VERSION")"
  printf '  %s\n' "$(hr 42)"
  # one-glance health line, derived from your real window (your work OR our pings)
  if [ "$loaded" != "yes" ]; then
    printf '  %s %s\n' "$(yellow "$S_WARN not installed")" "$(dim "— run: claude-prewarm install")"
  elif [ "$lu" -gt "$nowE" ]; then
    printf '  %s %s\n' "$(yellow "$S_WARN limited")" "$(dim "usage limit — prewarms paused until $(date -r "$lu" '+%H:%M')")"
  elif [ "$anchor" -gt 0 ] && [ "$elapsed" -lt "$INTERVAL" ]; then
    printf '  %s %s\n' "$(green "$S_DOT active")" "$(dim "window open until $(date -r $((anchor+INTERVAL*60)) '+%H:%M') · $((INTERVAL-elapsed))m left")"
  elif [ -n "$skip" ]; then
    printf '  %s %s\n' "$(dim "$S_RING skipped")" "$(dim "$skip")"
  elif { [ "$n" -ge "$(to_min "$TIME")" ] && [ "$n" -le "$(to_min "$END")" ]; } && is_scheduled_today; then
    printf '  %s %s\n' "$(green "$S_DOT active")" "$(dim "window due — re-anchors within $((TICK_SECONDS/60))m")"
  else
    printf '  %s %s\n' "$(dim "$S_RING idle")" "$(dim "outside active hours (${TIME}-${END}, $DAYS)")"
  fi

  group "Schedule"
  row "mode"      "$(mode_label)"
  row "schedule"  "$DAYS · ${TIME}-${END} · cadence $(mode_interval_min)m"
  row "prewarms"  "$(fire_times | tr '\n' ' ') $(dim '(nominal)')"
  row "calendar"  "$CALENDAR$([ -n "$SKIP_DATES" ] && printf ' + custom')"
  [ -n "$skip" ] && row "skip now" "$(yellow "$skip")"

  group "Ping"
  row "prompt"    "\"$PROMPT\" $(dim "model=${MODEL:-default}")"
  if [ "$CODEX" = "true" ]; then
    row "codex"    "$(green on) $(dim "prompt=\"$CODEX_PROMPT\" model=${CODEX_MODEL:-default}")"
    if [ "$clf" -gt 0 ]; then row "codex last" "$(date -r "$clf" '+%H:%M') $(dim "($(( (nowE-clf)/60 ))m ago, our ping)")"
    else row "codex last" "$(dim never)"; fi
  else
    row "codex"    "$(dim off)"
  fi

  group "Guardrails"
  if   [ -f "$WAKE_MARK" ];    then row "wake" "$(green "$S_OK") $(cat "$WAKE_MARK")$([ "$bsrc" = "battery" ] && printf ' %s' "$(yellow "$S_WARN on battery — scheduled wakes need AC power")")"
  elif [ "$WAKE" = "true" ];   then row "wake" "$(yellow "$S_NO not set") $(dim '— run: claude-prewarm config set WAKE true')"
  else                              row "wake" "$(dim off)"; fi
  [ "$STAYAWAKE" = "true" ] && row "awake" "caffeinate ${WORKSTART}-${END} $(dim "(loaded=$awake_loaded)")" || row "awake" "$(dim off)"
  row "notify"    "$NOTIFY"
  row "battery"   "skip=$LOW_BATTERY_SKIP ${MIN_BATTERY_PERCENT}% · min remaining ${MIN_REMAINING_MIN}m$([ -n "$bpct" ] && printf ' · now %s%% %s' "$bpct" "$bsrc")"

  group "Activity"
  if [ "$lf" -gt 0 ]; then row "last fire" "$(date -r "$lf" '+%H:%M') $(dim "($(( (nowE-lf)/60 ))m ago, our ping)")"
  else row "last fire" "$(dim never)"; fi
  [ "$next_due" -gt 0 ] && row "next due" "$(date -r "$next_due" '+%H:%M')"
  if [ "$act" -gt 0 ]; then row "activity" "$(date -r "$act" '+%H:%M') $(dim "($(( (nowE-act)/60 ))m ago, your Claude Code use)")"
  else row "activity" "$(dim 'none detected')"; fi
  [ -n "$rec" ] && row "recovery" "$rec"
  [ -n "$lskip" ] && row "last skip" "$lskip"
  [ "$lu" -gt "$nowE" ] && row "limit" "$(yellow "$S_WARN paused") $(dim "until $(date -r "$lu" '+%H:%M')")"
  [ "$clu" -gt "$nowE" ] && row "codex lim" "$(yellow "$S_WARN paused") $(dim "until $(date -r "$clu" '+%H:%M')")"

  printf '\n'
  command -v ccusage >/dev/null 2>&1 && row "ccusage" "$(dim "installed — run 'ccusage blocks' for live token spend")"
  row "log"       "$(dim "$LOG")"
}

cmd_config() {
  case "${1:-get}" in
    get|show|"") echo "# $CONFIG"; [ -f "$CONFIG" ] && cat "$CONFIG" || echo "(defaults; not yet saved)";;
    path)        echo "$CONFIG";;
    edit)        local o_t="$TIME" o_w="$WAKE" o_d="$DAYS"
                 cp "$CONFIG" "$CONFIG.bak" 2>/dev/null || true
                 "${EDITOR:-vi}" "$CONFIG"
                 # shellcheck disable=SC1090
                 [ -f "$CONFIG" ] && source "$CONFIG"
                 if ! ( validate_config ) 2>&1; then
                   echo "invalid edit — reverting to previous config."
                   [ -f "$CONFIG.bak" ] && mv "$CONFIG.bak" "$CONFIG"
                   exit 2
                 fi
                 rm -f "$CONFIG.bak"; save_config    # normalize to %q form
                 if [ -f "$PLIST" ]; then
                   apply_agents; echo "(re-applied agents)"
                   if [ "$TIME" != "$o_t" ] || [ "$WAKE" != "$o_w" ] || [ "$DAYS" != "$o_d" ]; then reconcile_wake; fi
                 fi;;
    set)         local k="${2:-}" v="${3:-}"
                 [ -n "$k" ] || die "usage: claude-prewarm config set KEY VALUE"
                 case "$k" in
                   TIME) TIME="$v";; DAYS) DAYS="$v";; INTERVAL) INTERVAL="$v";;
                   WORKSTART) WORKSTART="$v";; END) END="$v";; MODE) MODE="$v";; KEEPALIVE) KEEPALIVE="$v";;
                   PROMPT) PROMPT="$v";; MODEL) MODEL="$v";; CODEX) CODEX="$v";;
                   CODEX_PROMPT) CODEX_PROMPT="$v";; CODEX_MODEL) CODEX_MODEL="$v";;
                   CALENDAR) CALENDAR="$v";; SKIP_DATES) SKIP_DATES="$v";;
                   LOW_BATTERY_SKIP) LOW_BATTERY_SKIP="$v";; MIN_BATTERY_PERCENT) MIN_BATTERY_PERCENT="$v";;
                   MIN_REMAINING_MIN) MIN_REMAINING_MIN="$v";; WAKE) WAKE="$v";;
                   STAYAWAKE) STAYAWAKE="$v";; NOTIFY) NOTIFY="$v";;
                   *) die "unknown key: $k
keys: TIME DAYS INTERVAL WORKSTART END MODE KEEPALIVE PROMPT MODEL CODEX CODEX_PROMPT CODEX_MODEL CALENDAR SKIP_DATES LOW_BATTERY_SKIP MIN_BATTERY_PERCENT MIN_REMAINING_MIN WAKE STAYAWAKE NOTIFY";;
                 esac
                 validate_config; save_config; echo "set $k=$v"
                 if [ -f "$PLIST" ]; then apply_agents; echo "(re-applied schedule)"
                   case "$k" in TIME|WAKE|DAYS) reconcile_wake;; esac; fi;;
    test-notify) NOTIFY=true notify routine "Claude prewarm" "Test notification — if you can read this, notifications work."
                 echo "sent. No banner? System Settings → Notifications → Claude Prewarm → Allow.";;
    *) die "usage: claude-prewarm config [get|set KEY VALUE|edit|path|test-notify]";;
  esac
}

cmd_logs() { [ "${1:-}" = "-f" ] && tail -f "$LOG" || tail -n "${1:-30}" "$LOG" 2>/dev/null || echo "(no log yet)"; }

usage() {
  local cols; cols=$(term_cols)

  printf '%s %s — %s\n\n' "$(bold claude-prewarm)" "$(dim "v$VERSION")" \
    "align Claude's 5-hour windows to your workday $(dim '(optional Codex ping)')"

  printf '%s\n' "$(bold USAGE)"
  KEYW=16; WRAP=$(( cols - KEYW - 4 )); [ "$WRAP" -lt 24 ] && WRAP=24
  trow "install"         "Interactive guided install (recommended for first run)."
  trow "install-default [flags]" "Non-interactive: schedule prewarms with defaults/flags (plus optional caffeinate and overnight wake)."
  trow "uninstall [-y] [--purge]" "Remove all agents and the wake schedule (asks to confirm). --purge also deletes the binary, libs, notifier app, config, and logs."
  trow "now"             "Fire one prewarm ping immediately."
  trow "status [--json]" "Show current state, schedule, guardrails, and the active window."
  trow "config ..."      "View or change settings: get | set KEY VALUE | edit | path | test-notify."
  trow "logs [-f|N]"     "Show recent fires (follow with -f, or the last N lines)."

  printf '\n%s\n' "$(bold 'HOW IT WORKS')"
  printf '%s\n' "A launchd agent checks every $((TICK_SECONDS/60)) minutes and fires only when the selected mode says a window is due. It reads Claude Code's local session logs, skips redundant pings when a window is already open, backs off on usage limits, and records late-fire recovery when the Mac was asleep." | fold -s -w $(( cols - 2 )) | sed 's/^/  /'
  printf '%s\n' "When Codex is enabled, it runs a separate headless 'codex exec --skip-git-repo-check --ephemeral --sandbox read-only' ping on the same cadence. Codex has a non-interactive mode, but it is not documented as using Claude-style 5-hour windows, so Codex support is opt-in." | fold -s -w $(( cols - 2 )) | sed 's/^/  /'

  printf '\n%s %s\n' "$(bold 'INSTALL-DEFAULT FLAGS')" "$(dim '(optional; persisted; validated)')"
  KEYW=20; WRAP=$(( cols - KEYW - 4 )); [ "$WRAP" -lt 24 ] && WRAP=24
  trow "--time HH:MM"       "Morning anchor — earliest a prewarm fires (default $TIME)."
  trow "--days SPEC"        "weekdays | daily | weekends | letters e.g. MWF (default $DAYS)."
  trow "--interval MIN"     "Window length in minutes, integer >= 5 (default $INTERVAL)."
  trow "--workstart HH:MM"  "When caffeinate begins keeping the Mac awake (default $WORKSTART)."
  trow "--end HH:MM"        "End of active period; last fire + caffeinate off (default $END)."
  trow "--mode MODE"        "aggressive | coverage | conserve | manual (default $MODE)."
  trow "--keepalive B"      "true|false — re-fire at each window boundary (default $KEEPALIVE)."
  trow "--no-keepalive"     "Fire only once per day."
  trow "--notify MODE"      "true (all) | delayed (late/failed only) | false (default $NOTIFY)."
  trow "--no-notify"        "Disable notifications."
  trow "--stay-awake"       "No-sudo caffeinate WORKSTART..END (won't beat a closed lid)."
  trow "--no-stay-awake"    "Disable caffeinate (default)."
  trow "--wake / --no-wake" "Wake the Mac before TIME; prompts for admin once (default wake). Needs AC power overnight — on battery macOS downgrades the wake to a brief dark wake and the prewarm is missed (a tick warns the evening before)."
  trow "--prompt TEXT"      "Message used to anchor the window (default \"$PROMPT\")."
  trow "--model NAME"       "Model override (default: your usual model)."
  trow "--calendar NAME"    "none | us | canada | north-america holiday skips (default $CALENDAR)."
  trow "--skip-dates CSV"   "Additional YYYY-MM-DD dates to skip."
  trow "--min-battery N"    "Skip scheduled pings on battery below N percent (default $MIN_BATTERY_PERCENT)."
  trow "--min-remaining N"  "Skip if fewer than N minutes remain before END (default $MIN_REMAINING_MIN)."
  trow "--low-battery-skip" "Enable low-battery guardrail (default $LOW_BATTERY_SKIP)."
  trow "--no-low-battery-skip" "Disable low-battery guardrail."
  trow "--codex / --no-codex" "Also run an opt-in Codex headless ping (default $CODEX)."
  trow "--codex-prompt TEXT" "Message sent to Codex (default follows --prompt)."
  trow "--codex-model NAME" "Codex model override (default: your usual model)."

  printf '\n%s\n' "$(bold GLOBAL)"
  KEYW=20; WRAP=$(( cols - KEYW - 4 )); [ "$WRAP" -lt 24 ] && WRAP=24
  trow "--no-color"    "Disable color. Also honored: NO_COLOR env; auto-off when piped."
  trow "--help"        "Show this help."
  trow "--version"     "Print the version."

  printf '\n%s\n' "$(bold EXAMPLES)"
  printf '  %s\n' "$(dim 'claude-prewarm install-default --time 05:00 --workstart 09:00 --end 17:00 --stay-awake')"
  printf '  %s\n' "$(dim 'claude-prewarm install-default --mode coverage --calendar us')"
  printf '  %s\n' "$(dim 'claude-prewarm install-default --codex --codex-prompt ping')"
  printf '  %s\n' "$(dim 'claude-prewarm config set END 18:30')"
  printf '  %s\n' "$(dim 'claude-prewarm config set SKIP_DATES 2026-11-27,2026-12-24')"
  printf '  %s\n' "$(dim 'claude-prewarm config set CODEX true')"
  printf '  %s\n' "$(dim 'claude-prewarm status --json')"
  printf '  %s\n' "$(dim 'claude-prewarm now')"
}

