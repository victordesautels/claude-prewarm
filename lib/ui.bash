# ---- styling: color only on a TTY, unless opted out --------------------------
# Honors NO_COLOR (no-color.org), CLICOLOR=0, TERM=dumb, and --no-color. Auto-off
# when stdout is piped or redirected (e.g. the launchd log), so files stay clean.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${CLICOLOR:-1}" != "0" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  COLOR=1; else COLOR=0; fi
_sgr()   { if [ "$COLOR" = 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
bold()   { _sgr '1'  "$*"; }
dim()    { _sgr '2'  "$*"; }
red()    { _sgr '31' "$*"; }
green()  { _sgr '32' "$*"; }
yellow() { _sgr '33' "$*"; }
cyan()   { _sgr '36' "$*"; }
S_OK="✓"; S_NO="✗"; S_WARN="⚠"; S_DOT="●"; S_RING="○"
row() { printf '  %s  %s\n' "$(dim "$(printf '%-9s' "$1")")" "$2"; }   # aligned "label  value"

# Terminal width for responsive help: $COLUMNS override → tput (TTY) → 80; clamped.
term_cols() {
  local c="${COLUMNS:-}"
  [ -z "$c" ] && [ -t 1 ] && c="$(tput cols 2>/dev/null || true)"
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  [ "$c" -lt 40 ] && c=40; [ "$c" -gt 120 ] && c=120
  echo "$c"
}
# Two-column table row: key in the left gutter (width $KEYW), description wrapped
# to $WRAP and hang-indented under itself. Set KEYW/WRAP before calling.
trow() {
  local key="$1" desc="$2" first=1 line pad
  pad="$(printf '%-*s' "$KEYW" '')"
  printf '%s\n' "$desc" | fold -s -w "$WRAP" | while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      printf '  %s  %s\n' "$(cyan "$(printf '%-*s' "$KEYW" "$key")")" "$line"; first=0
    else
      printf '  %s  %s\n' "$pad" "$line"
    fi
  done
}

# ---- interactive prompts (used only by the `setup` wizard, TTY-only) ---------
# Free-text prompt with a default; prompt goes to stderr, the value to stdout.
ask_text() {   # $1=prompt  $2=default
  local prompt="$1" def="$2" ans=""
  printf '%s %s %s ' "$(cyan '?')" "$(bold "$prompt")" "$(dim "[$def]")" >&2
  IFS= read -r ans || ans=""
  [ -z "$ans" ] && ans="$def"
  printf '%s' "$ans"
}
# Yes/No prompt honoring a default; returns 0 for yes, 1 for no.
ask_yesno() {   # $1=prompt  $2=default(y|n)
  local prompt="$1" def="${2:-y}" ans="" hint
  [ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
  printf '%s %s %s ' "$(cyan '?')" "$(bold "$prompt")" "$(dim "$hint")" >&2
  IFS= read -r ans || ans=""
  [ -z "$ans" ] && ans="$def"
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
# Arrow-key single-select menu. Sets REPLY_IDX (-1 = cancelled) and REPLY_VAL.
REPLY_IDX=0; REPLY_VAL=""
menu_select() {   # $1=prompt  $2=default index  rest=options
  local prompt="$1" sel="$2"; shift 2
  local opts=("$@") n=${#opts[@]} key r1 r2 j cancel=0 stty_saved=""
  printf '%s %s\n' "$(cyan '?')" "$(bold "$prompt")"
  printf '%s\n' "$(dim '  ↑/↓ move · enter select · esc cancel')"
  _menu_draw() {
    for j in "${!opts[@]}"; do
      printf '\033[K'
      if [ "$j" -eq "$sel" ]; then printf '  %s %s\n' "$(cyan '▸')" "$(bold "${opts[$j]}")"
      else printf '    %s\n' "${opts[$j]}"; fi
    done
  }
  _menu_draw
  # NOTE: cmd_setup runs $(...) command substitutions before this menu, which leaves
  # SIGINT hard-ignored in the parent (bash quirk) — so a trap on INT can never fire.
  # Instead disable ISIG so Ctrl-C arrives as byte 0x03 that we handle as cancel below.
  # A TERM/HUP trap and the unconditional restore after the loop guarantee the terminal
  # is put back even if we're killed mid-menu.
  stty_saved="$(stty -g 2>/dev/null || true)"
  if [ -n "$stty_saved" ]; then
    trap 'stty '"$stty_saved"' 2>/dev/null; printf "\033[%dA\033[J" "'"$(( n+2 ))"'"; exit 130' TERM HUP
    stty -isig 2>/dev/null || true
  fi
  while true; do
    IFS= read -rsn1 key || { cancel=1; break; }
    case "$key" in
      $'\033') r1=""; r2=""
               IFS= read -rsn1 -t 1 r1 2>/dev/null || true
               if [ "$r1" = '[' ]; then                       # CSI arrow sequence
                 IFS= read -rsn1 -t 1 r2 2>/dev/null || true
                 case "$r2" in A) sel=$(( (sel-1+n)%n ));; B) sel=$(( (sel+1)%n ));; esac
               else cancel=1; break; fi;;                     # bare ESC → cancel
      k|K)         sel=$(( (sel-1+n)%n ));;
      j|J)         sel=$(( (sel+1)%n ));;
      q|Q|$'\003') cancel=1; break;;                          # q or Ctrl-C → cancel
      '')          break;;                                    # enter → select
    esac
    printf '\033[%dA' "$n"; _menu_draw
  done
  # ALWAYS restore the terminal, on every exit path
  [ -n "$stty_saved" ] && { stty "$stty_saved" 2>/dev/null || true; trap - TERM HUP; }
  printf '\033[%dA\033[J' "$(( n+2 ))"   # collapse the menu to one line
  if [ "$cancel" = 1 ]; then REPLY_IDX=-1; REPLY_VAL=""; return 1; fi
  REPLY_IDX=$sel; REPLY_VAL="${opts[$sel]}"
  printf '  %s %s %s\n' "$(green "$S_OK")" "$(dim "$prompt")" "$(bold "$REPLY_VAL")"
  return 0
}

die() {   # $1 = message, $2 = optional fix hint
  printf '%s %s\n' "$(red "error:")" "$1" >&2
  [ -n "${2:-}" ] && printf '  %s %s\n' "$(dim "hint:")" "$2" >&2
  exit 2
}
