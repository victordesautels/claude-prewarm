#!/usr/bin/env bash
# ============================================================================
# claude-prewarm — dependency-free unit test harness (pure bash, macOS 3.2)
#
#   ./tests/run.sh            # or:  /usr/bin/env bash tests/run.sh
#
# Sources lib/ui.bash, lib/time_state.bash, lib/policy.bash and exercises the
# pure logic (time/JSON helpers, validators, calendar math, weekday parsing,
# limit parsing, config validation, schedule display). No bats, no brew, no
# external frameworks. Works under system bash 3.2 (no bash-4 features).
#
# Expected values for date math were verified independently against `date`
# (and by observing the functions once) and are hard-coded below.
# ============================================================================

# Resolve repo root from this script's location so it runs from anywhere.
SELF="${BASH_SOURCE[0]}"
TESTS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# NOTE: deliberately NO `set -u` — lib functions read globals we set per-test.
. "$ROOT/lib/ui.bash"
. "$ROOT/lib/time_state.bash"
. "$ROOT/lib/policy.bash"
. "$ROOT/lib/launchd.bash"   # runtime layer — exercised (stubbed) at the bottom
. "$ROOT/lib/fire.bash"      # runtime layer — exercised (stubbed) at the bottom
COLOR=0   # force plain output regardless of TTY detection in ui.bash

# ---- tiny assert framework --------------------------------------------------
PASS=0
FAIL=0

_pass() { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"
          [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "expected [$2] got [$3]"; fi
}

# assert_ok NAME CMD...   — CMD (run in a subshell) must exit 0
assert_ok() {
  local name="$1"; shift
  ( "$@" ) >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then _pass "$name"; else _fail "$name" "expected exit 0, got $rc"; fi
}

# assert_fail NAME CMD... — CMD (run in a subshell) must exit non-zero
assert_fail() {
  local name="$1"; shift
  ( "$@" ) >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then _pass "$name"; else _fail "$name" "expected non-zero, got 0"; fi
}

# assert_contains NAME HAYSTACK NEEDLE — HAYSTACK must contain NEEDLE
assert_contains() {
  case "$2" in
    *"$3"*) _pass "$1";;
    *)      _fail "$1" "[$2] does not contain [$3]";;
  esac
}

section() { printf '\n== %s ==\n' "$1"; }

# ---- test-only helper subjects (defined before use) -------------------------
_is_pos_int() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }

# holiday_name subjects
_hn_none()  { CALENDAR=none; SKIP_DATES=""; holiday_name "2026-07-04"; }
_hn_us_ok() { CALENDAR=us;   SKIP_DATES=""; holiday_name "2026-11-26"; }

# validate_config: start from a known-good config, then override ONE field.
_cfg_bad() {  # $1=field $2=value
  set_valid_config
  eval "$1=\"\$2\""
  validate_config
}
_cfg_bad_codex() {
  set_valid_config
  CODEX="true"; CODEX_PROMPT=""
  validate_config
}

# ============================================================================
# time / JSON helpers (lib/time_state.bash)
# ============================================================================
section "to_min"
assert_eq "to_min 09:30 -> 570"       570   "$(to_min 09:30)"
assert_eq "to_min 00:00 -> 0"         0     "$(to_min 00:00)"
assert_eq "to_min 23:59 -> 1439"      1439  "$(to_min 23:59)"
assert_eq "to_min 08:05 -> 485 (not octal)" 485 "$(to_min 08:05)"

section "to_hm"
assert_eq "to_hm 570 -> 09:30"   "09:30" "$(to_hm 570)"
assert_eq "to_hm 0 -> 00:00"     "00:00" "$(to_hm 0)"
assert_eq "to_hm 1439 -> 23:59"  "23:59" "$(to_hm 1439)"

section "to_hm/to_min round-trip"
for t in 00:00 08:05 09:30 12:34 17:00 23:59; do
  assert_eq "round-trip $t" "$t" "$(to_hm "$(to_min "$t")")"
done

section "json_escape"
assert_eq "escape backslash+quote" 'a\\b\"c' "$(json_escape 'a\b"c')"
LF=$'\n'
assert_eq "escape newline -> \\n" '\n' "$(json_escape "$LF")"

section "json_bool"
assert_eq "json_bool true"  "true"  "$(json_bool true)"
assert_eq "json_bool false" "false" "$(json_bool false)"
assert_eq "json_bool empty" "false" "$(json_bool '')"

section "mode_interval_min"
assert_eq "standard INTERVAL=300"   300 "$(MODE=standard; INTERVAL=300; mode_interval_min)"
assert_eq "daily INTERVAL=250"     250 "$(MODE=daily;   INTERVAL=250; mode_interval_min)"

section "ui: welcome_banner"
# title="abc"(3) sub="abcdef..."(10) -> w=10, inner=w+6=16, so each rule = 16 "─".
# Guards the bash 3.2 multibyte bug: a loop-built rule corrupts to a 2-byte stub,
# which would fail both the dash count and the top==bottom border check.
WB_OUT="$(welcome_banner abc abcdefghij)"
WB_TOP="$(printf '%s\n' "$WB_OUT" | sed -n '2p')"
WB_BOT="$(printf '%s\n' "$WB_OUT" | sed -n '5p')"
assert_eq "welcome_banner top rule = w+6"    16 "$(printf '%s' "$WB_TOP" | grep -o '─' | wc -l | tr -d ' ')"
assert_eq "welcome_banner bottom rule = w+6" 16 "$(printf '%s' "$WB_BOT" | grep -o '─' | wc -l | tr -d ' ')"
assert_contains "welcome_banner draws a rounded box top"    "$WB_TOP" "╭"
assert_contains "welcome_banner draws a rounded box bottom" "$WB_BOT" "╰"

section "read_lf"
LF_TMP="$(mktemp -t prewarm_lf.XXXXXX)"; rm -f "$LF_TMP"   # ensure missing
LAST_FIRE="$LF_TMP"
assert_eq "missing file -> 0" 0 "$(read_lf)"
printf '123456' > "$LF_TMP"
assert_eq "numeric file -> 123456" 123456 "$(read_lf)"
printf 'abc' > "$LF_TMP"
assert_eq "garbage file -> 0" 0 "$(read_lf)"
rm -f "$LF_TMP"

# ============================================================================
# validators (lib/policy.bash)
# ============================================================================
section "valid_hhmm"
for v in 09:30 9:30 00:00 23:59; do assert_ok   "accept '$v'" valid_hhmm "$v"; done
for v in 24:00 12:60 9:5 ab:cd '';  do assert_fail "reject '$v'" valid_hhmm "$v"; done

section "normalize_hhmm"
assert_eq "6 -> 06:00"        "06:00" "$(normalize_hhmm 6)"
assert_eq "6:30 -> 06:30"     "06:30" "$(normalize_hhmm 6:30)"
assert_eq "06:30 unchanged"   "06:30" "$(normalize_hhmm 06:30)"
assert_eq "17 -> 17:00"       "17:00" "$(normalize_hhmm 17)"
assert_eq "23:59 unchanged"   "23:59" "$(normalize_hhmm 23:59)"
assert_eq "0 -> 00:00"        "00:00" "$(normalize_hhmm 0)"
assert_eq "09 -> 09:00 (not octal)" "09:00" "$(normalize_hhmm 09)"
for v in 24 24:00 12:60 6:5 6:305 ab:cd 630 ''; do
  assert_fail "reject '$v'" normalize_hhmm "$v"
done

section "valid_int"
for v in 5 0 100; do assert_ok   "accept '$v'" valid_int "$v"; done
for v in x 1.5 ''; do assert_fail "reject '$v'" valid_int "$v"; done

section "valid_bool"
for v in true false;       do assert_ok   "accept '$v'" valid_bool "$v"; done
for v in yes TRUE 1 '';    do assert_fail "reject '$v'" valid_bool "$v"; done

section "valid_skip_dates"
assert_ok   "empty -> ok"                     valid_skip_dates ""
assert_ok   "two valid dates -> ok"           valid_skip_dates "2026-11-27,2026-12-24"
assert_fail "impossible month 2026-13-01"     valid_skip_dates "2026-13-01"
assert_fail "not-a-date"                       valid_skip_dates "not-a-date"

