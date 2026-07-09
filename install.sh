#!/usr/bin/env bash
#
# install.sh — installer for the `claude-prewarm` macOS CLI.
#
# Lays down files only. It does NOT create launchd agents, touch your config,
# or run pmset/sudo. After installing, run the guided setup with:
#   claude-prewarm install
#
# Idempotent: safe to re-run. Overridable install locations via env vars:
#   BIN_DIR    (default: $HOME/.local/bin)             — where the executable goes
#   SHARE_DIR  (default: $HOME/.local/share/claude-prewarm)
#              libraries -> $SHARE_DIR/lib, assets -> $SHARE_DIR/assets,
#              notifier  -> "$SHARE_DIR/Claude Prewarm.app"
#
set -euo pipefail

# ---- usage -------------------------------------------------------------------
usage() {
  cat <<'EOF'
claude-prewarm installer

Usage: ./install.sh [-h|--help]

Installs the claude-prewarm CLI, its libraries, assets, and (best-effort) the
notifier app. Lays down files only — no launchd agents, config, or sudo.

Environment variable overrides:
  BIN_DIR     Directory for the executable   (default: $HOME/.local/bin)
  SHARE_DIR   Directory for support files    (default: $HOME/.local/share/claude-prewarm)
              Libraries go to  $SHARE_DIR/lib
              Assets go to     $SHARE_DIR/assets
              Notifier app to  "$SHARE_DIR/Claude Prewarm.app"

Examples:
  ./install.sh
  BIN_DIR=~/bin SHARE_DIR=~/opt/claude-prewarm ./install.sh

After installing, run:  claude-prewarm install
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) printf 'error: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# ---- platform guards ---------------------------------------------------------
# This tool depends on macOS-only facilities: launchd, pmset, caffeinate,
# osascript. Refuse to install anywhere else.
if [ "$(uname -s)" != "Darwin" ]; then
  printf 'error: claude-prewarm is macOS-only.\n' >&2
  printf '       It relies on launchd, pmset, caffeinate, and osascript.\n' >&2
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  printf 'error: bash was not found on PATH; it is required to run claude-prewarm.\n' >&2
  exit 1
fi

