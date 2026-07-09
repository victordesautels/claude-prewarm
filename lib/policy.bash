# ---- calendars and guardrails -----------------------------------------------
nth_weekday_ymd() {  # $1=year $2=month(1-12) $3=dow(0=Sun) $4=n
  local y="$1" m="$2" w="$3" n="$4" first first_dow day
  first="$(printf '%04d-%02d-01' "$y" "$m")"
  first_dow=$(date_dow "$first")
  day=$(( 1 + ((w - first_dow + 7) % 7) + (n - 1) * 7 ))
  printf '%04d-%02d-%02d\n' "$y" "$m" "$day"
}
last_weekday_ymd() {  # $1=year $2=month(1-12) $3=dow(0=Sun)
  local y="$1" m="$2" w="$3" next_y next_m last ep dow day
  if [ "$m" -eq 12 ]; then next_y=$(( y + 1 )); next_m=1; else next_y="$y"; next_m=$(( m + 1 )); fi
  ep=$(date_epoch "$(printf '%04d-%02d-01' "$next_y" "$next_m")")
  ep=$(( ep - 86400 ))
  last=$(epoch_day "$ep")
  dow=$(date_dow "$last")
  day=${last##*-}
  day=$(( 10#$day - ((dow - w + 7) % 7) ))
  printf '%04d-%02d-%02d\n' "$y" "$m" "$day"
}
observed_fixed_ymd() {  # $1=year $2=month $3=day
  local d ep dow
  d="$(printf '%04d-%02d-%02d' "$1" "$2" "$3")"
  ep=$(date_epoch "$d"); dow=$(date_dow "$d")
  case "$dow" in
    6) epoch_day $(( ep - 86400 )) ;;
    0) epoch_day $(( ep + 86400 )) ;;
    *) echo "$d" ;;
  esac
}
canada_victoria_day() {  # Monday before May 25
  local y="$1" ep dow day
  ep=$(date_epoch "$(printf '%04d-05-24' "$y")")
  dow=$(date -r "$ep" +%w)
  day=$(( 24 - ((dow - 1 + 7) % 7) ))
  printf '%04d-05-%02d\n' "$y" "$day"
}
is_us_holiday() {
  local d="$1" y mday
  y=${d%%-*}; mday=${d#*-}
  case "$mday" in
    01-01|06-19|07-04|11-11|12-25) return 0 ;;
  esac
  [ "$d" = "$(observed_fixed_ymd "$y" 1 1)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 6 19)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 7 4)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 11 11)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 12 25)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 1 1 3)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 2 1 3)" ] && return 0
  [ "$d" = "$(last_weekday_ymd "$y" 5 1)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 9 1 1)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 10 1 2)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 11 4 4)" ] && return 0
  return 1
}
is_canada_holiday() {
  local d="$1" y mday
  y=${d%%-*}; mday=${d#*-}
  case "$mday" in
    01-01|07-01|11-11|12-25|12-26) return 0 ;;
  esac
  [ "$d" = "$(observed_fixed_ymd "$y" 1 1)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 7 1)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 11 11)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 12 25)" ] && return 0
  [ "$d" = "$(observed_fixed_ymd "$y" 12 26)" ] && return 0
  [ "$d" = "$(canada_victoria_day "$y")" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 9 1 1)" ] && return 0
  [ "$d" = "$(nth_weekday_ymd "$y" 10 1 2)" ] && return 0
  return 1
}
holiday_name() {
  local d="${1:-$(date +%F)}"
  case ",$SKIP_DATES," in *",$d,"*) echo "custom skip date"; return 0;; esac
  case "$CALENDAR" in
    none|"") return 1 ;;
    us) is_us_holiday "$d" && { echo "US holiday"; return 0; } ;;
    canada) is_canada_holiday "$d" && { echo "Canada holiday"; return 0; } ;;
    north-america) if is_us_holiday "$d"; then echo "US holiday"; return 0; fi
                   if is_canada_holiday "$d"; then echo "Canada holiday"; return 0; fi ;;
  esac
  return 1
}
battery_info() {  # prints "source|percent"; source is ac, battery, or unknown
  local out source="unknown" pct=""
  out="$(pmset -g batt 2>/dev/null || true)"
  case "$out" in *"Battery Power"*) source="battery";; *"AC Power"*) source="ac";; esac
  pct="$(printf '%s\n' "$out" | sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | head -1)"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=""
  printf '%s|%s\n' "$source" "$pct"
}
current_skip_reason() {
  local n today h binfo bsrc bpct rem
  n=$(now_min); today=$(date '+%F')
  [ "$MODE" = "manual" ] && { echo "mode manual"; return 0; }
  { [ "$n" -ge "$(to_min "$TIME")" ] && [ "$n" -le "$(to_min "$END")" ]; } || { echo "outside active hours"; return 0; }
  is_scheduled_today || { echo "not a scheduled day"; return 0; }
  if h="$(holiday_name "$today")"; then echo "calendar skip: $h"; return 0; fi
  rem=$(( $(to_min "$END") - n ))
  if [ "$MIN_REMAINING_MIN" -gt 0 ] && [ "$rem" -lt "$MIN_REMAINING_MIN" ]; then
    echo "guardrail: only ${rem}m left before END"; return 0
  fi
  if [ "$LOW_BATTERY_SKIP" = "true" ]; then
    binfo="$(battery_info)"; bsrc="${binfo%%|*}"; bpct="${binfo##*|}"
    if [ "$bsrc" = "battery" ] && [[ "$bpct" =~ ^[0-9]+$ ]] && [ "$bpct" -lt "$MIN_BATTERY_PERCENT" ]; then
      echo "guardrail: battery ${bpct}%"; return 0
    fi
  fi
  return 1
}
# pmset scheduled wakes only produce a full wake on AC power. On battery the RTC
# alarm is serviced as a seconds-long dark wake, no tick runs, and the morning
# anchor is missed until the Mac is next opened (seen 2026-07-09: due 05:00,
# fired 09:08). Runs on every tick; only acts outside active hours, when the
# Mac may sleep unattended before its next scheduled wake. Warns once per
# target date; plugging in re-arms the warning in case the Mac is unplugged again.
check_wake_ac() {
  { [ "$WAKE" = "true" ] && [ "$MODE" != "manual" ] && [ -f "$WAKE_MARK" ]; } || return 0
  local n target bsrc
  n=$(now_min)
  if [ "$n" -gt "$(to_min "$END")" ]; then target="$(date -v+1d +%F)"  # tonight's wake = tomorrow morning
  elif [ "$n" -lt "$(to_min "$TIME")" ]; then target="$(date +%F)"     # today's wake is imminent
  else return 0; fi
  is_scheduled_on "$target" || return 0
  if holiday_name "$target" >/dev/null; then return 0; fi              # tick would skip anyway
  bsrc="$(battery_info)"; bsrc="${bsrc%%|*}"
  if [ "$bsrc" != "battery" ]; then rm -f "$WAKE_AC_WARNED"; return 0; fi
  [ "$(cat "$WAKE_AC_WARNED" 2>/dev/null)" = "$target" ] && return 0
  echo "$target" > "$WAKE_AC_WARNED"
  printf '%s  WARN    wake %s %s needs AC power; Mac is on battery\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$target" "$TIME" >> "$LOG"
  notify alert "Claude prewarm - plug in" "Mac is on battery. The $target $TIME wake will not fully wake it and the prewarm will be missed. Connect power."
  return 0
}
record_skip_once() {  # $1=agent $2=reason
  local agent="$1" reason="$2" key ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"; key="$(date '+%Y%m%d')|$agent|$reason"
  [ -f "$LAST_SKIP" ] && [ "$(cat "$LAST_SKIP" 2>/dev/null)" = "$key" ] && return 0
  echo "$key" > "$LAST_SKIP"
  printf '%s  SKIP    %s: %s\n' "$ts" "$agent" "$reason" >> "$LOG"
}
record_recovery() {  # $1=agent $2=due_epoch $3=fired_epoch $4=delay_min $5=next_epoch
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" > "$LAST_RECOVERY"
}
recovery_summary() {
  [ -f "$LAST_RECOVERY" ] || return 1
  local agent due fired delay next
  IFS='|' read -r agent due fired delay next < "$LAST_RECOVERY" || return 1
  [[ "$due" =~ ^[0-9]+$ ]] || return 1
  printf '%s due %s fired %s (+%sm), next %s\n' "$agent" "$(date -r "$due" '+%H:%M')" "$(date -r "$fired" '+%H:%M')" "$delay" "$(date -r "$next" '+%H:%M')"
}
next_due_epoch() {  # $1 = last fire epoch
  local lf="${1:-0}" nowE today lf_day due step
  [ "$MODE" = "manual" ] && { echo 0; return; }
  nowE=$(date '+%s'); today=$(date '+%Y%m%d'); step=$(mode_interval_min)
  lf_day=$( [ "$lf" -gt 0 ] && date -r "$lf" '+%Y%m%d' 2>/dev/null || echo 0 )
  if [ "$lf" -eq 0 ] || [ "$lf_day" != "$today" ]; then
    due=$(today_epoch "$TIME")
    [ "$due" -lt "$nowE" ] && due="$nowE"
  elif [ "$MODE" = "conserve" ]; then
    due=0
  else
    due=$(( lf + step * 60 ))
  fi
  echo "$due"
}
json_num_or_null() {
  local v="${1:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] && printf '%s' "$v" || printf null
}
# Best-effort: pull the reset time out of a limit message and return its epoch.
# Anchors near "reset" (so a "(UTC+05:30)" offset can't hijack it) and prefers an
# am/pm time over a bare colon time. Recognizes "3pm", "3:30 PM", "15:00". rc 1 if
# nothing parseable.
parse_reset_epoch() {   # $1 = message
  local msg="$1" scope h m ap base now
  case "$msg" in *[Rr]eset*) scope="${msg#*[Rr]eset}";; *) scope="$msg";; esac
  if   [[ "$scope" =~ ([0-9]{1,2}):([0-9]{2})[[:space:]]*([AaPp][Mm]) ]]; then   # H:MM am/pm
    h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; ap="${BASH_REMATCH[3]}"
  elif [[ "$scope" =~ ([0-9]{1,2})[[:space:]]*([AaPp][Mm]) ]]; then              # H am/pm
    h=${BASH_REMATCH[1]}; m=00; ap="${BASH_REMATCH[2]}"
  elif [[ "$scope" =~ ([0-9]{1,2}):([0-9]{2}) ]]; then                           # 24h H:MM
    h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; ap=""
  else return 1; fi
  case "$ap" in
    [Pp][Mm]) [ "$((10#$h))" -lt 12 ] && h=$(( 10#$h + 12 ));;
    [Aa][Mm]) [ "$((10#$h))" -eq 12 ] && h=0;;
  esac
  [ "$((10#$h))" -ge 0 ] && [ "$((10#$h))" -le 23 ] || return 1
  base="$(date -j -f '%Y-%m-%d %H:%M' "$(date +%F) $(printf '%02d:%02d' "$((10#$h))" "$((10#$m))")" +%s 2>/dev/null)" || return 1
  now=$(date +%s)
  [ "$base" -le "$now" ] && base=$(( base + 86400 ))   # reset is later today or tomorrow
  echo "$base"
}
# Detect a usage-limit response. On match: echo the reset epoch (0 if unknown) and
# return 0; return 1 for a normal response. Matches only the characteristic phrases
# ("limit reached", "limit will reset") — NOT bare "rate limit"/"usage limit", which
# a benign ping reply could contain (e.g. "rate limiting"). Guarded so a false hit
# can't crash a tick.
detect_limit() {   # $1 = ping output (newline-collapsed)
  local msg="$1" rst
  case "$msg" in
    *[Ll]"imit reached"*|*[Ll]"imit will reset"*)
      rst="$(parse_reset_epoch "$msg" 2>/dev/null || true)"
      echo "${rst:-0}"; return 0;;
  esac
  return 1
}