# ============================================================================
# weekday parsing (lib/policy.bash weekday_nums)
# ============================================================================
section "weekday_nums"
assert_eq "weekdays"          "1 2 3 4 5"      "$(DAYS=weekdays; weekday_nums)"
assert_eq "daily"             "0 1 2 3 4 5 6"  "$(DAYS=daily;    weekday_nums)"
assert_eq "weekends"          "0 6"            "$(DAYS=weekends; weekday_nums)"
assert_eq "MWF (leading spc)" " 1 3 5"         "$(DAYS=MWF;      weekday_nums)"
# unrecognized letters are skipped and warn on stderr
assert_eq "MXF skips X"       " 1 5"           "$(DAYS=MXF; weekday_nums 2>/dev/null)"
assert_eq "MXF warns"         "warning: unrecognized day letter 'X' ignored (use M T W R F S U)" \
                              "$(DAYS=MXF; weekday_nums 2>&1 >/dev/null)"

# ============================================================================
# holidays (lib/policy.bash) — dates verified independently vs `date`
# ============================================================================
section "is_us_holiday"
SKIP_DATES=""
assert_ok   "fixed: Independence Day 2026-07-04" is_us_holiday "2026-07-04"
assert_ok   "MLK 2026-01-19 (3rd Mon Jan)"       is_us_holiday "2026-01-19"
assert_ok   "Thanksgiving 2026-11-26 (4th Thu)"  is_us_holiday "2026-11-26"
assert_ok   "Thanksgiving 2027-11-25 (4th Thu)"  is_us_holiday "2027-11-25"
assert_fail "ordinary weekday 2026-07-15"        is_us_holiday "2026-07-15"

section "is_canada_holiday"
assert_ok   "Canada Day 2026-07-01"              is_canada_holiday "2026-07-01"
assert_ok   "Victoria Day 2026-05-18"            is_canada_holiday "2026-05-18"
assert_fail "ordinary weekday 2026-07-15"        is_canada_holiday "2026-07-15"

section "holiday_name"
assert_fail "CALENDAR=none -> no name"           _hn_none
# CALENDAR=us on a US holiday -> prints a name, returns 0
assert_eq "us + holiday prints name" "US holiday" \
          "$(CALENDAR=us; SKIP_DATES=''; holiday_name '2026-11-26')"
assert_ok "us + holiday returns 0" _hn_us_ok
# custom skip date wins regardless of calendar
assert_eq "custom skip date name" "custom skip date" \
          "$(CALENDAR=none; SKIP_DATES='2026-03-16'; holiday_name '2026-03-16')"

# ============================================================================
# limit parsing (lib/policy.bash parse_reset_epoch / detect_limit)
# ============================================================================
section "detect_limit / parse_reset_epoch"
assert_fail "detect_limit 'pong' not a limit"    detect_limit "pong"
assert_ok   "detect_limit 'limit reached' is limit" detect_limit "usage limit reached, resets 3pm"
# echoed epoch must be a positive integer when a time is present
LIM_EPOCH="$(detect_limit 'usage limit reached, resets 3pm')"
assert_ok   "detect_limit epoch is integer"      _is_pos_int "$LIM_EPOCH"
RST_EPOCH="$(parse_reset_epoch 'your limit will reset 3pm today')"
assert_ok   "parse_reset_epoch epoch is integer" _is_pos_int "$RST_EPOCH"
assert_fail "parse_reset_epoch 'no time here'"   parse_reset_epoch "no time here"
# Claude Code 2.x wording, verbatim from the 2026-08/09 log (both were logged as
# FAILED with no back-off before "hit your … limit" was recognized)
assert_eq   "spend limit w/o reset time -> epoch 0" 0 \
            "$(detect_limit "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit")"
SPEND_EPOCH="$(detect_limit "You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit · your weekly limit resets 6am (America/Toronto)")"
assert_ok   "org spend limit -> reset epoch"     _is_pos_int "$SPEND_EPOCH"
assert_eq   "  ...parsed as the next 06:00:00"   "06:00:00" "$(date -r "${SPEND_EPOCH:-0}" '+%H:%M:%S')"
assert_fail "'hit your' without 'limit' is not a limit" detect_limit "Looks like the ping hit your server"
# a dated reset is that day, not the next occurrence of the clock time
DATED_EPOCH="$(detect_limit "You've hit your weekly limit · resets Oct 27, 6am (America/Toronto)")"
assert_eq   "dated reset -> that day"            "Oct 27 06:00" "$(date -r "${DATED_EPOCH:-0}" '+%b %-d %H:%M')"
assert_ok   "  ...in the future"                 test "${DATED_EPOCH:-0}" -gt "$(date +%s)"

section "today_epoch"
assert_eq   "lands on the minute (no stray seconds)" 0 "$(( $(today_epoch 06:00) % 60 ))"

# ============================================================================
# config validation (lib/policy.bash validate_config) — die -> exit 2
# ============================================================================
section "validate_config"
set_valid_config() {
  TIME="09:00"; WORKSTART="08:00"; END="17:00"; MODE="standard"; CALENDAR="none"
  INTERVAL="30"; MIN_BATTERY_PERCENT="20"; MIN_REMAINING_MIN="30"
  KEEPALIVE="true"; CODEX="false"; LOW_BATTERY_SKIP="true"; WAKE="true"
  STAYAWAKE="false"; NOTIFY="true"; CODEX_PROMPT="do work"; DAYS="weekdays"; SKIP_DATES=""
}
set_valid_config
assert_ok   "full valid config exits 0"          validate_config
# flip one field invalid at a time (subshell so the tweak + die stay contained)
assert_fail "END before TIME"                    _cfg_bad END "08:00"
assert_fail "bad MODE"                            _cfg_bad MODE "turbo"
assert_fail "INTERVAL=3 (<5)"                     _cfg_bad INTERVAL "3"
assert_fail "NOTIFY=maybe"                        _cfg_bad NOTIFY "maybe"
assert_fail "MIN_BATTERY_PERCENT=150"             _cfg_bad MIN_BATTERY_PERCENT "150"
assert_fail "CODEX=true w/ empty CODEX_PROMPT"    _cfg_bad_codex
assert_fail "DAYS with no valid letters"          _cfg_bad DAYS "XYZ"

# ============================================================================
# fire_times (lib/policy.bash) — display schedule
# ============================================================================
section "fire_times"
assert_eq "standard 09:00-17:00 @300m" "$(printf '09:00\n14:00')" \
          "$(MODE=standard; TIME=09:00; END=17:00; INTERVAL=300; fire_times)"
assert_eq "standard first line 09:00" "09:00" \
          "$(MODE=standard; TIME=09:00; END=17:00; INTERVAL=300; fire_times | head -1)"
assert_eq "daily -> single time"      "09:00" \
          "$(MODE=daily; TIME=09:00; END=17:00; INTERVAL=300; fire_times)"

# ============================================================================
# RUNTIME LAYER (lib/launchd.bash, lib/fire.bash) — stubbed integration tests
#
# These exercise the launchd / pmset / notify / fire logic WITHOUT touching the
# real system: a sandbox state dir plus stub `claude`, `codex`, `launchctl`,
# `pmset`, `sudo`, `caffeinate`, and `osascript` binaries prepended to PATH.
# No real pings, agents, wakes, or notifications are produced. Assertions read
# the sandbox log, state files, generated plists, and recorded stub calls.
# ============================================================================
RT_SANDBOX="$(mktemp -d -t prewarm_rt.XXXXXX)"
RT_CALLS="$RT_SANDBOX/calls";    mkdir -p "$RT_CALLS"
RT_STUBSTATE="$RT_SANDBOX/stub"; mkdir -p "$RT_STUBSTATE"
STUB_BIN="$RT_SANDBOX/bin";      mkdir -p "$STUB_BIN"
export RT_CALLS RT_STUBSTATE

