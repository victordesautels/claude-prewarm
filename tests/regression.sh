#!/usr/bin/env bash
# ============================================================================
# claude-prewarm — notification + CLI-routing regression tests
#
#   ./tests/regression.sh
#
# Guards the bugs found while building the custom notification logo:
#   - applet argv is NOT forwarded on direct exec → title/message must travel
#     via CP_TITLE/CP_MESSAGE env vars
#   - `system attribute` returns raw bytes → UTF-8 mojibake (must use
#     `do shell script` to read env)
#   - notify() must never return nonzero (callers run under set -e)
#   - notifier_setup must be first-run-only (marker file) and NOTIFY-gated
#   - `install` = guided wizard, `install-default`/flags = non-interactive
#   - bundle: stable CFBundleIdentifier, no Assets.car/CFBundleIconName
#     (they override the custom icns), valid signature after plist edits
#   - icon must be full-bleed (transparent margins → macOS 26 adds a
#     backing-plate "border")
#
# Logic and routing tests run against THIS repo's bin/ and lib/ inside a
# sandbox $HOME with a stub applet and stub osascript — no real notifications
# are posted, and the user's config/state/launchd agents are never touched.
# Bundle checks run against the installed app (skipped if not installed).
# ============================================================================
set -u

SELF="${BASH_SOURCE[0]}"
TESTS_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB="$ROOT/lib"
BIN="$ROOT/bin/claude-prewarm"
APP="${CLAUDE_PREWARM_APP:-$HOME/.local/share/claude-prewarm/Claude Prewarm.app}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf 'skip - %s (%s)\n' "$1" "$2"; }

