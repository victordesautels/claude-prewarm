uid() { id -u; }

reload() {  # $1 = label, $2 = plist
  local u; u=$(uid)
  launchctl bootout "gui/$u/$1" 2>/dev/null || launchctl unload "$2" 2>/dev/null || true
  launchctl bootstrap "gui/$u" "$2" 2>/dev/null || launchctl load -w "$2" 2>/dev/null || true
  launchctl enable "gui/$u/$1" 2>/dev/null || true
}

unload_agent() {  # $1 = label, $2 = plist
  local u; u=$(uid)
  launchctl bootout "gui/$u/$1" 2>/dev/null || launchctl unload "$2" 2>/dev/null || true
}

agent_loaded() {  # $1 = label
  local u; u=$(uid)
  launchctl print "gui/$u/$1" >/dev/null 2>&1 || launchctl list 2>/dev/null | grep -q "$1"
}

# Main agent: tick every TICK_SECONDS. RunAtLoad makes it check immediately on
# install, so a mid-day install starts prewarming right away.
gen_plist() {
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$LABEL</string>"
    echo '  <key>ProgramArguments</key>'
    echo "  <array><string>$SELF</string><string>tick</string></array>"
    echo "  <key>StartInterval</key><integer>$TICK_SECONDS</integer>"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>ProcessType</key><string>Background</string>'
    echo '  <key>EnvironmentVariables</key>'
    echo '  <dict>'
    echo "    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
    # Forward the install location so the background tick finds its libraries and
    # notifier app wherever the tool was installed (e.g. a Homebrew Cellar prefix).
    [ -n "${CLAUDE_PREWARM_LIB_DIR:-}" ]   && echo "    <key>CLAUDE_PREWARM_LIB_DIR</key><string>$CLAUDE_PREWARM_LIB_DIR</string>"
    [ -n "${CLAUDE_PREWARM_SHARE_DIR:-}" ] && echo "    <key>CLAUDE_PREWARM_SHARE_DIR</key><string>$CLAUDE_PREWARM_SHARE_DIR</string>"
    # so the launchd tick reads the same session logs as your interactive Claude Code
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && echo "    <key>CLAUDE_CONFIG_DIR</key><string>$CLAUDE_CONFIG_DIR</string>"
    echo '  </dict>'
    echo "  <key>StandardOutPath</key><string>$LOG</string>"
    echo "  <key>StandardErrorPath</key><string>$LOG</string>"
    echo '</dict></plist>'
  } > "$PLIST"
}

# Companion agent: at WORKSTART, run our `keepawake` (NO sudo). It computes the
# time left until END and runs caffeinate for exactly that long, so it ALWAYS
# switches off at end of day — even if it started late after the Mac woke.
gen_awake_plist() {
  local hm h m d
  hm="$WORKSTART"; h=${hm%%:*}; m=${hm##*:}
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$AWAKE_LABEL</string>"
    echo '  <key>ProgramArguments</key>'
    echo "  <array><string>$SELF</string><string>keepawake</string></array>"
    # keepawake sources the same libraries, so forward the install location too.
    echo '  <key>EnvironmentVariables</key>'
    echo '  <dict>'
    echo "    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
    [ -n "${CLAUDE_PREWARM_LIB_DIR:-}" ]   && echo "    <key>CLAUDE_PREWARM_LIB_DIR</key><string>$CLAUDE_PREWARM_LIB_DIR</string>"
    [ -n "${CLAUDE_PREWARM_SHARE_DIR:-}" ] && echo "    <key>CLAUDE_PREWARM_SHARE_DIR</key><string>$CLAUDE_PREWARM_SHARE_DIR</string>"
    echo '  </dict>'
    echo '  <key>StartCalendarInterval</key><array>'
    for d in $(weekday_nums); do
      echo "    <dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>$((10#$h))</integer><key>Minute</key><integer>$((10#$m))</integer></dict>"
    done
    echo '  </array>'
    echo "  <key>StandardOutPath</key><string>$LOG</string>"
    echo "  <key>StandardErrorPath</key><string>$LOG</string>"
    echo '</dict></plist>'
  } > "$AWAKE_PLIST"
}

apply_agents() {
  gen_plist; reload "$LABEL" "$PLIST"
  if [ "$STAYAWAKE" = "true" ]; then gen_awake_plist; reload "$AWAKE_LABEL" "$AWAKE_PLIST"
  else unload_agent "$AWAKE_LABEL" "$AWAKE_PLIST"; rm -f "$AWAKE_PLIST"; fi
}