# runtime globals normally exported by bin/claude-prewarm
STATE_DIR="$RT_SANDBOX/state";   mkdir -p "$STATE_DIR"
CONFIG_DIR="$RT_SANDBOX/config"; mkdir -p "$CONFIG_DIR"
CONFIG="$CONFIG_DIR/config"
LOG="$STATE_DIR/prewarm.log";    : > "$LOG"
LAST_FIRE="$STATE_DIR/last_fire"
LIMIT_UNTIL="$STATE_DIR/limit_until"
CODEX_LAST_FIRE="$STATE_DIR/codex_last_fire"
CODEX_LIMIT_UNTIL="$STATE_DIR/codex_limit_until"
LAST_SKIP="$STATE_DIR/last_skip"
LAST_RECOVERY="$STATE_DIR/last_recovery"
WAKE_MARK="$STATE_DIR/wake_set"
WAKE_AC_WARNED="$STATE_DIR/wake_ac_warned"
FIRE_HISTORY="$STATE_DIR/fire_history"
LAST_TICK="$STATE_DIR/last_tick"
WINDOW_CACHE="$STATE_DIR/window_open"
FAIL_BACKOFF="$STATE_DIR/fail_backoff"
CODEX_FAIL_BACKOFF="$STATE_DIR/codex_fail_backoff"
CLAUDE_PROJECTS="$RT_SANDBOX/claude_projects"; mkdir -p "$CLAUDE_PROJECTS"  # empty => no open window
PLIST="$RT_SANDBOX/agent.plist"
AWAKE_PLIST="$RT_SANDBOX/awake.plist"
LABEL="com.claude-prewarm.test"
AWAKE_LABEL="com.claude-prewarm.test.awake"
SELF="$STUB_BIN/claude-prewarm"
TICK_SECONDS=300; GRACE_MIN=8; PING_TIMEOUT=180

_mkstub() {  # $1=name  $2=body (single-quoted; $RT_* expand at stub runtime, not now)
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; } > "$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}
# claude: $STUB_CLAUDE_HANG turns it into a silent sleep that long — a hung ping
# (exec, so the watchdog's TERM leaves no orphaned child).
_mkstub claude     'echo "$@" >> "$RT_CALLS/claude"; [ -n "${STUB_CLAUDE_HANG:-}" ] && exec /bin/sleep "$STUB_CLAUDE_HANG"; printf "%s" "${STUB_CLAUDE_OUT:-pong}"; exit "${STUB_CLAUDE_RC:-0}"'
_mkstub codex      'echo "$@" >> "$RT_CALLS/codex";  printf "%s" "${STUB_CODEX_OUT:-pong}";  exit "${STUB_CODEX_RC:-0}"'
_mkstub caffeinate 'echo "$@" >> "$RT_CALLS/caffeinate"; exit 0'
# sleep: real unless $STUB_SLEEP is set (then it only records), so wait_for_time
# can be tested without waiting while run_with_timeout's watchdog still sleeps.
_mkstub sleep      '[ -n "${STUB_SLEEP:-}" ] && { echo "$@" >> "$RT_CALLS/sleep"; exit 0; }; exec /bin/sleep "$@"'
_mkstub osascript  'echo "$@" >> "$RT_CALLS/osascript"; exit 0'
_mkstub sudo       'echo "$@" >> "$RT_CALLS/sudo"; exec "$@"'
# pmset: emits $STUB_PMSET_BATT for `-g batt` so battery_info can be driven.
_mkstub pmset      'echo "$@" >> "$RT_CALLS/pmset"; if [ "$1" = "-g" ] && [ -n "${STUB_PMSET_BATT:-}" ]; then printf "%s\n" "$STUB_PMSET_BATT"; fi; exit 0'
# launchctl: tracks a per-LABEL "loaded" marker so different agents stay distinct
# (a bug that bootout'd the wrong label would then be visible). `print` honors
# $STUB_NO_PRINT (simulating older macOS without `print`) to force the
# agent_loaded `list|grep` fallback. The label comes from the gui/UID/LABEL arg,
# or is read out of the plist for bootstrap/load.
_mkstub launchctl  'echo "$@" >> "$RT_CALLS/launchctl"
lbl=""
case "$1" in
  bootstrap|load)
    for a in "$@"; do case "$a" in *.plist) lbl="$(grep -o "<string>[^<]*</string>" "$a" | head -1 | sed -E "s/<[^>]*>//g")";; esac; done
    [ -n "$lbl" ] && : > "$RT_STUBSTATE/loaded.$lbl";;
  bootout|unload)
    for a in "$@"; do case "$a" in gui/*/*) lbl="${a##*/}";; *.plist) lbl="$(grep -o "<string>[^<]*</string>" "$a" | head -1 | sed -E "s/<[^>]*>//g")";; esac; done
    [ -n "$lbl" ] && rm -f "$RT_STUBSTATE/loaded.$lbl";;
  print) [ -n "${STUB_NO_PRINT:-}" ] && exit 1; lbl="${2##*/}"; [ -f "$RT_STUBSTATE/loaded.$lbl" ] && exit 0 || exit 1;;
  list)  for f in "$RT_STUBSTATE"/loaded.*; do [ -e "$f" ] && echo "${f##*/loaded.}"; done;;
esac
exit 0'
PATH="$STUB_BIN:$PATH"; export PATH

_logtail()    { tail -n1 "$LOG" 2>/dev/null; }
_reset_fire() { : > "$LOG"; rm -f "$LAST_FIRE" "$LIMIT_UNTIL" "$LAST_SKIP" "$FIRE_HISTORY" "$FAIL_BACKOFF" "$WINDOW_CACHE" "$RT_CALLS/claude"; rm -rf "$STATE_DIR/fire.lock"; PREV_TICK=0; }
_reset_codex(){ : > "$LOG"; rm -f "$CODEX_LAST_FIRE" "$CODEX_LIMIT_UNTIL" "$CODEX_FAIL_BACKOFF" "$RT_CALLS/codex"; rm -rf "$STATE_DIR/codex.fire.lock"; }
# Tests that set TIME to "now ± N minutes" by the wall clock: skip them while
# those wall-clock times are not really N minutes from now — across a DST change
# (a skipped or repeated hour) or past midnight.
_wallclock_ok() {  # $@ = minute offsets the test builds TIME from
  local n now d
  n=$(now_min); now=$(( $(date +%s) / 60 * 60 ))
  for d in 0 "$@"; do
    { [ $(( n + d )) -ge 0 ] && [ $(( n + d )) -lt 1440 ]; } || return 1
    [ "$(today_epoch "$(to_hm $(( n + d )))")" = $(( now + d * 60 )) ] || return 1
  done
}
# hold_awake starts caffeinate in the background: give the stub a moment to log.
_wait_for_call() {  # $1 = stub name, $2 = needle
  local i=0
  while [ "$i" -lt 40 ]; do
    case "$(cat "$RT_CALLS/$1" 2>/dev/null)" in *"$2"*) return 0;; esac
    /bin/sleep 0.05; i=$(( i + 1 ))
  done
  return 1
}

set_valid_config   # baseline valid config (defined in the validate_config section)

# ---- launchd: plist generation ---------------------------------------------
section "launchd: gen_plist"
WORKSTART="09:00"; DAYS="weekdays"; MODE="standard"
gen_plist
PLIST_TXT="$(cat "$PLIST" 2>/dev/null)"
assert_ok       "gen_plist writes \$PLIST"      test -f "$PLIST"
assert_contains "plist carries the Label"       "$PLIST_TXT" "<string>$LABEL</string>"
assert_contains "plist runs the 'tick' verb"    "$PLIST_TXT" "<string>tick</string>"
assert_contains "plist StartInterval 300"       "$PLIST_TXT" "<integer>300</integer>"
assert_contains "plist has RunAtLoad"           "$PLIST_TXT" "<key>RunAtLoad</key>"

section "launchd: gen_awake_plist"
WORKSTART="09:30"; DAYS="weekdays"
gen_awake_plist
AWK_TXT="$(cat "$AWAKE_PLIST" 2>/dev/null)"
assert_contains "awake plist Hour 9"            "$AWK_TXT" "<key>Hour</key><integer>9</integer>"
assert_contains "awake plist Minute 30"         "$AWK_TXT" "<key>Minute</key><integer>30</integer>"
assert_eq       "awake plist has 5 weekdays"    5 "$(grep -c '<key>Weekday</key>' "$AWAKE_PLIST")"