sandbox() {  # fresh sandbox HOME with a stub applet that records its env + argv
  SB="$(mktemp -d)"
  mkdir -p "$SB/.local/share/claude-prewarm/Claude Prewarm.app/Contents/MacOS" \
           "$SB/.local/state/claude-prewarm" "$SB/bin"
  cat > "$SB/.local/share/claude-prewarm/Claude Prewarm.app/Contents/MacOS/applet" <<EOF
#!/bin/bash
printf '%s|%s\n' "\${CP_TITLE:-}" "\${CP_MESSAGE:-}" >> "$SB/applet.log"
if [ \$# -gt 0 ]; then printf '%s\n' "\$@" >> "$SB/applet.argv.log"; fi
exit 0
EOF
  chmod +x "$SB/.local/share/claude-prewarm/Claude Prewarm.app/Contents/MacOS/applet"
  cat > "$SB/bin/osascript" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SB/osascript.log"
EOF
  # stub sqlite3: "app not registered with Notification Center" by default
  printf '#!/bin/bash\nexit 1\n' > "$SB/bin/sqlite3"
  chmod +x "$SB/bin/osascript" "$SB/bin/sqlite3"
}

# run_notify <NOTIFY value> <shell snippet>
# Sources the repo libs inside the sandbox under set -euo pipefail (same
# strictness as the production entrypoint).
run_notify() {
  local mode="$1"; shift
  HOME="$SB" PATH="$SB/bin:$PATH" bash -c "
    set -euo pipefail
    NOTIFY='$mode'
    STATE_DIR=\"\$HOME/.local/state/claude-prewarm\"
    SHARE_DIR=\"\$HOME/.local/share/claude-prewarm\"
    source '$LIB/ui.bash'
    source '$LIB/launchd.bash'
    $*
  " 2>&1
}

# ---- notify(): delivery mechanics ---------------------------------------------

sandbox
run_notify true 'notify routine "T1" "M1"' >/dev/null
if grep -q '^T1|M1$' "$SB/applet.log" 2>/dev/null; then
  ok "notify passes title/message to applet via CP_TITLE/CP_MESSAGE env"
else
  fail "notify passes title/message to applet via CP_TITLE/CP_MESSAGE env" "applet.log: $(cat "$SB/applet.log" 2>/dev/null)"
fi
if [ ! -f "$SB/applet.argv.log" ]; then
  ok "notify does not rely on argv (direct exec drops applet argv)"
else
  fail "notify does not rely on argv (direct exec drops applet argv)" "argv.log: $(cat "$SB/applet.argv.log")"
fi
if [ ! -f "$SB/osascript.log" ]; then
  ok "osascript fallback not used when applet present"
else
  fail "osascript fallback not used when applet present" "$(cat "$SB/osascript.log")"
fi
rm -rf "$SB"

sandbox
run_notify true 'notify routine "Tú" "em — dash · dot … ellipsis"' >/dev/null
if grep -q 'em — dash · dot … ellipsis' "$SB/applet.log" 2>/dev/null; then
  ok "UTF-8 message survives the env handoff intact"
else
  fail "UTF-8 message survives the env handoff intact" "applet.log: $(cat "$SB/applet.log" 2>/dev/null)"
fi
rm -rf "$SB"

sandbox
rm -rf "$SB/.local/share/claude-prewarm/Claude Prewarm.app"
run_notify true 'notify routine "T2" "M2"' >/dev/null
if grep -q 'display notification' "$SB/osascript.log" 2>/dev/null && grep -q 'M2' "$SB/osascript.log"; then
  ok "notify falls back to osascript when applet is missing"
else
  fail "notify falls back to osascript when applet is missing" "osascript.log: $(cat "$SB/osascript.log" 2>/dev/null)"
fi
rm -rf "$SB"

# ---- notify(): gating + set -e safety ------------------------------------------

sandbox
run_notify false 'notify routine "T" "M"; notify alert "T" "M"' >/dev/null
if [ ! -f "$SB/applet.log" ] && [ ! -f "$SB/osascript.log" ]; then
  ok "NOTIFY=false suppresses everything"
else
  fail "NOTIFY=false suppresses everything"
fi
rm -rf "$SB"

sandbox
run_notify delayed 'notify routine "quiet" "M"; notify alert "loud" "M"' >/dev/null
if ! grep -q 'quiet' "$SB/applet.log" 2>/dev/null && grep -q '^loud|M$' "$SB/applet.log" 2>/dev/null; then
  ok "NOTIFY=delayed drops routine, delivers alert"
else
  fail "NOTIFY=delayed drops routine, delivers alert" "applet.log: $(cat "$SB/applet.log" 2>/dev/null)"
fi
rm -rf "$SB"

sandbox
# applet AND osascript both fail: notify must still return 0 under set -e
printf '#!/bin/bash\nexit 1\n' > "$SB/.local/share/claude-prewarm/Claude Prewarm.app/Contents/MacOS/applet"
printf '#!/bin/bash\nexit 1\n' > "$SB/bin/osascript"
chmod +x "$SB/.local/share/claude-prewarm/Claude Prewarm.app/Contents/MacOS/applet" "$SB/bin/osascript"
out="$(run_notify true 'notify routine "T" "M"; echo SURVIVED')"
if printf '%s' "$out" | grep -q 'SURVIVED'; then
  ok "notify never trips set -e even when applet and osascript both fail"
else
  fail "notify never trips set -e even when applet and osascript both fail" "$out"
fi
rm -rf "$SB"

# ---- notifier_setup(): first-run marker ----------------------------------------

sandbox
run_notify true 'notifier_setup; notifier_setup' >/dev/null
n="$(grep -c 'Notifications are working' "$SB/applet.log" 2>/dev/null || echo 0)"
if [ "$n" = 1 ] && [ -f "$SB/.local/state/claude-prewarm/notifier_intro" ]; then
  ok "notifier_setup fires exactly once and leaves the marker"
else
  fail "notifier_setup fires exactly once and leaves the marker" "fired $n times"
fi
rm -rf "$SB"

sandbox
run_notify false 'notifier_setup' >/dev/null
if [ ! -f "$SB/applet.log" ] && [ ! -f "$SB/.local/state/claude-prewarm/notifier_intro" ]; then
  ok "notifier_setup is a no-op when NOTIFY=false (no marker either)"
else
  fail "notifier_setup is a no-op when NOTIFY=false (no marker either)"
fi
rm -rf "$SB"

sandbox
rm -rf "$SB/.local/share/claude-prewarm/Claude Prewarm.app"
out="$(run_notify true 'notifier_setup; echo SURVIVED')"
if printf '%s' "$out" | grep -q 'SURVIVED' && [ ! -f "$SB/.local/state/claude-prewarm/notifier_intro" ]; then
  ok "notifier_setup skips cleanly when applet is absent"
else
  fail "notifier_setup skips cleanly when applet is absent" "$out"
fi
rm -rf "$SB"

sandbox
# app already registered with Notification Center (reinstall / post-purge):
# no intro notification, but the marker is still written
printf '#!/bin/bash\necho 1\n' > "$SB/bin/sqlite3"; chmod +x "$SB/bin/sqlite3"
run_notify true 'notifier_setup' >/dev/null
if [ ! -f "$SB/applet.log" ] && [ -f "$SB/.local/state/claude-prewarm/notifier_intro" ]; then
  ok "notifier_setup skips the intro when the app is already registered"
else
  fail "notifier_setup skips the intro when the app is already registered" "applet.log: $(cat "$SB/applet.log" 2>/dev/null)"
fi
rm -rf "$SB"

sandbox
# sqlite3 missing entirely (defensive): must degrade to firing the intro
rm "$SB/bin/sqlite3"
out="$(run_notify true 'notifier_setup; echo SURVIVED')"
if printf '%s' "$out" | grep -q 'SURVIVED' && grep -q 'Notifications are working' "$SB/applet.log" 2>/dev/null; then
  ok "notifier_setup still fires when the registration check is unavailable"
else
  fail "notifier_setup still fires when the registration check is unavailable" "$out"
fi
rm -rf "$SB"

# ---- CLI dispatch: install / install-default / aliases --------------------------

# cli <args...> — repo bin + repo libs, sandbox HOME, no tty stdin.
cli() {
  HOME="$SB" CLAUDE_PREWARM_LIB_DIR="$LIB" NO_COLOR=1 bash "$BIN" "$@" </dev/null 2>&1
}

sandbox
if cli install | grep -q 'guided install needs an interactive terminal'; then
  ok "install (no args) routes to the guided wizard"
else
  fail "install (no args) routes to the guided wizard" "$(cli install | head -2)"
fi
if cli setup | grep -q 'guided install needs an interactive terminal'; then
  ok "setup remains a compat alias for the wizard"
else
  fail "setup remains a compat alias for the wizard"
fi
if cli install --no-color | grep -q 'guided install needs an interactive terminal'; then
  ok "install --no-color still routes to the wizard (global flag stripped first)"
else
  fail "install --no-color still routes to the wizard (global flag stripped first)"
fi
if cli install --bogus-flag | grep -q 'unknown flag: --bogus-flag'; then
  ok "install <flags> routes to the non-interactive path"
else
  fail "install <flags> routes to the non-interactive path"
fi
if cli install-default --bogus-flag | grep -q 'unknown flag: --bogus-flag'; then
  ok "install-default routes to the non-interactive path"
else
  fail "install-default routes to the non-interactive path"
fi
if cli --help | grep -q 'install-default \[flags\]'; then
  ok "help documents install-default"
else
  fail "help documents install-default"
fi
# First-run gate is TTY-guarded: a bare, non-interactive invocation (no config
# in the sandbox HOME) must fall through to help, never prompt for setup.
if cli | grep -q 'install-default \[flags\]'; then
  ok "bare invocation falls back to help when non-interactive"
else
  fail "bare invocation falls back to help when non-interactive" "$(cli | head -3)"
fi
if cli | grep -q 'Start guided setup now'; then
  fail "bare invocation must not prompt for setup without a TTY"
else
  ok "bare invocation does not prompt for setup without a TTY"
fi
cli config test-notify >/dev/null
if grep -q 'Test notification' "$SB/applet.log" 2>/dev/null; then
  ok "config test-notify sends through the applet even with default config"
else
  fail "config test-notify sends through the applet even with default config" "applet.log: $(cat "$SB/applet.log" 2>/dev/null)"
fi
rm -rf "$SB"

# ---- tick end to end: the real entrypoint under set -euo pipefail -------------
# tests/run.sh sources the libs without errexit; this drives bin/claude-prewarm
# itself, where a failing `a && b` or a pipefail slip aborts the tick. Every
# tick's exit status is asserted, so an abort fails the check rather than
# skipping it. Stubs keep the real claude/codex/caffeinate/pmset/launchctl out;
# CLAUDE_CONFIG_DIR is dropped so no real session logs are read. A stub fails
# while $SB/<name>.fail exists.

sandbox
CFG="$SB/.config/claude-prewarm/config"; ST="$SB/.local/state/claude-prewarm"
mkdir -p "$SB/.config/claude-prewarm" "$SB/.claude/projects/p"
conf() {  # $1 = TIME  $2 = END  $3 = MIN_REMAINING_MIN  $4 = CODEX
  # WORKSTART=00:00: the default 09:00 would fail "END after WORKSTART" for an
  # END computed from the clock before 09:00
  printf 'TIME=%s\nWORKSTART=00:00\nEND=%s\nDAYS=daily\nMODE=standard\nMIN_REMAINING_MIN=%s\nWAKE=false\nLOW_BATTERY_SKIP=false\nCALENDAR=none\nCODEX=%s\nCODEX_PROMPT=ping\n' \
    "$1" "$2" "$3" "$4" > "$CFG"
}
for t in claude codex; do
  cat > "$SB/bin/$t" <<EOF
#!/bin/bash
echo x >> "$SB/$t.calls"
[ -f "$SB/$t.fail" ] && { echo "Failed to authenticate"; exit 1; }
echo pong
EOF
done
# sleep stays real (the ping watchdog uses it) unless STUB_SLEEP is set
printf '#!/bin/bash\n[ -n "${STUB_SLEEP:-}" ] && { echo "$*" >> "%s/sleep.calls"; exit 0; }\nexec /bin/sleep "$@"\n' "$SB" > "$SB/bin/sleep"
for t in caffeinate pmset; do printf '#!/bin/bash\nexit 0\n' > "$SB/bin/$t"; done
printf '#!/bin/bash\nexit 1\n' > "$SB/bin/launchctl"
chmod +x "$SB/bin/"*
run_cli() { env -u CLAUDE_CONFIG_DIR HOME="$SB" PATH="$SB/bin:$PATH" CLAUDE_PREWARM_LIB_DIR="$LIB" bash "$BIN" "$@" </dev/null 2>&1; }
calls() { cat "$SB/$1.calls" 2>/dev/null | wc -l | tr -d ' '; }
last() { tail -n1 "$ST/prewarm.log" 2>/dev/null; }
nm() { echo $(( 10#$(date +%H) * 60 + 10#$(date +%M) )); }
hm() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
reply() {  # an API reply $1 seconds ago in the sandbox session logs
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus"}}\n' \
    "$(date -u -r "$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%S.000Z')" > "$SB/.claude/projects/p/s.jsonl"
}
# expect NAME PATTERN [STUB COUNT]: one tick must exit 0, its last log line must
# contain PATTERN, and (if given) STUB must have been called COUNT times in all
expect() {
  local rc=0
  run_cli tick >/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && case "$(last)" in *"$2"*) true;; *) false;; esac \
     && { [ -z "${3:-}" ] || [ "$(calls "$3")" = "$4" ]; }; then
    ok "e2e: $1"
  else
    fail "e2e: $1" "rc=$rc ${3:+$3 calls=$(calls "$3")} last: $(last)"
  fi
}

conf 00:00 23:59 0 false
expect "first tick fires"                  "ok  anchor" claude 1
expect "cadence not due -> no second ping" "ok  anchor" claude 1
# due by cadence (last fire two days ago), but your own reply 3m ago opened a
# window. forget() drops every trace of our earlier pings: last_fire,
# fire_history, and the log's ok lines (merged into the window replay).
forget() { printf '%s' "$(( $(date +%s) - 172800 ))" > "$ST/last_fire"; : > "$ST/fire_history"; : > "$ST/prewarm.log"; }
forget; reply 180
expect "open window (session log) -> no ping" "" claude 1
rm -f "$SB/.claude/projects/p/s.jsonl"; : > "$SB/claude.fail"
expect "failure backs off"                 "FAILED  rc=1  retry" claude 2
grep -q 'FAILED' "$SB/applet.log" 2>/dev/null && ok "e2e: first failure notifies" || fail "e2e: first failure notifies"
expect "back-off -> no retry yet"          "SKIP    claude: retrying failed ping" claude 2
claude_json() { local j; j="$(run_cli status --json)"; j="${j#*\"claude\":\{}"; printf '%s' "${j%%\}*}"; }
case "$(claude_json)" in
  *'"retry_at":'[0-9]*) ok "e2e: status --json shows claude's pending retry";;
  *) fail "e2e: status --json shows claude's pending retry" "$(claude_json)";;
esac
rm -f "$SB/claude.fail"
if [ "$(nm)" -ge 2 ]; then   # now-60 must still be today
  now=$(date +%s); printf '1|%s|%s\n' "$(( now - 60 ))" "$(( now - 960 ))" > "$ST/fail_backoff"
  expect "retry reads as recovered"        "recovered after 1 failed"
  case "$(claude_json)" in
    *'"retry_at":null'*) ok "e2e: status --json clears claude's retry";;
    *) fail "e2e: status --json clears claude's retry" "$(claude_json)";;
  esac