# ---- validation --------------------------------------------------------------
valid_hhmm() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }
# Lenient 24-hour time for interactive input: 6, 6:30, 06:30 -> zero-padded HH:MM.
normalize_hhmm() {
  local t="$1" h m
  case "$t" in *:*) h=${t%%:*} m=${t#*:};; *) h=$t m=00;; esac
  [[ "$h" =~ ^[0-9]{1,2}$ && "$m" =~ ^[0-5][0-9]$ ]] || return 1
  [ "$((10#$h))" -le 23 ] || return 1
  printf '%02d:%s\n' "$((10#$h))" "$m"
}
valid_int()  { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_bool() { [ "$1" = "true" ] || [ "$1" = "false" ]; }
valid_skip_dates() {
  local s="$1" oldifs part
  [ -z "$s" ] && return 0
  oldifs="$IFS"; IFS=,
  for part in $s; do
    IFS="$oldifs"
    [[ "$part" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [ -n "$(date_epoch "$part")" ] || return 1
    IFS=,
  done
  IFS="$oldifs"
  return 0
}

validate_config() {
  valid_hhmm "$TIME"      || die "TIME must be HH:MM (got '$TIME')"
  valid_hhmm "$WORKSTART" || die "WORKSTART must be HH:MM (got '$WORKSTART')"
  valid_hhmm "$END"       || die "END must be HH:MM (got '$END')"
  case "$MODE" in aggressive|coverage|conserve|manual) ;; *) die "MODE must be aggressive|coverage|conserve|manual (got '$MODE')";; esac
  case "$CALENDAR" in none|us|canada|north-america) ;; *) die "CALENDAR must be none|us|canada|north-america (got '$CALENDAR')";; esac
  { valid_int "$INTERVAL" && [ "$INTERVAL" -ge 5 ]; } || die "INTERVAL must be an integer >= 5 (got '$INTERVAL')"
  { valid_int "$MIN_BATTERY_PERCENT" && [ "$MIN_BATTERY_PERCENT" -ge 0 ] && [ "$MIN_BATTERY_PERCENT" -le 100 ]; } || die "MIN_BATTERY_PERCENT must be 0-100 (got '$MIN_BATTERY_PERCENT')"
  valid_int "$MIN_REMAINING_MIN" || die "MIN_REMAINING_MIN must be an integer >= 0 (got '$MIN_REMAINING_MIN')"
  valid_bool "$KEEPALIVE"  || die "KEEPALIVE must be true/false (got '$KEEPALIVE')"
  valid_bool "$CODEX"      || die "CODEX must be true/false (got '$CODEX')"
  valid_bool "$LOW_BATTERY_SKIP" || die "LOW_BATTERY_SKIP must be true/false (got '$LOW_BATTERY_SKIP')"
  valid_bool "$WAKE"       || die "WAKE must be true/false (got '$WAKE')"
  valid_bool "$STAYAWAKE"  || die "STAYAWAKE must be true/false (got '$STAYAWAKE')"
  case "$NOTIFY" in true|delayed|false) ;; *) die "NOTIFY must be true|delayed|false (got '$NOTIFY')";; esac
  valid_skip_dates "$SKIP_DATES" || die "SKIP_DATES must be comma-separated YYYY-MM-DD values (got '$SKIP_DATES')"
  [ "$(to_min "$END")" -gt "$(to_min "$TIME")" ]      || die "END ($END) must be after TIME ($TIME)"
  [ "$(to_min "$END")" -gt "$(to_min "$WORKSTART")" ] || die "END ($END) must be after WORKSTART ($WORKSTART)"
  [ "$CODEX" != "true" ] || [ -n "$CODEX_PROMPT" ] || die "CODEX_PROMPT cannot be empty when CODEX=true"
  [ -n "$(weekday_nums)" ] || die "DAYS selected no valid days (got '$DAYS')"
}