# ---- launchd: agent load / unload ------------------------------------------
section "launchd: reload / unload"
rm -f "$RT_STUBSTATE"/loaded.*
gen_plist
reload "$LABEL" "$PLIST"
assert_ok   "reload -> agent_loaded true"        agent_loaded "$LABEL"
unload_agent "$LABEL" "$PLIST"
assert_fail "unload_agent -> agent_loaded false" agent_loaded "$LABEL"

# agent_loaded must also work on macOS without `launchctl print` (the list|grep
# fallback). STUB_NO_PRINT forces print to fail so only the fallback can answer.
section "launchd: agent_loaded list fallback"
_al_noprint() { ( export STUB_NO_PRINT=1; agent_loaded "$LABEL" ); }
rm -f "$RT_STUBSTATE"/loaded.*
gen_plist; reload "$LABEL" "$PLIST"
assert_ok   "list fallback finds a loaded agent"  _al_noprint
unload_agent "$LABEL" "$PLIST"
assert_fail "list fallback: absent after unload"  _al_noprint

section "launchd: apply_agents"
rm -f "$RT_STUBSTATE"/loaded.* ; : > "$AWAKE_PLIST"   # stale awake plist present
STAYAWAKE="false"; DAYS="weekdays"; WORKSTART="09:00"
apply_agents
assert_ok   "writes the main plist"              test -f "$PLIST"
assert_ok   "leaves the MAIN agent loaded"       agent_loaded "$LABEL"   # awake unload must not clobber it
assert_fail "removes awake plist when STAYAWAKE=false" test -f "$AWAKE_PLIST"
STAYAWAKE="true"; apply_agents
assert_ok   "builds awake plist when STAYAWAKE=true"   test -f "$AWAKE_PLIST"
STAYAWAKE="false"

# ---- launchd: notification gating ------------------------------------------
# HOME points at the sandbox (no notifier .app there) so notify falls back to
# the osascript stub — verifying the NOTIFY policy without real notifications.
section "launchd: notify gating"
_notify() { ( HOME="$RT_SANDBOX"; NOTIFY="$1"; notify "$2" "Title" "Msg" ); }
rm -f "$RT_CALLS/osascript"; _notify false   routine
assert_fail "NOTIFY=false suppresses"            test -s "$RT_CALLS/osascript"
rm -f "$RT_CALLS/osascript"; _notify delayed routine
assert_fail "NOTIFY=delayed drops routine"       test -s "$RT_CALLS/osascript"
rm -f "$RT_CALLS/osascript"; _notify delayed alert
assert_ok   "NOTIFY=delayed keeps alert"         test -s "$RT_CALLS/osascript"
rm -f "$RT_CALLS/osascript"; _notify true    routine
assert_ok   "NOTIFY=true notifies"               test -s "$RT_CALLS/osascript"

# ---- launchd: pmset wake (sudo stubbed) ------------------------------------
section "launchd: reconcile_wake"
rm -f "$WAKE_MARK" "$RT_CALLS/pmset"
( MODE="standard"; WAKE="true"; TIME="05:00"; DAYS="weekdays"; reconcile_wake ) >/dev/null 2>&1
assert_ok       "set_wake writes the wake marker"  test -f "$WAKE_MARK"
assert_contains "set_wake calls pmset repeat"      "$(cat "$RT_CALLS/pmset" 2>/dev/null)" "repeat"
( MODE="manual"; reconcile_wake ) >/dev/null 2>&1  # marker present -> clear it
assert_fail     "manual mode clears the wake marker" test -f "$WAKE_MARK"

# ---- policy: battery_info + check_wake_ac ----------------------------------
section "policy: battery_info"
_batt() { ( export STUB_PMSET_BATT="$1"; battery_info ); }
assert_eq "battery_info reads AC + percent"      "ac|80"      "$(_batt "Now drawing from 'AC Power'; -InternalBattery-0 80%; charged;")"
assert_eq "battery_info reads battery + percent" "battery|15" "$(_batt "Now drawing from 'Battery Power'; -InternalBattery-0 15%; discharging;")"

# On battery, an outside-active-hours tick must warn that the scheduled wake
# needs AC. TIME=00:00/END=00:01 keeps 'now' past END for all but the first
# minutes of the day (skipped then), so the target is always tomorrow's wake.
section "policy: check_wake_ac warns on battery"
if [ "$(now_min)" -ge 2 ]; then
  rm -f "$WAKE_AC_WARNED" "$RT_CALLS/pmset"; : > "$LOG"; : > "$WAKE_MARK"
  ( export STUB_PMSET_BATT="Now drawing from 'Battery Power'; -InternalBattery-0 15%; discharging;"
    WAKE="true"; MODE="standard"; DAYS="daily"; CALENDAR="none"; SKIP_DATES=""
    TIME="00:00"; END="00:01"; NOTIFY="false"; check_wake_ac )
  assert_contains "logs a plug-in warning"        "$(cat "$LOG")" "needs AC power"
  assert_ok       "records the warned target date" test -s "$WAKE_AC_WARNED"
else
  _pass "check_wake_ac (skipped: first minutes of day)"
fi

