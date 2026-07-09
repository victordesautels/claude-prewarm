#!/usr/bin/env bash
#
# build-notifier.sh — build the "Claude Prewarm.app" notifier applet.
#
# Usage: build-notifier.sh SRC_DIR OUT_APP
#   SRC_DIR   repo root containing notifier/notifier.applescript and assets/
#   OUT_APP   destination bundle path, e.g. "$SHARE_DIR/Claude Prewarm.app"
#
# osacompile builds a tiny AppleScript applet so notifications carry the
# claude-prewarm icon. Shared by install.sh and the Homebrew formula so both
# produce a byte-for-byte identical, ad-hoc-signed bundle. Exits non-zero (so
# callers can treat the notifier as best-effort) when osacompile is unavailable
# or the build fails; the CLI then falls back to a generic osascript notification.
set -euo pipefail

SRC="${1:?usage: build-notifier.sh SRC_DIR OUT_APP}"
OUT="${2:?usage: build-notifier.sh SRC_DIR OUT_APP}"

command -v osacompile >/dev/null 2>&1 || {
  printf 'build-notifier: osacompile not found\n' >&2
  exit 1
}
[ -f "$SRC/notifier/notifier.applescript" ] || {
  printf 'build-notifier: missing %s\n' "$SRC/notifier/notifier.applescript" >&2
  exit 1
}

# Remove any prior build so osacompile starts clean (idempotency).
rm -rf "$OUT"
osacompile -o "$OUT" "$SRC/notifier/notifier.applescript"

# Overlay the claude-prewarm icon, if we shipped one.
if [ -f "$SRC/assets/logo.icns" ]; then
  cp "$SRC/assets/logo.icns" "$OUT/Contents/Resources/applet.icns" 2>/dev/null || true
fi
# osacompile ships an Assets.car whose icon (CFBundleIconName=applet) overrides
# applet.icns — remove both so the custom icon wins.
rm -f "$OUT/Contents/Resources/Assets.car"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$OUT/Contents/Info.plist" 2>/dev/null || true
# Stable identity: notification permission is keyed to the bundle ID, so it must
# not change across reinstalls.
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.claude-prewarm.notifier" "$OUT/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude Prewarm" "$OUT/Contents/Info.plist" 2>/dev/null || true
# The edits above break osacompile's signature seal; re-sign (ad-hoc) or macOS
# silently refuses to present the app's notifications.
codesign -f -s - "$OUT" 2>/dev/null || true
# Touch the bundle so Finder / Notification Center refresh the icon cache.
touch "$OUT" 2>/dev/null || true
