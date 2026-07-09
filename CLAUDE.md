# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claude-prewarm` is a macOS-only bash tool that keeps Claude's 5-hour usage
windows aligned to the workday. Claude's window is anchored to your *first*
message and only re-opens after it expires; this tool fires a tiny headless
`claude -p` ping so windows tile back-to-back with no wasted hours. Everything
runs under system bash 3.2 and depends only on macOS built-ins (`launchd`,
`pmset`, `caffeinate`, `osascript`, BSD `date`) — keep new code bash-3.2-compatible
and dependency-free.

## Commands

```bash
bash tests/run.sh                     # full test suite (~2s, 137 assertions)
./scripts/lint.sh                     # bash -n + shellcheck + dead-code check
git config core.hooksPath .githooks   # one-time: enable the pre-commit gate
```

There is no build step — the tool ships as source. `install.sh` copies
`bin/`, `lib/`, and `notifier/` into `~/.local/bin` and
`~/.local/share/claude-prewarm`.

### Running a single test

`tests/run.sh` is a single dependency-free harness (no `bats`), not per-file
tests. It defines `assert_eq` / `assert_ok` / `assert_fail` / `assert_contains`
and runs every assertion top to bottom. To isolate one area, comment out
unrelated blocks or grep the run output — there is no test selector flag.

### Pre-commit gate

The `.githooks/pre-commit` hook (once `core.hooksPath` is set) runs
`scripts/lint.sh` then `tests/run.sh` whenever a shell file is staged. Bypass in
an emergency with `git commit --no-verify`. `shellcheck` is optional (`brew
install shellcheck`); it's skipped with a warning if absent.

## Architecture

The runtime is a thin dispatcher plus sourced libraries. `bin/claude-prewarm`
sets `set -euo pipefail`, defines all global paths/defaults, sources every
`lib/*.bash` **in dependency order** (`ui` → `time_state` → `policy` →
`launchd` → `fire` → `commands`), then routes `$1` to a `cmd_*` function via a
static `case`. Because libs are sourced into one shell, globals and functions
cross file boundaries freely — this is why `.shellcheckrc` disables SC2034
(unused-variable false positives) and why `lint.sh` has its own dead-code check
for unreferenced *functions* instead.

| Library               | Responsibility                                        |
|-----------------------|-------------------------------------------------------|
| `lib/ui.bash`         | Colors, help tables, interactive prompts, `die`       |
| `lib/time_state.bash` | Time/JSON helpers, state readers, window detection    |
| `lib/policy.bash`     | Validators, holiday calendars, guardrails, scheduling |
| `lib/launchd.bash`    | launchd agents, pmset wake, notifications             |
| `lib/fire.bash`       | The Claude/Codex ping + the `tick` decision           |
| `lib/commands.bash`   | `cmd_*` subcommands and help text                      |

### The self-healing tick (the core idea)

A single `launchd` agent runs `claude-prewarm tick` every 5 minutes
(`TICK_SECONDS=300`). Each tick **decides** whether to fire based on how long
ago the *last* fire was — read from `last_fire` in the state dir — not a fixed
wall-clock table. So the next window always opens one tick after the current one
expires, even if a fire landed hours late (Mac asleep). A tick, in order:
validate config → check skip conditions (outside active hours, wrong day,
holiday/skip-date, too little time before `END`, low battery) → back off if a
usage limit was hit (reset time parsed from the limit message into
`limit_until`) → fire only if no window is currently open **and** the mode's
cadence says one is due. `fire.bash` holds this decision logic; understand it
before touching firing behavior.

### Three independent times

`TIME` (earliest a prewarm may fire), `WORKSTART` (when `caffeinate` starts
keeping the Mac awake so midday fires land on time), and `END` (last cutoff +
caffeinate off). Modes (`aggressive`/`coverage`/`conserve`/`manual`) map to the
legacy `KEEPALIVE` boolean for backward compat — see the mapping in both
`bin/claude-prewarm` and `policy.bash`.

### State and config (never hardcode these paths — use the globals)

- Config: `~/.config/claude-prewarm/config` (sourced shell assignments).
- State: `~/.local/state/claude-prewarm/` — `last_fire`, `limit_until`,
  `codex_last_fire`, `wake_set`, `last_skip`, `last_recovery`, logs.
- Claude session logs it reads to detect an already-open window:
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`.

### Privilege boundary

The only action needing admin is the optional overnight `pmset` wake, and it
prompts once during `install`. The tool never runs `sudo` silently. `caffeinate`
(via the `keepawake` command / `.awake` agent) needs no sudo.

## Testing approach

`tests/run.sh` sources the libs and exercises them in two layers: **pure logic**
(time/JSON helpers, validators, weekday/holiday math, limit parsing, config
validation, schedule computation) and a **runtime layer** where `fire.bash` and
`launchd.bash` run against stub `claude`/`codex`/`launchctl`/`pmset`/`sudo`/
`caffeinate`/`osascript` binaries and a sandbox state dir. Result: plist
generation, the tick fire/skip decision, delayed recovery, Codex ping,
usage-limit back-off, and pmset wake logic are all covered without touching the
real system. When adding runtime behavior, add a stub rather than calling a real
binary. Note `run.sh` deliberately omits `set -u` because lib functions read
globals set per-test.

## Conventions

- Bash 3.2 only — no associative arrays, no `${var^^}`, no `mapfile`.
- Codex support (`codex exec`) is an opt-in keep-warm ping on the same cadence;
  Codex has no documented Claude-style window, so don't assume window semantics.
- Adding a subcommand: add the `cmd_*` function in `commands.bash` and a literal
  `case` arm in `bin/claude-prewarm` (dispatch is static — the dead-code check
  relies on that).