# ---- pmset wake (the only privileged action) ---------------------------------
set_wake() {   # interactive sudo; records a marker so uninstall can clean up
  local wt; wt="$(to_hm $(( ( $(to_min "$TIME") - 1 + 1440 ) % 1440 )))"":00"
  printf '%s\n' "$(dim "  scheduling overnight wake at $wt ($(pmset_days)) — admin needed…")"
  if sudo pmset repeat wakeorpoweron "$(pmset_days)" "$wt"; then
    printf '%s %s\n' "$(pmset_days)" "$wt" > "$WAKE_MARK"
    printf '%s %s\n' "$(green "$S_OK")" "Overnight wake set: $wt on $(pmset_days)."
  else
    printf '%s %s\n' "$(yellow "$S_WARN")" "Wake not set — run: sudo pmset repeat wakeorpoweron $(pmset_days) $wt"
  fi
}

clear_wake() {   # only if WE set it. `pmset repeat cancel` clears the whole
                 # repeat schedule, so we only run it when our marker is present.
  [ -f "$WAKE_MARK" ] || return 0
  printf '%s\n' "$(dim '  clearing overnight wake schedule — admin needed…')"
  if sudo pmset repeat cancel; then rm -f "$WAKE_MARK"; printf '%s %s\n' "$(green "$S_OK")" "Overnight wake schedule cleared."
  else printf '%s %s\n' "$(yellow "$S_WARN")" "Could not clear wake — run: sudo pmset repeat cancel"; fi
}

reconcile_wake() {
  if [ "$MODE" = "manual" ]; then clear_wake
  elif [ "$WAKE" = "true" ]; then set_wake
  else clear_wake; fi
}

# ---- notifications -----------------------------------------------------------
# NOTE: $2/$3 go into an AppleScript string. Only call with fixed-template text
# plus safe numeric/time values — never user PROMPT or model output.
notify() {  # $1 = routine|alert   $2 = title   $3 = message
  case "$NOTIFY" in
    true)    : ;;
    delayed) [ "$1" = "alert" ] || return 0 ;;
    *)       return 0 ;;
  esac
  # Prefer the bundled notifier applet so notifications carry the claude-prewarm
  # icon; a bare osascript notification always shows the Script Editor icon.
  local notifier="$SHARE_DIR/Claude Prewarm.app/Contents/MacOS/applet"
  if [ -x "$notifier" ]; then
    # env vars, not argv: exec'ing an applet binary directly does not forward
    # CLI arguments to the script's `on run argv`.
    CP_TITLE="$2" CP_MESSAGE="$3" "$notifier" >/dev/null 2>&1 && return 0
  fi
  osascript -e "display notification \"$3\" with title \"$2\"" >/dev/null 2>&1 || true
}

# True if Notification Center already knows the notifier app — i.e. the
# permission prompt was answered in some previous install. Best-effort: any
# read failure counts as "not registered" so a genuine first run still prompts.
notifier_registered() {
  sqlite3 "$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db" \
    "select 1 from app where identifier='com.claude-prewarm.notifier' limit 1;" 2>/dev/null | grep -q 1
}

# First-run notification permission. macOS delivers the permission request AS a
# notification card, so it is easy to miss (and Do Not Disturb swallows it
# silently). Fire a test from setup and walk the user through granting it.
# Runs once (marker file), and not at all when a previous install already
# registered the app. Re-test anytime with: claude-prewarm config test-notify
notifier_setup() {
  [ "$NOTIFY" = "false" ] && return 0
  local applet="$SHARE_DIR/Claude Prewarm.app/Contents/MacOS/applet"
  [ -x "$applet" ] || return 0
  local mark="$STATE_DIR/notifier_intro"
  [ -f "$mark" ] && return 0
  touch "$mark"
  notifier_registered && return 0
  CP_TITLE="Claude prewarm" CP_MESSAGE="Notifications are working." "$applet" >/dev/null 2>&1 || true
  echo
  printf '%s\n' "A test notification was just sent."
  printf '  %s\n' "$(dim "· If macOS asked to allow notifications, click Allow.")"
  printf '  %s\n' "$(dim "· If nothing appeared, enable it under System Settings → Notifications → Claude Prewarm,")"
  printf '  %s\n' "$(dim "  then verify with: claude-prewarm config test-notify")"
}