# ---- time_state: window_anchor from session logs ---------------------------
section "time_state: window_anchor"
rm -f "$LAST_FIRE" "$FIRE_HISTORY" "$CLAUDE_PROJECTS"/*.jsonl
WA_NOW=$(date +%s)
_iso() { date -u -r "$(( WA_NOW - $1 ))" '+%Y-%m-%dT%H:%M:%S.000Z'; }   # $1 = seconds ago
# a session record shaped like Claude Code's: top-level "uuid","timestamp" after
# the message. $1 = user|assistant  $2 = seconds ago  $3 = model  $4 = extra content
_rec() {
  printf '{"parentUuid":null,"isSidechain":false,"type":"%s","message":{"role":"%s","model":"%s","content":[%s]},"uuid":"00000000-0000-4000-8000-%012d","timestamp":"%s"}\n' \
    "$1" "$1" "${3:-claude-opus}" "${4:-}" "$RANDOM" "$(_iso "$2")"
}
_reply() { _rec assistant "$1" "${2:-claude-opus}"; }
assert_eq "no logs + no last-fire -> anchor 0"     0 "$(INTERVAL=300; window_anchor)"
_reply 180 > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "reply 3m ago -> window opened then"     "$(( WA_NOW - 180 ))" "$(INTERVAL=300; window_anchor)"
_reply 21600 > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "6h-old reply (5h window) -> closed"     0 "$(INTERVAL=300; window_anchor)"
_rec user 180 > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "user line alone (no API reply) -> closed" 0 "$(INTERVAL=300; window_anchor)"
# A reply is dated by its request (the user record before it): a request sent
# inside the 06:00-11:00 window whose reply streams back just after 11:00 opens
# no new window. Ping 5h10m ago, request 10m10s ago... reply 9m50s ago.
printf '%s\n' "$(( WA_NOW - 18600 ))" > "$FIRE_HISTORY"
{ _rec user 610; _reply 590; } > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "reply past the boundary, request inside -> closed" 0 "$(INTERVAL=300; window_anchor)"
rm -f "$FIRE_HISTORY"
# Only the record's own timestamp counts: not a "timestamp" nested in tool-call
# arguments, and nothing in the future (a tool call scheduling 18:00 at 10:00).
_rec assistant 21600 claude-opus "{\"type\":\"tool_use\",\"input\":{\"timestamp\":\"$(_iso 120)\"}}" > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "timestamp nested in tool args -> ignored" 0 "$(INTERVAL=300; window_anchor)"
_reply -3600 > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "record dated in the future -> ignored" 0 "$(INTERVAL=300; window_anchor)"
_reply 180 '<synthetic>' > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "synthetic error reply -> closed"        0 "$(INTERVAL=300; window_anchor)"
# a session started yesterday and resumed today: its first line is old, but the
# reply 1h ago opened today's window
{ _reply 79200; _reply 3600; } > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "resumed session -> today's window"      "$(( WA_NOW - 3600 ))" "$(INTERVAL=300; window_anchor)"
# Our pings leave no session log. Pings 7h and 2h ago, your work 4h ago: the 4h-ago
# reply sat inside the 7h-ago window, so the open window is the 2h-ago ping's.
_reply 14400 > "$CLAUDE_PROJECTS/session.jsonl"
printf '%s\n%s\n' "$(( WA_NOW - 25200 ))" "$(( WA_NOW - 7200 ))" > "$FIRE_HISTORY"
printf '%s' "$(( WA_NOW - 7200 ))" > "$LAST_FIRE"
assert_eq "ping history keeps the real boundary"   "$(( WA_NOW - 7200 ))" "$(INTERVAL=300; window_anchor)"
# The log is never parsed for pings (its local stamps read back hours off in
# another TZ): with a 25200s-ago ping logged but not in fire_history, the
# 14400s-ago reply still anchors the window.
{ printf '%s  ok  anchor on-time        window~x\n' "$(date -r "$(( WA_NOW - 25200 ))" '+%Y-%m-%d %H:%M:%S')"; } > "$LOG"
printf '%s\n' "$(( WA_NOW - 7200 ))" > "$FIRE_HISTORY"
assert_eq "logged pings are not read back"         "$(( WA_NOW - 14400 ))" "$(INTERVAL=300; window_anchor)"
rm -f "$FIRE_HISTORY"
assert_eq "  ...nor without a fire_history"        "$(( WA_NOW - 14400 ))" "$(INTERVAL=300; window_anchor)"
printf '%s\n%s\n' "$(( WA_NOW - 90000 ))" "$(( WA_NOW - 7200 ))" > "$FIRE_HISTORY"
record_ping "$WA_NOW"
assert_eq "record_ping appends and drops pings over a day old" \
          "$(printf '%s\n%s' "$(( WA_NOW - 7200 ))" "$WA_NOW")" "$(cat "$FIRE_HISTORY")"
# a NUL from a crash mid-write must not make grep treat a session log as binary
{ printf 'garbage\0\0\0\n'; _reply 180; } > "$CLAUDE_PROJECTS/session.jsonl"; rm -f "$FIRE_HISTORY" "$LAST_FIRE"
assert_eq "NUL-damaged session log still read"     "$(( WA_NOW - 180 ))" "$(INTERVAL=300; window_anchor)"
: > "$LOG"
rm -f "$LAST_FIRE" "$FIRE_HISTORY" "$CLAUDE_PROJECTS"/*.jsonl

# The tick reuses an open window's anchor until that window ends.
section "time_state: window_anchor_cached"
rm -f "$WINDOW_CACHE"; WA_NOW=$(date +%s)
_reply 180 > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "open window -> anchor, cached"         "$(( WA_NOW - 180 ))" "$(INTERVAL=300; window_anchor_cached)"
rm -f "$CLAUDE_PROJECTS"/*.jsonl
assert_eq "  ...reused while it lasts (no rescan)" "$(( WA_NOW - 180 ))" "$(INTERVAL=300; window_anchor_cached)"
assert_eq "  ...not reused under another INTERVAL" 0 "$(INTERVAL=60; window_anchor_cached)"
printf '%s 18000\n' "$(( WA_NOW - 18060 ))" > "$WINDOW_CACHE"
assert_eq "  ...expired cache -> rescan"           0 "$(INTERVAL=300; window_anchor_cached)"
rm -f "$WINDOW_CACHE"

# ---- fire: do_fire outcomes -------------------------------------------------
section "fire: do_fire success"
_reset_fire
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; PROMPT="ping"; MODEL=""; NOTIFY="false"; CODEX="false"; do_fire tick )
assert_ok       "records a positive last_fire"    _is_pos_int "$(read_lf)"
assert_contains "logs an ok anchor fire"          "$(_logtail)" "ok  anchor"
assert_contains "invokes claude with -p"          "$(cat "$RT_CALLS/claude" 2>/dev/null)" "-p"
assert_contains "ping skips session persistence"  "$(cat "$RT_CALLS/claude" 2>/dev/null)" "--no-session-persistence"
assert_eq       "records the ping in fire_history" "$(read_lf)" "$(tail -n1 "$FIRE_HISTORY" 2>/dev/null)"
assert_ok       "holds the Mac awake for the ping" _wait_for_call caffeinate "-w"

# A boundary fire that's overdue (Mac was asleep) must log DELAYED and record
# recovery. Seed last-fire 1h ago; with INTERVAL=5 the boundary was due ~55m ago.
# (The previous tick ran 50m ago: the Mac slept through the boundary. Skipped in
# the first 70 minutes of the day, when last-fire-1h-ago would be yesterday.)
section "fire: do_fire delayed recovery"
if [ "$(now_min)" -ge 70 ]; then
  _reset_fire; rm -f "$LAST_RECOVERY"
  printf '%s' "$(( $(date +%s) - 3600 ))" > "$LAST_FIRE"
  ( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"; PREV_TICK=$(( $(date +%s) - 3000 ))
    MODE="standard"; INTERVAL=5; TIME="00:00"; END="23:59"; PROMPT="ping"; MODEL=""; NOTIFY="false"; CODEX="false"; do_fire tick )
  assert_contains "logs a DELAYED fire"           "$(_logtail)" "DELAYED due="
  assert_ok       "writes recovery state"         test -s "$LAST_RECOVERY"
  # first tick since install/upgrade: no previous tick to judge sleep by
  _reset_fire; rm -f "$LAST_RECOVERY" "$RT_CALLS/osascript"
  printf '%s' "$(( $(date +%s) - 3600 ))" > "$LAST_FIRE"
  ( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"; PREV_TICK=0
    MODE="standard"; INTERVAL=5; TIME="00:00"; END="23:59"; NOTIFY="delayed"; CODEX="false"; do_fire tick )
  assert_contains "unknown previous tick -> held, not asleep" "$(_logtail)" "held +55m (first tick, cause unknown)"
  assert_fail     "  ...no alert"                 test -s "$RT_CALLS/osascript"
else
  _pass "do_fire delayed recovery (skipped: first 70 minutes of day)"
fi

section "fire: do_fire usage-limit backoff"
_reset_fire
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="Your usage limit reached; limit will reset 3pm"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_ok       "writes a positive limit_until"   _is_pos_int "$(read_limit_until)"
assert_contains "logs a LIMIT line"               "$(_logtail)" "LIMIT"
assert_eq       "does NOT advance last_fire"      0 "$(read_lf)"

section "fire: do_fire spend limit (rc=1) backs off"
_reset_fire
( export STUB_CLAUDE_RC=1 STUB_CLAUDE_OUT="You've hit your org's monthly spend limit · your weekly limit resets 6am (America/Toronto)"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_contains "logs LIMIT, not FAILED"          "$(_logtail)" "LIMIT"
assert_ok       "writes a positive limit_until"   _is_pos_int "$(read_limit_until)"

# A failed ping backs off 15m, 30m, then hourly, and only the first failure of the
# streak notifies — before this, every 5-minute tick re-pinged and re-alerted.
section "fire: do_fire failure backs off"
_reset_fire; rm -f "$RT_CALLS/osascript"
_fail_fire() { ( export STUB_CLAUDE_RC=7 STUB_CLAUDE_OUT="boom"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="true"; do_fire tick ); }
_fail_fire
FB_NOW=$(date +%s)
assert_contains "logs a FAILED line with rc"      "$(_logtail)" "FAILED  rc=7  retry"
assert_eq       "does NOT advance last_fire"      0 "$(read_lf)"
assert_eq       "streak 1"                        1 "$(cut -d'|' -f1 "$FAIL_BACKOFF")"
assert_ok       "retry ~15m out"                  test $(( $(read_fail_until "$FAIL_BACKOFF") - FB_NOW )) -ge 890
assert_ok       "first failure notifies"          test -s "$RT_CALLS/osascript"
rm -f "$RT_CALLS/osascript"; _fail_fire
assert_eq       "streak 2"                        2 "$(cut -d'|' -f1 "$FAIL_BACKOFF")"
assert_ok       "retry ~30m out"                  test $(( $(read_fail_until "$FAIL_BACKOFF") - FB_NOW )) -ge 1790
assert_fail     "second failure stays quiet"      test -s "$RT_CALLS/osascript"
_fail_fire
assert_ok       "third retry ~60m out"            test $(( $(read_fail_until "$FAIL_BACKOFF") - FB_NOW )) -ge 3590
# the streak is keyed on the last failure's day, not the retry time (which can
# cross midnight); two days back stays a different date even across DST
printf '9|%s|%s\n' "$(( FB_NOW + 3600 ))" "$(( FB_NOW - 172800 ))" > "$FAIL_BACKOFF"; _fail_fire
assert_eq       "an earlier day's streak restarts at 1" 1 "$(cut -d'|' -f1 "$FAIL_BACKOFF")"
printf '3|%s|%s\n' "$(( FB_NOW + 172800 ))" "$FB_NOW" > "$FAIL_BACKOFF"; _fail_fire
assert_eq       "retry on another day keeps today's streak" 4 "$(cut -d'|' -f1 "$FAIL_BACKOFF")"
printf '2|123\n' > "$FAIL_BACKOFF"
assert_eq       "reads a 0.5.3 two-field back-off" 123 "$(read_fail_until "$FAIL_BACKOFF")"
# 0.5.3 two-field files: the failure was one back-off (30m at streak 2) before the retry
printf '2|%s\n' "$(( FB_NOW + 1800 ))" > "$FAIL_BACKOFF"; _fail_fire
assert_eq       "  ...and continues its streak"   3 "$(read_fail_streak "$FAIL_BACKOFF")"
# failed yesterday 23:50, retry today 00:20: today's first failure starts afresh
printf '2|%s\n' "$(today_epoch 00:20)" > "$FAIL_BACKOFF"; _fail_fire
assert_eq       "  ...a pre-midnight one restarts" 1 "$(read_fail_streak "$FAIL_BACKOFF")"
printf '2|%s\n' "$(( FB_NOW + 1800 ))" > "$FAIL_BACKOFF"; _fail_fire
rm -f "$RT_CALLS/osascript"
( export STUB_CLAUDE_RC=7 STUB_CLAUDE_OUT="boom"
  MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="true"; do_fire manual )
assert_contains "manual failure logs 'manual'"    "$(_logtail)" "FAILED  rc=7  manual"
assert_eq       "manual failure leaves the schedule's back-off alone" 3 "$(read_fail_streak "$FAIL_BACKOFF")"
assert_contains "manual failure still notifies"   "$(cat "$RT_CALLS/osascript" 2>/dev/null)" "Manual ping failed"
assert_eq       "retry inside hours -> 'Retrying at'" "Retrying at 10:15." "$(TIME=06:00; END=18:00; MIN_REMAINING_MIN=60; retry_text 10:15)"
assert_eq       "retry after the guardrail cutoff -> none today" "No retry today (last prewarm by 17:00)." \
                "$(TIME=06:00; END=18:00; MIN_REMAINING_MIN=60; retry_text 17:10)"
assert_eq       "retry at the cutoff -> still today" "Retrying at 17:00." "$(TIME=06:00; END=18:00; MIN_REMAINING_MIN=60; retry_text 17:00)"
assert_eq       "retry past midnight -> none today" "No retry today (last prewarm by 18:00)." \
                "$(TIME=06:00; END=18:00; MIN_REMAINING_MIN=0; retry_text 00:05)"
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_fail     "a clean ping clears the back-off" test -f "$FAIL_BACKOFF"

# The retry after a failure was due at its back-off time: firing on time then
# is a recovery, not "Mac was asleep" measured from the slot that failed.
section "fire: do_fire retry reads as recovered, not delayed"
if _wallclock_ok -16; then
  _reset_fire; rm -f "$RT_CALLS/osascript" "$LAST_RECOVERY"
  printf '1|%s|%s\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 960 ))" > "$FAIL_BACKOFF"
  ( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
    MODE="standard"; INTERVAL=300; TIME="$(to_hm $(( $(now_min) - 16 )))"; END="23:59"; NOTIFY="true"; do_fire tick )
  assert_contains "logs 'recovered after 1 failed'" "$(_logtail)" "recovered after 1 failed"
  assert_contains "notifies the recovery"           "$(cat "$RT_CALLS/osascript" 2>/dev/null)" "recovered"
  assert_fail     "records no sleep recovery"       test -s "$LAST_RECOVERY"
else
  _pass "retry recovered (skipped: first minutes of day)"
fi

# Late against TIME, but the previous tick ran 5 minutes ago: an open window or a
# guardrail held the fire back, so no "Mac was asleep" alert.
section "fire: do_fire late but ticks ran on -> held, not asleep"
if _wallclock_ok -45; then
  _reset_fire; rm -f "$RT_CALLS/osascript" "$LAST_RECOVERY"
  ( export STUB_CLAUDE_RC=0; PREV_TICK=$(( $(date +%s) - 300 ))
    MODE="standard"; INTERVAL=300; TIME="$(to_hm $(( $(now_min) - 45 )))"; END="23:59"; NOTIFY="delayed"; do_fire tick )
  assert_contains "logs 'held +45m'"              "$(_logtail)" "held +4"
  assert_fail     "no alert (routine notice only)" test -s "$RT_CALLS/osascript"
  assert_fail     "records no sleep recovery"     test -s "$LAST_RECOVERY"
  _reset_fire
  ( export STUB_CLAUDE_RC=0; PREV_TICK=$(( $(date +%s) - 3000 ))
    MODE="standard"; INTERVAL=300; TIME="$(to_hm $(( $(now_min) - 45 )))"; END="23:59"; NOTIFY="false"; do_fire tick )
  assert_contains "ticks stopped -> DELAYED"      "$(_logtail)" "DELAYED"
else
  _pass "held vs asleep (skipped: first hour of day)"
fi

section "fire: note_tick"
rm -f "$LAST_TICK"; note_tick
assert_eq       "no previous tick -> 0"           0 "$PREV_TICK"
assert_ok       "stamps this tick"                _is_pos_int "$(cat "$LAST_TICK")"
printf '%s' 1234 > "$LAST_TICK"; note_tick
assert_eq       "reads the previous tick"         1234 "$PREV_TICK"
printf '%s' 1234 > "$LAST_TICK"; chmod 444 "$LAST_TICK"
# the tick carries on, and a frozen stamp is not trusted (it would make every
# late fire "Mac was asleep")
assert_eq       "unwritable last_tick: carries on, previous tick unknown" "ok 0" "$( set -e; note_tick; echo "ok $PREV_TICK" )"
chmod 644 "$LAST_TICK"
PREV_TICK=0

section "fire: do_fire kills a hung ping"
_reset_fire
HP_T0=$(date +%s)
HP_OUT="$( ( export STUB_CLAUDE_HANG=4 STUB_CLAUDE_RC=0
  PING_TIMEOUT=1; MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick ) 2>&1 )"
HP_SECS=$(( $(date +%s) - HP_T0 ))
_timeout_marker() { local f; for f in "$STATE_DIR"/timeout.*; do [ -e "$f" ] && return 0; done; return 1; }
assert_contains "logs FAILED rc=124"              "$(_logtail)" "FAILED  rc=124  retry"
assert_contains "says it timed out"               "$(_logtail)" "ping timed out after 1s"
assert_fail     "no bash job notice in the log"   grep -q Terminated "$LOG"
assert_eq       "does NOT advance last_fire"      0 "$(read_lf)"
# 1s timeout; a watchdog still holding the caller's stdout would add 5s more
assert_ok       "returns promptly (watchdog lets go of stdout)" test "$HP_SECS" -le 4
assert_eq       "prints nothing to the caller"    "" "$HP_OUT"
assert_fail     "leaves no timeout marker"        _timeout_marker

section "fire: do_fire manual inside open window"
_reset_fire
RT_NOW="$(date +%s)"; printf '%s' "$RT_NOW" > "$LAST_FIRE"   # our own ping => window open now
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="false"; do_fire manual )
assert_contains "logs 'already open'"             "$(_logtail)" "already open"
assert_eq       "manual fire does not re-anchor"  "$RT_NOW" "$(read_lf)"

# ---- fire: do_codex_fire (opt-in Codex ping) -------------------------------
section "fire: do_codex_fire success"
_reset_codex
( export STUB_CODEX_RC=0 STUB_CODEX_OUT="pong"
  CODEX="true"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; CODEX_PROMPT="ping"; CODEX_MODEL=""; NOTIFY="false"; do_codex_fire tick )
assert_ok       "records a positive codex last_fire" _is_pos_int "$(read_codex_lf)"
assert_contains "logs a codex fire"                  "$(_logtail)" "codex"
assert_contains "invokes 'codex exec'"               "$(cat "$RT_CALLS/codex" 2>/dev/null)" "exec"
assert_contains "codex ping is ephemeral"            "$(cat "$RT_CALLS/codex" 2>/dev/null)" "--ephemeral"

section "fire: do_codex_fire usage-limit backoff"
_reset_codex
( export STUB_CODEX_RC=0 STUB_CODEX_OUT="Your usage limit reached; limit will reset 3pm"
  CODEX="true"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; CODEX_PROMPT="ping"; NOTIFY="false"; do_codex_fire tick )
assert_ok       "writes a positive codex limit_until" _is_pos_int "$(read_codex_limit_until)"
assert_contains "logs a CODEX LIMIT line"             "$(_logtail)" "CODEX LIMIT"

section "fire: do_codex_fire failure backs off"
_reset_codex
( export STUB_CODEX_RC=3 STUB_CODEX_OUT="boom"
  CODEX="true"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; CODEX_PROMPT="ping"; NOTIFY="false"; do_codex_fire tick )
assert_contains "logs CODEX FAILED with a retry"      "$(_logtail)" "CODEX FAILED  rc=3  retry"
assert_eq       "codex streak 1"                      1 "$(read_fail_streak "$CODEX_FAIL_BACKOFF")"
assert_eq       "does NOT advance codex last_fire"    0 "$(read_codex_lf)"

# ---- fire: cmd_tick decision core ------------------------------------------
section "fire: cmd_tick skips (mode manual)"
_reset_fire
( set_valid_config; MODE="manual"; WAKE="false"; cmd_tick )
assert_contains "logs a SKIP line"                "$(_logtail)" "SKIP"
assert_fail     "does NOT ping claude"            test -s "$RT_CALLS/claude"

# TIME=00:00/END=23:59 => 'now' is always within active hours (no wall-clock
# flake), and with no open window + no prior fire the tick must fire.
section "fire: cmd_tick fires when due"
_reset_fire
_tick_due() { export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  set_valid_config; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"
  DAYS="daily"; CALENDAR="none"; SKIP_DATES=""; LOW_BATTERY_SKIP="false"; MIN_REMAINING_MIN="0"
  WAKE="false"; CODEX="false"; NOTIFY="false"; cmd_tick; }
( _tick_due )   # subshell contains cmd_tick's exit 0; file side effects persist
assert_ok       "cmd_tick fired -> last_fire set" _is_pos_int "$(read_lf)"
assert_ok       "cmd_tick pinged claude"          test -s "$RT_CALLS/claude"
assert_contains "cmd_tick logs an ok fire"        "$(_logtail)" "ok"

# The failing tick checked at T but stamped its retry at T+2 (after
# window_anchor, across a minute boundary); the tick 15m on checks at T+900-1.
# It must retry — a tick late, and at the guardrail cutoff not at all, otherwise.
section "policy: retry_pending slack"
RP_T=$(date +%s)
printf '1|%s|%s\n' "$(( RP_T + 2 + 900 ))" "$(( RP_T + 2 ))" > "$FAIL_BACKOFF"
assert_fail     "tick 15m on (1s early, retry stamped 2s late) retries" retry_pending "$FAIL_BACKOFF" $(( RP_T + 899 ))
assert_ok       "tick 10m on still waits"         retry_pending "$FAIL_BACKOFF" $(( RP_T + 600 ))
printf '1|%s|%s\n' "$(( RP_T + 900 ))" "$RP_T" > "$FAIL_BACKOFF"
assert_ok       "61s ahead -> pending"            retry_pending "$FAIL_BACKOFF" $(( RP_T + 839 ))
assert_fail     "59s ahead -> due"                retry_pending "$FAIL_BACKOFF" $(( RP_T + 841 ))
rm -f "$FAIL_BACKOFF"
assert_fail     "no back-off file -> nothing pending" retry_pending "$FAIL_BACKOFF" "$RP_T"

# Both pings stamp their retry from the tick's start, so Codex — whose turn
# comes after Claude's ping, minutes later if that one timed out — is not
# pushed a tick late either.
section "fire: retries stamped from the tick's start"
TN=$(( $(date +%s) - 100 ))
_reset_fire
( export STUB_CLAUDE_RC=7; TICK_NOW=$TN; MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_eq       "Claude retry = tick start + 15m" $(( TN + 900 )) "$(read_fail_until "$FAIL_BACKOFF")"
_reset_codex
( export STUB_CODEX_RC=7; TICK_NOW=$TN; CODEX="true"; CODEX_PROMPT="ping"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="false"; do_codex_fire tick )
assert_eq       "Codex retry = tick start + 15m"  $(( TN + 900 )) "$(read_fail_until "$CODEX_FAIL_BACKOFF")"
# likewise Codex's cadence and a limit pause with no parsed reset time
_reset_codex
( export STUB_CODEX_RC=0; TICK_NOW=$TN; CODEX="true"; CODEX_PROMPT="ping"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="false"; do_codex_fire tick )
assert_eq       "Codex last_fire = tick start"    "$TN" "$(read_codex_lf)"
_reset_fire
( export STUB_CLAUDE_RC=1 STUB_CLAUDE_OUT="You've hit your individual spend limit"; TICK_NOW=$TN
  MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_eq       "undated limit resumes from tick start + INTERVAL" $(( TN + 18000 )) "$(read_limit_until)"
_reset_fire; _reset_codex

# A back-off file that can't be written: log the failure, but no alert — the
# stuck file would otherwise re-alert every tick.
section "fire: unwritable back-off file"
_reset_fire; rm -f "$RT_CALLS/osascript"
printf '1|%s|%s\n' "$(( $(date +%s) - 86400 ))" "$(( $(date +%s) - 87000 ))" > "$FAIL_BACKOFF"; chmod 444 "$FAIL_BACKOFF"
( export STUB_CLAUDE_RC=7; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; NOTIFY="true"; do_fire tick )
assert_contains "logs the failure"                "$(_logtail)" "FAILED  rc=7  retry ?? (state not writable)"
assert_fail     "no alert"                        test -s "$RT_CALLS/osascript"
chmod 644 "$FAIL_BACKOFF"; _reset_fire

# A 5h boundary due within the next minute is waited for (to 10s past due), not
# left to the next tick: last_fire is stamped a second or more into its tick.
section "fire: wait_for_boundary"
if [ "$(now_min)" -ge 302 ]; then
  _wfb() { ( export STUB_SLEEP=1; MODE="${2:-standard}"; INTERVAL=300; printf '%s' "$1" > "$LAST_FIRE"; wait_for_boundary ); }
  rm -f "$RT_CALLS/sleep"
  _wfb $(( $(date +%s) - 18000 + 30 ))
  WFB_S="$(cat "$RT_CALLS/sleep" 2>/dev/null)"
  assert_ok       "due in 30s -> waits to 10s past due" test "${WFB_S:-0}" -ge 38 -a "${WFB_S:-0}" -le 40
  rm -f "$RT_CALLS/sleep"; _wfb $(( $(date +%s) - 18000 + 120 ))
  assert_fail     "due in 2m -> next tick's job"  test -s "$RT_CALLS/sleep"
  _wfb $(( $(date +%s) - 18000 - 60 ))
  assert_fail     "already past due+10 -> no wait" test -s "$RT_CALLS/sleep"
  _wfb $(( $(date +%s) - 18000 + 30 )) daily
  assert_fail     "daily mode -> no wait"         test -s "$RT_CALLS/sleep"
  rm -f "$LAST_FIRE"
else
  _pass "wait_for_boundary (skipped: before 05:02)"
fi

section "fire: cmd_tick honors the failure back-off"
_reset_fire
printf '1|%s|%s\n' "$(( $(date +%s) + 600 ))" "$(date +%s)" > "$FAIL_BACKOFF"
( _tick_due )
assert_fail     "does NOT ping claude"            test -s "$RT_CALLS/claude"
assert_contains "logs the pending retry"          "$(_logtail)" "retrying failed ping at"
rm -f "$FAIL_BACKOFF"

# Due by cadence (last fire was yesterday) but your own reply 3m ago opened a
# window: no ping.
section "fire: cmd_tick declines inside an open window"
_reset_fire
printf '%s' "$(( $(date +%s) - 172800 ))" > "$LAST_FIRE"
_reply 180 > "$CLAUDE_PROJECTS/session.jsonl"
( _tick_due )
assert_fail     "does NOT ping claude"            test -s "$RT_CALLS/claude"
rm -f "$CLAUDE_PROJECTS"/*.jsonl

# Daily mode: one ping a day even once that ping's window has closed.
section "fire: cmd_tick daily mode"
if [ "$(now_min)" -ge 301 ]; then
  _tick_daily() { ( export STUB_CLAUDE_RC=0
    set_valid_config; MODE="daily"; INTERVAL=300; TIME="00:00"; END="23:59"; DAYS="daily"
    CALENDAR="none"; SKIP_DATES=""; LOW_BATTERY_SKIP="false"; MIN_REMAINING_MIN="0"
    WAKE="false"; CODEX="false"; NOTIFY="false"; cmd_tick ); }
  _reset_fire
  today_epoch 00:00 > "$LAST_FIRE"                # fired at midnight; window closed at 05:00
  _tick_daily
  assert_fail     "already fired today -> no ping" test -s "$RT_CALLS/claude"
  printf '%s' "$(( $(date +%s) - 172800 ))" > "$LAST_FIRE"   # 2 days back: another date even across DST
  _tick_daily
  assert_ok       "not yet today -> pings"        test -s "$RT_CALLS/claude"
else
  _pass "cmd_tick daily mode (skipped: before 05:01)"
fi

section "fire: cmd_tick honors the codex back-off"
_reset_fire; _reset_codex
printf '%s' "$(date +%s)" > "$LAST_FIRE"           # keep claude out of it
printf '1|%s|%s\n' "$(( $(date +%s) + 600 ))" "$(date +%s)" > "$CODEX_FAIL_BACKOFF"
( export STUB_CODEX_RC=0
  set_valid_config; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; DAYS="daily"
  CALENDAR="none"; SKIP_DATES=""; LOW_BATTERY_SKIP="false"; MIN_REMAINING_MIN="0"
  WAKE="false"; CODEX="true"; CODEX_PROMPT="ping"; NOTIFY="false"; cmd_tick )
assert_fail     "does NOT ping codex"             test -s "$RT_CALLS/codex"
assert_contains "logs the pending codex retry"    "$(_logtail)" "codex: retrying failed ping at"
_reset_codex

section "policy: record_skip_once dedupes countdowns"
_reset_fire
record_skip_once all "guardrail: only 55m left before END"
record_skip_once all "guardrail: only 50m left before END"
record_skip_once all "guardrail: battery 19%"
record_skip_once all "guardrail: battery 18%"
assert_eq       "one line per distinct reason"    2 "$(grep -c SKIP "$LOG")"
: > "$LOG"; rm -f "$LAST_SKIP"
record_skip_once all "guardrail: only 56m left before END"
record_skip_once all "guardrail: only 6m left before END"
assert_eq       "56m and 6m count as one reason"  1 "$(grep -c SKIP "$LOG")"
# Claude and Codex skips keep separate slots: alternating them logs each once.
: > "$LOG"
for _i in 1 2 3; do
  record_skip_once claude "retrying failed ping at 10:15"
  record_skip_once codex  "retrying failed ping at 10:20"
done
assert_eq       "claude/codex alternation logs once each" 2 "$(grep -c SKIP "$LOG")"
assert_contains "last skip summary shows the latest" "$(last_skip_summary)" "codex: retrying"

# A tick a minute or two before TIME (the overnight wake lands at TIME-1) must
# hold the Mac awake and wait for TIME rather than skip — but only when the
# tick at TIME would fire. sleep is stubbed.
section "fire: wait_for_time"
if _wallclock_ok 2 -1 10 20; then
  _wft() { ( export STUB_SLEEP=1; MODE="${2:-standard}"; DAYS="daily"; CALENDAR="none"; SKIP_DATES=""
             INTERVAL=300; END="${3:-23:59}"; MIN_REMAINING_MIN=0; LOW_BATTERY_SKIP="false"
             [ -n "${4:-}" ] && MIN_REMAINING_MIN="$4"
             TIME="$1"; wait_for_time ) ; }
  _reset_fire; rm -f "$RT_CALLS/sleep" "$RT_CALLS/caffeinate"
  _wft "$(to_hm $(( $(now_min) + 2 )))"
  WFT_S="$(cat "$RT_CALLS/sleep" 2>/dev/null)"
  assert_contains "logs a WAIT line"              "$(_logtail)" "WAIT"
  # TIME+1s; 2-121 rather than 62-121 in case the minute ticked over mid-test
  assert_ok       "sleeps until just past TIME"   test "${WFT_S:-0}" -ge 2 -a "${WFT_S:-0}" -le 121
  assert_ok       "holds the Mac awake meanwhile" _wait_for_call caffeinate "-w"
  rm -f "$RT_CALLS/sleep"
  _wft "$(to_hm $(( $(now_min) - 1 )))"
  assert_fail     "TIME already passed -> no wait" test -s "$RT_CALLS/sleep"
  _wft "$(to_hm $(( $(now_min) + 10 )))"
  assert_fail     "TIME 10m away -> no wait"      test -s "$RT_CALLS/sleep"
  _wft "$(to_hm $(( $(now_min) + 2 )))" standard "$(to_hm $(( $(now_min) + 20 )))" 60
  assert_fail     "guardrail day -> no wait"      test -s "$RT_CALLS/sleep"
  printf '%s' "$(( $(date +%s) + 3600 ))" > "$LIMIT_UNTIL"
  _wft "$(to_hm $(( $(now_min) + 2 )))"
  assert_fail     "limit pause -> no wait"        test -s "$RT_CALLS/sleep"
  rm -f "$LIMIT_UNTIL"
  _reply 180 > "$CLAUDE_PROJECTS/session.jsonl"
  _wft "$(to_hm $(( $(now_min) + 2 )))"
  assert_fail     "window already open -> no wait" test -s "$RT_CALLS/sleep"
  rm -f "$CLAUDE_PROJECTS"/*.jsonl
else
  _pass "wait_for_time (skipped: edge of day)"
fi

# ---- fire: cmd_keepawake ----------------------------------------------------
# dur = END - now; guard the final minute of the day where dur would be 0.
section "fire: cmd_keepawake"
rm -f "$RT_CALLS/caffeinate"
if [ "$(now_min)" -lt 1439 ]; then
  _keepawake() { set_valid_config; MODE="standard"; TIME="00:00"; END="23:59"; DAYS="daily"
    CALENDAR="none"; SKIP_DATES=""; LOW_BATTERY_SKIP="false"; MIN_REMAINING_MIN="0"; cmd_keepawake; }
  assert_ok       "keepawake execs caffeinate (exit 0)" _keepawake
  assert_contains "runs caffeinate with -t timeout"     "$(cat "$RT_CALLS/caffeinate" 2>/dev/null)" "-t"
else
  _pass "cmd_keepawake (skipped: final minute of day)"
fi

rm -rf "$RT_SANDBOX"

# ============================================================================
# summary
# ============================================================================
printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
