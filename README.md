# claude-prewarm

Keep Claude's 5-hour usage windows aligned to your workday.

Claude's 5-hour usage window is anchored to your **first** message and only
re-opens when you send a message *after* it expires. If you step away, the
window drifts off your schedule and you "waste" hours you could have used.
`claude-prewarm` fires a tiny headless `claude -p` ping so windows tile
back-to-back and stay lined up with the hours you actually work.

- **Self-healing schedule.** A single `launchd` agent ticks every 5 minutes and
  decides whether to fire based on how long ago the *last* fire was — not a
  fixed wall-clock table. The next window always opens one tick after the
  current one expires, even if a fire happened hours late because the Mac was
  asleep. No drift, no gaps, and a mid-day install starts prewarming
  immediately.
- **Reads your real usage.** It inspects Claude Code's local session logs to
  detect a window that's already open (from your own work *or* a previous ping)
  and skips redundant pings.
- **Stays out of the way.** Backs off on usage limits, skips holidays/PTO,
  skips on low battery or when too little of the workday remains, and notifies
  you when a fire lands late because the Mac was asleep.
- **Optional Codex ping.** Can run a separate `codex exec` keep-warm ping on the
  same cadence (opt-in; Codex does not document Claude-style 5-hour windows).

> **macOS only.** Depends on `launchd`, `pmset`, `caffeinate`, `osascript`, and
> BSD `date`. Runs under the system bash 3.2.

## Install

```bash
git clone <this-repo> claude-prewarm
cd claude-prewarm
./install.sh
```

`install.sh` lays down the files only — the executable at `~/.local/bin`, the
libraries and notifier app under `~/.local/share/claude-prewarm`. It does not
create any schedule or run `sudo`. If `~/.local/bin` is not on your `PATH`, the
installer tells you the line to add.

Then configure the schedule:

```bash
claude-prewarm install          # guided, interactive setup
# — or non-interactive —
claude-prewarm install-default --time 05:00 --end 17:00
```

## Usage

```
claude-prewarm install                 Interactive guided install (first run).
claude-prewarm install-default [flags] Non-interactive install with defaults/flags.
claude-prewarm uninstall [-y] [--purge] Remove agents + wake schedule; --purge also
                                        deletes the binary, libs, app, config, and logs.
claude-prewarm now                     Fire one prewarm ping immediately.
claude-prewarm status [--json]         Show state, schedule, guardrails, active window.
claude-prewarm config ...              get | set KEY VALUE | edit | path | test-notify.
claude-prewarm logs [-f|N]             Recent fires (follow with -f, or last N lines).
claude-prewarm --help                  Full help, all flags, examples.
claude-prewarm --version               Print the version.
```

### Modes

| Mode         | Behavior                                             |
|--------------|------------------------------------------------------|
| `aggressive` | Tile Claude windows back-to-back during active hours |
| `coverage`   | One ping every 6 hours while active                  |
| `conserve`   | A single prewarm per day                             |
| `manual`     | No scheduled pings (fire only with `now`)            |

### Common examples

```bash
claude-prewarm install-default --time 05:00 --workstart 09:00 --end 17:00 --stay-awake
claude-prewarm install-default --mode coverage --calendar us
claude-prewarm config set END 18:30
claude-prewarm config set SKIP_DATES 2026-11-27,2026-12-24
claude-prewarm config set CODEX true
claude-prewarm status --json
```

## How it works

A `launchd` agent runs `claude-prewarm tick` every 5 minutes. Each tick:

1. Validates the on-disk config; bad config logs why and does not fire.
2. Checks skip conditions — outside active hours, not a scheduled day, holiday
   or custom skip date, too little time left before `END`, or low battery.
3. Backs off if a usage limit was hit (parses the reset time from the limit
   message and pauses until then).
4. Fires a `claude -p` ping only if no window is currently open **and** the
   cadence for the selected mode says one is due.

An optional companion agent runs `caffeinate` from `WORKSTART` to `END` (no
sudo) so midday fires land on time. An optional overnight `pmset` wake (the only
privileged action — prompts for admin once during install) wakes the Mac before
the morning anchor. Notifications distinguish an on-time fire from one that
fired late because the Mac had been asleep.

State lives in `~/.local/state/claude-prewarm/` (last-fire timestamps, limit
back-off, logs); config in `~/.config/claude-prewarm/config`.

## Uninstall

```bash
claude-prewarm uninstall            # remove agents + wake schedule; keep config/logs
claude-prewarm uninstall --purge    # also delete the binary, libs, app, config, logs
```

## Development

The runtime is a thin `bin/claude-prewarm` dispatcher plus libraries under
`lib/` (all bash 3.2-compatible):

| File                  | Responsibility                                        |
|-----------------------|-------------------------------------------------------|
| `lib/ui.bash`         | Colors, help tables, interactive prompts, `die`       |
| `lib/time_state.bash` | Time/JSON helpers, state readers, window detection    |
| `lib/policy.bash`     | Validators, holiday calendars, guardrails, scheduling |
| `lib/launchd.bash`    | launchd agents, pmset wake, notifications             |
| `lib/fire.bash`       | The actual Claude/Codex ping + the `tick` decision    |
| `lib/commands.bash`   | Subcommands and help text                             |

### Lint & pre-commit hook

```bash
git config core.hooksPath .githooks   # one-time, after cloning
./scripts/lint.sh                     # run the checks manually
```

The pre-commit hook runs `scripts/lint.sh` — syntax check (`bash -n`),
[shellcheck](https://www.shellcheck.net) (`brew install shellcheck`; skipped
with a warning if absent), and a dead-code check for functions that are never
called — then the full test suite (~2s). Bypass with `git commit --no-verify`.

### Tests

```bash
bash tests/run.sh
```

A dependency-free bash harness (no `bats` required), 137 assertions in two parts:

- **Pure logic** — time/JSON helpers, validators, weekday parsing, holiday math,
  usage-limit message parsing, config validation, schedule computation.
- **Runtime layer** — `fire.bash` and `launchd.bash` exercised against stub
  `claude` / `codex` / `launchctl` / `pmset` / `sudo` / `caffeinate` /
  `osascript` binaries and a sandbox state dir, so plist generation, the `tick`
  fire/skip decision, delayed self-healing recovery, the Codex ping, usage-limit
  back-off, notification gating, `window_anchor`, and the pmset wake logic are
  all covered without touching the real system (no real pings, agents, wakes, or
  notifications).

## License

[MIT](LICENSE)