# ---- resolve this script's own directory (the repo root), following symlinks -
# So the installer works no matter where it is invoked from, even via a symlink.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  dir="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  # If the symlink target is relative, resolve it against the link's directory.
  case "$SOURCE" in /*) ;; *) SOURCE="$dir/$SOURCE" ;; esac
done
REPO_ROOT="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# ---- destinations (overridable via environment) ------------------------------
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SHARE_DIR="${SHARE_DIR:-$HOME/.local/share/claude-prewarm}"
DEFAULT_SHARE_DIR="$HOME/.local/share/claude-prewarm"
LIB_DEST="$SHARE_DIR/lib"
ASSETS_DEST="$SHARE_DIR/assets"
APP_DEST="$SHARE_DIR/Claude Prewarm.app"

# ---- sanity-check the source tree --------------------------------------------
[ -f "$REPO_ROOT/bin/claude-prewarm" ] || {
  printf 'error: cannot find bin/claude-prewarm under %s\n' "$REPO_ROOT" >&2
  exit 1
}

printf '==> Installing claude-prewarm from %s\n' "$REPO_ROOT"
printf '    bin   -> %s\n' "$BIN_DIR"
printf '    share -> %s\n' "$SHARE_DIR"

# ---- create destination dirs (idempotent) ------------------------------------
mkdir -p "$BIN_DIR" "$LIB_DEST" "$ASSETS_DEST"

# ---- a. executable -----------------------------------------------------------
printf '==> Installing executable\n'
cp "$REPO_ROOT/bin/claude-prewarm" "$BIN_DIR/claude-prewarm"
chmod 755 "$BIN_DIR/claude-prewarm"

# ---- b. libraries ------------------------------------------------------------
printf '==> Installing libraries\n'
cp "$REPO_ROOT"/lib/*.bash "$LIB_DEST/"

# ---- c. assets ---------------------------------------------------------------
printf '==> Installing assets\n'
cp "$REPO_ROOT"/assets/* "$ASSETS_DEST/"

# ---- d. notifier app (best-effort, non-fatal) --------------------------------
# osacompile builds a tiny AppleScript applet so notifications carry the
# claude-prewarm icon. If it is unavailable or the build fails, the CLI falls
# back to a generic osascript notification — so we warn and continue.
printf '==> Building notifier app\n'
NOTIFIER_OK=0
if command -v osacompile >/dev/null 2>&1; then
  # Remove any prior build so osacompile starts clean (idempotency).
  rm -rf "$APP_DEST"
  if osacompile -o "$APP_DEST" "$REPO_ROOT/notifier/notifier.applescript" 2>/dev/null; then
    # Overlay the claude-prewarm icon, if we shipped one.
    if [ -f "$REPO_ROOT/assets/logo.icns" ]; then
      cp "$REPO_ROOT/assets/logo.icns" "$APP_DEST/Contents/Resources/applet.icns" 2>/dev/null || true
    fi
    # osacompile ships an Assets.car whose icon (CFBundleIconName=applet)
    # overrides applet.icns — remove both so the custom icon wins.
    rm -f "$APP_DEST/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP_DEST/Contents/Info.plist" 2>/dev/null || true
    # Stable identity: notification permission is keyed to the bundle ID, so
    # it must not change across reinstalls.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.claude-prewarm.notifier" "$APP_DEST/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude Prewarm" "$APP_DEST/Contents/Info.plist" 2>/dev/null || true
    # The edits above break osacompile's signature seal; re-sign (ad-hoc) or
    # macOS silently refuses to present the app's notifications.
    codesign -f -s - "$APP_DEST" 2>/dev/null || true
    # Touch the bundle so Finder / Notification Center refresh the icon cache.
    touch "$APP_DEST" 2>/dev/null || true
    NOTIFIER_OK=1
  fi
fi
if [ "$NOTIFIER_OK" -eq 1 ]; then
  printf '    Built "%s"\n' "$APP_DEST"
else
  printf 'warning: could not build the notifier app; notifications will use the\n' >&2
  printf '         generic system icon. This is non-fatal — install continues.\n' >&2
fi

# ---- post-install notes ------------------------------------------------------
printf '==> Done.\n'

# PATH setup: if BIN_DIR is not on the current PATH, add it to the user's
# shell profile so the install is one-and-done. Idempotent: skipped when the
# profile already exports it (e.g. from a previous run).
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    # Prefer a $HOME-relative line so the profile stays portable.
    case "$BIN_DIR" in
      "$HOME"/*) path_line='export PATH="$HOME/'"${BIN_DIR#"$HOME"/}"':$PATH"' ;;
      *)         path_line='export PATH="'"$BIN_DIR"':$PATH"' ;;
    esac
    # Pick the profile for the user's login shell. Only bash and zsh are
    # configured automatically — other shells (fish, tcsh, ...) don't source
    # these files or use this syntax, so guessing would silently do nothing.
    prof=""
    case "${SHELL:-/bin/zsh}" in
      */bash) prof="$HOME/.bash_profile" ;;
      */zsh)  prof="${ZDOTDIR:-$HOME}/.zshrc" ;;
    esac
    if [ -z "$prof" ]; then
      printf '\n'
      printf 'NOTE: %s is not on your PATH, and your login shell (%s)\n' "$BIN_DIR" "${SHELL:-unknown}" >&2
      printf '      is not one this installer configures automatically. Add the\n' >&2
      printf '      equivalent of this to your shell startup file:\n' >&2
      printf '        %s\n' "$path_line" >&2
      printf '      (fish: fish_add_path %s)\n' "$BIN_DIR" >&2
    elif [ -f "$prof" ] && grep -qxF "$path_line" "$prof" 2>/dev/null; then
      : # already configured; takes effect in new shells
    elif { printf '\n# Added by claude-prewarm install.sh\n%s\n' "$path_line" >>"$prof"; } 2>/dev/null; then
      printf '\n'
      printf '==> Added %s to PATH in %s\n' "$BIN_DIR" "$prof"
      printf '    Takes effect in new shells; for this one, run:\n'
      printf '      %s\n' "$path_line"
    else
      printf '\n'
      printf 'NOTE: %s is not on your PATH and %s could not be updated.\n' "$BIN_DIR" "$prof" >&2
      printf '      Add this line to your shell profile and restart your shell:\n' >&2
      printf '        %s\n' "$path_line" >&2
    fi
    ;;
esac

# If SHARE_DIR was overridden away from the default, the CLI and its launchd
# agent must be told where the libraries live.
if [ "$SHARE_DIR" != "$DEFAULT_SHARE_DIR" ]; then
  printf '\n'
  printf 'NOTE: You installed to a non-default location. Export this so the CLI\n'
  printf '      (and its launchd agent) can find the libraries:\n'
  printf '        export CLAUDE_PREWARM_LIB_DIR="%s"\n' "$LIB_DEST"
fi

# Next steps.
printf '\n'
printf 'Next steps:\n'
printf '  claude-prewarm install          # guided interactive setup\n'
printf '  claude-prewarm install-default --time 05:00 --end 17:00   # non-interactive\n'
printf '  claude-prewarm --help           # all commands\n'
