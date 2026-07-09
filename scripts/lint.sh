#!/usr/bin/env bash
# ============================================================================
# lint.sh — repo-wide static checks for claude-prewarm. Run from anywhere:
#
#   ./scripts/lint.sh
#
# Checks, in order:
#   1. syntax     bash -n on every tracked shell file (the bash "typecheck")
#   2. shellcheck lint per .shellcheckrc (skipped with a warning if missing)
#   3. dead code  functions defined but never referenced anywhere else
#
# Exits non-zero if any check fails. Pure bash 3.2 + git + grep, matching the
# project's dependency-free ethos; shellcheck is the one optional extra
# (brew install shellcheck).
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; FAIL=1; }

# ---- tracked shell files (by extension or bash shebang) ----------------------
SHELL_FILES=""
while IFS= read -r f; do
  case "$f" in
    *.sh|*.bash) SHELL_FILES="$SHELL_FILES $f"; continue ;;
    assets/*|*.png|*.icns|*.svg|*.md) continue ;;
  esac
  if [ -f "$f" ] && head -n1 "$f" 2>/dev/null | grep -q '^#!.*bash'; then
    SHELL_FILES="$SHELL_FILES $f"
  fi
done < <(git ls-files)
# shellcheck disable=SC2086  # intentional word-splitting; no tracked shell file has spaces
set -- $SHELL_FILES
[ $# -gt 0 ] || { bad "no shell files found"; exit 1; }

# ---- 1. syntax (bash -n) ------------------------------------------------------
for f in "$@"; do
  if ! err=$(bash -n "$f" 2>&1); then
    bad "syntax: $f"$'\n'"$err"
  fi
done
[ "$FAIL" = 0 ] && note "ok: syntax ($# files)"

# ---- 2. shellcheck ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$@"; then
    note "ok: shellcheck"
  else
    bad "shellcheck reported issues (see above)"
  fi
else
  note "warn: shellcheck not installed — skipping lint (brew install shellcheck)"
fi

# ---- 3. dead code: functions never referenced outside their definition --------
# Finds `name() {` definitions, then looks for `name` on any other line of any
# shell file. Dispatch in bin/claude-prewarm is static (literal case arms), so
# a name with zero references really is dead. Recursion-only or comment-only
# mentions count as uses — rare enough not to matter here.
DEAD=""
while IFS= read -r name; do
  uses=$(grep -hE "\b${name}\b" "$@" | grep -cvE "^[[:space:]]*(function[[:space:]]+)?${name}\(\)")
  if [ "$uses" -eq 0 ]; then
    DEAD="$DEAD $name"
  fi
done < <(grep -hE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' "$@" \
           | sed -E 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)\(\).*/\2/' | sort -u)
if [ -n "$DEAD" ]; then
  bad "dead code — functions defined but never called:$DEAD"
else
  note "ok: dead code"
fi

exit "$FAIL"