save_config() {   # %q round-trips arbitrary content safely (quotes, $(), spaces)
  case "$MODE" in aggressive|coverage) KEEPALIVE="true";; conserve|manual) KEEPALIVE="false";; esac
  {
    echo "# claude-prewarm config — regenerated by the tool."
    echo "# Prefer: claude-prewarm config set KEY VALUE   (values are auto-escaped)"
    printf 'TIME=%q\n'      "$TIME"
    printf 'DAYS=%q\n'      "$DAYS"
    printf 'INTERVAL=%q\n'  "$INTERVAL"
    printf 'WORKSTART=%q\n' "$WORKSTART"
    printf 'END=%q\n'       "$END"
    printf 'MODE=%q\n'      "$MODE"
    printf 'KEEPALIVE=%q\n' "$KEEPALIVE"
    printf 'PROMPT=%q\n'    "$PROMPT"
    printf 'MODEL=%q\n'     "$MODEL"
    printf 'CODEX=%q\n'     "$CODEX"
    printf 'CODEX_PROMPT=%q\n' "$CODEX_PROMPT"
    printf 'CODEX_MODEL=%q\n' "$CODEX_MODEL"
    printf 'CALENDAR=%q\n'  "$CALENDAR"
    printf 'SKIP_DATES=%q\n' "$SKIP_DATES"
    printf 'LOW_BATTERY_SKIP=%q\n' "$LOW_BATTERY_SKIP"
    printf 'MIN_BATTERY_PERCENT=%q\n' "$MIN_BATTERY_PERCENT"
    printf 'MIN_REMAINING_MIN=%q\n' "$MIN_REMAINING_MIN"
    printf 'WAKE=%q\n'      "$WAKE"
    printf 'STAYAWAKE=%q\n' "$STAYAWAKE"
    printf 'NOTIFY=%q\n'    "$NOTIFY"
  } > "$CONFIG"
}