else
  skip "e2e: retry reads as recovered" "first minutes of the day"
fi

forget; rm -f "$ST/fail_backoff" "$SB/claude.calls"
printf '%s' "$(( $(date +%s) + 3600 ))" > "$ST/limit_until"
expect "limit pause -> skip"               "SKIP    claude: usage limit until" claude 0
rm -f "$ST/limit_until"
if [ "$(nm)" -lt 1400 ]; then
  conf 00:00 "$(hm $(( $(nm) + 30 )))" 60 false
  expect "guardrail -> skip"               "SKIP    all: guardrail" claude 0
else
  skip "e2e: guardrail -> skip" "too close to midnight"
fi

conf 00:00 23:59 0 true
printf '%s' "$(date +%s)" > "$ST/last_fire"                   # claude not due
expect "codex fires"                       "ok  codex anchor" codex 1
rm -f "$ST/codex_last_fire"; : > "$SB/codex.fail"
expect "codex failure backs off"           "CODEX FAILED  rc=1  retry" codex 2
expect "codex back-off -> skip"            "SKIP    codex: retrying failed ping" codex 2
rm -f "$SB/codex.fail" "$ST/codex_fail_backoff"

# a tick two minutes before TIME waits for it (sleep stubbed), then — still
# before TIME by the real clock — skips as outside active hours
if [ "$(nm)" -ge 1 ] && [ "$(nm)" -lt 1430 ]; then
  conf "$(hm $(( $(nm) + 2 )))" 23:59 0 false
  forget; rm -f "$SB/sleep.calls"
  export STUB_SLEEP=1
  expect "wait_for_time path runs clean"   "SKIP    all: outside active hours"
  unset STUB_SLEEP
  grep -q 'WAIT ' "$ST/prewarm.log" && [ -s "$SB/sleep.calls" ] \
    && ok "e2e: waited for TIME" || fail "e2e: waited for TIME" "$(tail -n3 "$ST/prewarm.log")"
