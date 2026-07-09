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
CLAUDE_PROJECTS="$RT_SANDBOX/claude_projects"; mkdir -p "$CLAUDE_PROJECTS"  # empty => no open window
PLIST="$RT_SANDBOX/agent.plist"
AWAKE_PLIST="$RT_SANDBOX/awake.plist"
LABEL="com.claude-prewarm.test"
AWAKE_LABEL="com.claude-prewarm.test.awake"
SELF="$STUB_BIN/claude-prewarm"
TICK_SECONDS=300; GRACE_MIN=8

_mkstub() {  # $1=name  $2=body (single-quoted; $RT_* expand at stub runtime, not now)
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; } > "$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}
_mkstub claude     'echo "$@" >> "$RT_CALLS/claude"; printf "%s" "${STUB_CLAUDE_OUT:-pong}"; exit "${STUB_CLAUDE_RC:-0}"'
_mkstub codex      'echo "$@" >> "$RT_CALLS/codex";  printf "%s" "${STUB_CODEX_OUT:-pong}";  exit "${STUB_CODEX_RC:-0}"'
_mkstub caffeinate 'echo "$@" >> "$RT_CALLS/caffeinate"; exit 0'
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
_reset_fire() { : > "$LOG"; rm -f "$LAST_FIRE" "$LIMIT_UNTIL" "$LAST_SKIP" "$RT_CALLS/claude"; rm -rf "$STATE_DIR/fire.lock"; }
_reset_codex(){ : > "$LOG"; rm -f "$CODEX_LAST_FIRE" "$CODEX_LIMIT_UNTIL" "$RT_CALLS/codex"; rm -rf "$STATE_DIR/codex.fire.lock"; }

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
# minute of the day, so the target is always tomorrow's wake.
section "policy: check_wake_ac warns on battery"
rm -f "$WAKE_AC_WARNED" "$RT_CALLS/pmset"; : > "$LOG"; : > "$WAKE_MARK"
( export STUB_PMSET_BATT="Now drawing from 'Battery Power'; -InternalBattery-0 15%; discharging;"
  WAKE="true"; MODE="standard"; DAYS="daily"; CALENDAR="none"; SKIP_DATES=""
  TIME="00:00"; END="00:01"; NOTIFY="false"; check_wake_ac )
assert_contains "logs a plug-in warning"          "$(cat "$LOG")" "needs AC power"
assert_ok       "records the warned target date"  test -s "$WAKE_AC_WARNED"

# ---- time_state: window_anchor from session logs ---------------------------
section "time_state: window_anchor"
rm -f "$LAST_FIRE" "$CLAUDE_PROJECTS"/*.jsonl
assert_eq "no logs + no last-fire -> anchor 0"     0 "$(INTERVAL=300; window_anchor)"
RECENT_ISO="$(date -u -v-3M '+%Y-%m-%dT%H:%M:%S.000Z')"
printf '{"timestamp":"%s","type":"user"}\n' "$RECENT_ISO" > "$CLAUDE_PROJECTS/session.jsonl"
assert_ok "recent session -> window open (anchor>0)" _is_pos_int "$(INTERVAL=300; window_anchor)"
OLD_ISO="$(date -u -v-6H '+%Y-%m-%dT%H:%M:%S.000Z')"
printf '{"timestamp":"%s","type":"user"}\n' "$OLD_ISO" > "$CLAUDE_PROJECTS/session.jsonl"
assert_eq "6h-old session (5h window) -> closed"   0 "$(INTERVAL=300; window_anchor)"
rm -f "$CLAUDE_PROJECTS"/*.jsonl

# ---- fire: do_fire outcomes -------------------------------------------------
section "fire: do_fire success"
_reset_fire
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; PROMPT="ping"; MODEL=""; NOTIFY="false"; CODEX="false"; do_fire tick )
assert_ok       "records a positive last_fire"    _is_pos_int "$(read_lf)"
assert_contains "logs an ok anchor fire"          "$(_logtail)" "ok  anchor"
assert_contains "invokes claude with -p"          "$(cat "$RT_CALLS/claude" 2>/dev/null)" "-p"

# A boundary fire that's overdue (Mac was asleep) must log DELAYED and record
# recovery. Seed last-fire 1h ago; with INTERVAL=5 the boundary was due ~55m ago.
section "fire: do_fire delayed recovery"
_reset_fire; rm -f "$LAST_RECOVERY"
printf '%s' "$(( $(date +%s) - 3600 ))" > "$LAST_FIRE"
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="pong"
  MODE="standard"; INTERVAL=5; TIME="00:00"; END="23:59"; PROMPT="ping"; MODEL=""; NOTIFY="false"; CODEX="false"; do_fire tick )
assert_contains "logs a DELAYED fire"             "$(_logtail)" "DELAYED due="
assert_ok       "writes recovery state"           test -s "$LAST_RECOVERY"

section "fire: do_fire usage-limit backoff"
_reset_fire
( export STUB_CLAUDE_RC=0 STUB_CLAUDE_OUT="Your usage limit reached; limit will reset 3pm"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_ok       "writes a positive limit_until"   _is_pos_int "$(read_limit_until)"
assert_contains "logs a LIMIT line"               "$(_logtail)" "LIMIT"
assert_eq       "does NOT advance last_fire"      0 "$(read_lf)"

section "fire: do_fire failure"
_reset_fire
( export STUB_CLAUDE_RC=7 STUB_CLAUDE_OUT="boom"
  MODE="standard"; INTERVAL=300; TIME="$(date +%H:%M)"; END="23:59"; NOTIFY="false"; do_fire tick )
assert_contains "logs a FAILED line with rc"      "$(_logtail)" "FAILED  rc=7"
assert_eq       "does NOT advance last_fire"      0 "$(read_lf)"

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

section "fire: do_codex_fire usage-limit backoff"
_reset_codex
( export STUB_CODEX_RC=0 STUB_CODEX_OUT="Your usage limit reached; limit will reset 3pm"
  CODEX="true"; MODE="standard"; INTERVAL=300; TIME="00:00"; END="23:59"; CODEX_PROMPT="ping"; NOTIFY="false"; do_codex_fire tick )
assert_ok       "writes a positive codex limit_until" _is_pos_int "$(read_codex_limit_until)"
assert_contains "logs a CODEX LIMIT line"             "$(_logtail)" "CODEX LIMIT"

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
