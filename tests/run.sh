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
assert_eq "coverage -> 360"           360 "$(MODE=coverage;   mode_interval_min)"
assert_eq "aggressive INTERVAL=300"   300 "$(MODE=aggressive; INTERVAL=300; mode_interval_min)"
assert_eq "conserve INTERVAL=250"     250 "$(MODE=conserve;   INTERVAL=250; mode_interval_min)"

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
  TIME="09:00"; WORKSTART="08:00"; END="17:00"; MODE="aggressive"; CALENDAR="none"
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
assert_eq "aggressive 09:00-17:00 @300m" "$(printf '09:00\n14:00')" \
          "$(MODE=aggressive; TIME=09:00; END=17:00; INTERVAL=300; fire_times)"
assert_eq "aggressive first line 09:00" "09:00" \
          "$(MODE=aggressive; TIME=09:00; END=17:00; INTERVAL=300; fire_times | head -1)"
assert_eq "conserve -> single time"      "09:00" \
          "$(MODE=conserve; TIME=09:00; END=17:00; INTERVAL=300; fire_times)"

# ============================================================================
# summary
# ============================================================================
printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