else
  skip "e2e: wait_for_time path" "too close to midnight"
fi
rm -rf "$SB"

# ---- notifier source: env-first, UTF-8-safe ------------------------------------

src="$ROOT/notifier/notifier.applescript"
# strip AppleScript comment lines so doc comments can mention the anti-pattern
code="$(grep -v '^[[:space:]]*--' "$src")"
if printf '%s' "$code" | grep -q 'CP_MESSAGE' && printf '%s' "$code" | grep -q 'printf'; then
  ok "notifier source reads env vars via do shell script"
else
  fail "notifier source reads env vars via do shell script"
fi
if ! printf '%s' "$code" | grep -q 'system attribute'; then
  ok "notifier source avoids system attribute (mojibake regression)"
else
  fail "notifier source avoids system attribute (mojibake regression)"
fi
if [ "$(printf '%s' "$code" | grep -c 'end try')" -ge 3 ]; then
  ok "title and message reads have independent try blocks"
else
  fail "title and message reads have independent try blocks"
fi

# ---- installed notifier bundle (skipped when not installed) ---------------------

if [ -d "$APP" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" = "com.claude-prewarm.notifier" ] \
    && ok "bundle has stable identifier com.claude-prewarm.notifier" \
    || fail "bundle has stable identifier com.claude-prewarm.notifier"
  if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist" >/dev/null 2>&1 \
     && [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
    ok "no CFBundleIconName / Assets.car (would override the custom icns)"
  else
    fail "no CFBundleIconName / Assets.car (would override the custom icns)"
  fi
  [ -f "$APP/Contents/Resources/applet.icns" ] \
    && ok "custom applet.icns present" || fail "custom applet.icns present"
  codesign -v "$APP" 2>/dev/null \
    && ok "bundle signature is valid" || fail "bundle signature is valid"
else
  skip "installed bundle checks" "no app at $APP — run install.sh first"
fi

# ---- icon: full-bleed (no macOS backing-plate border) ---------------------------

if [ -f "$ROOT/assets/logo.icns" ]; then
  tmp="$(mktemp -d)"
  if iconutil -c iconset "$ROOT/assets/logo.icns" -o "$tmp/i.iconset" 2>/dev/null; then
    big="$(ls "$tmp/i.iconset"/*512x512@2x* "$tmp/i.iconset"/*512x512* 2>/dev/null | head -1)"
    if [ -n "$big" ] && python3 - "$big" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
w, h = im.size
corners = [(0,0), (w-1,0), (0,h-1), (w-1,h-1)]
sys.exit(0 if all(im.getpixel(c)[3] >= 250 for c in corners) else 1)
EOF
    then ok "icon is full-bleed (opaque corners — no macOS backing-plate border)"
    else fail "icon is full-bleed (opaque corners — no macOS backing-plate border)"
    fi
  else
    fail "icon is full-bleed (opaque corners — no macOS backing-plate border)" "iconutil failed"
  fi
  rm -rf "$tmp"
else
  skip "icon full-bleed check" "no assets/logo.icns in repo"
fi

# ---- shell syntax ---------------------------------------------------------------

for f in "$BIN" "$LIB"/*.bash "$ROOT/install.sh"; do
  bash -n "$f" 2>/dev/null && ok "syntax: ${f##*/}" || fail "syntax: ${f##*/}"
done

echo
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