last_skip_summary() {
  [ -f "$LAST_SKIP" ] || return 1
  local day agent reason
  IFS='|' read -r day agent reason < "$LAST_SKIP" || return 1
  [ -n "$day" ] && [ -n "$agent" ] && [ -n "$reason" ] || return 1
  printf '%s %s: %s\n' "$day" "$agent" "$reason"
}

# Nominal fire times for display only — the actual schedule self-heals at
# runtime. Shows anchor + each ideal window boundary up to END.
fire_times() {
  local anchor end i t step
  [ "$MODE" = "manual" ] && return 0
  anchor=$(to_min "$TIME"); end=$(to_min "$END"); i=0
  step=$(mode_interval_min)
  while [ "$i" -lt 2000 ]; do
    t=$(( anchor + i * step ))
    [ "$t" -ge 1440 ] && break
    [ "$i" -gt 0 ] && [ "$t" -gt "$end" ] && break
    to_hm "$t"
    [ "$MODE" = "conserve" ] && break
    i=$(( i + 1 ))
  done
}

# launchd Weekday integers: 0/7=Sun 1=Mon .. 5=Fri 6=Sat  (also used by `date +%w`)
weekday_nums() {
  case "$DAYS" in
    weekdays)           echo "1 2 3 4 5" ;;
    daily|all|everyday) echo "0 1 2 3 4 5 6" ;;
    weekends)           echo "0 6" ;;
    *) local s="$DAYS" out="" k c
       for (( k=0; k<${#s}; k++ )); do c=${s:k:1}
         case "$c" in
           M|m) out="$out 1";; T|t) out="$out 2";; W|w) out="$out 3";;
           R|r) out="$out 4";; F|f) out="$out 5";; S|s) out="$out 6";; U|u) out="$out 0";;
           *) echo "warning: unrecognized day letter '$c' ignored (use M T W R F S U)" >&2;;
         esac
       done; echo "$out" ;;
  esac
}

is_scheduled_on() {  # $1 = YYYY-MM-DD
  local dow; dow=$(date_dow "$1")
  case " $(weekday_nums) " in *" $dow "*) return 0;; *) return 1;; esac
}

is_scheduled_today() { is_scheduled_on "$(date +%F)"; }

pmset_days() {
  case "$DAYS" in
    weekdays)           echo "MTWRF" ;;
    daily|all|everyday) echo "MTWRFSU" ;;
    weekends)           echo "SU" ;;
    *)                  echo "$DAYS" ;;
  esac
}
