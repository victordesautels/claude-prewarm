# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.6-beta] — 2026-10-20

### Fixed
- Upgrading from 0.5.2 no longer misplaces the current window. 0.5.2 pings left
  neither a session log nor `fire_history`. Until that file exists, the day's
  successful pings are now read back from `prewarm.log`.
- A 0.5.3 failure back-off file (`streak|retry`) now derives its failure time
  as one back-off before the retry. A failure just before midnight no longer
  carries its streak into the next day.
- A failure alert now says "No retry today" when the retry falls past the
  last possible prewarm: `END` minus `MIN_REMAINING_MIN`, not `END` itself.
- The end-to-end guardrail test no longer fails before 08:31; it sets
  `WORKSTART` explicitly. The `status --json` checks now read Claude's
  `retry_at`, not either agent's.

## [0.5.5-beta] — 2026-10-20

### Fixed
- A ping that fails instantly (e.g. `claude` missing) no longer leaves bash's
  "Terminated: 15" notice in the log or on the terminal. The timeout watchdog
  is now reaped before its marker is read, and it stops its own sleeps with
  KILL, so a cancelled watchdog never leaves a stray `sleep` running.
- A failed `now` no longer sets the schedule's retry back-off. It could push
  the next scheduled ping up to 15 minutes late. A failure alert whose retry
  falls after `END` says "No retry today" instead of a time that never comes.
- A late ping says "Mac was asleep" only if the ticks actually stopped. One
  held back by an open window or a guardrail, while ticks kept running, is
  logged as `held` with a routine notice. Each tick stamps `last_tick` for
  this.
- Upgrading from 0.5.3 mid-failure-streak continues the streak instead of
  restarting it with a fresh alert.
- The end-to-end tests assert every tick's exit status, so an errexit abort
  fails them instead of skipping the check. They now also cover window
  detection, the pre-`TIME` wait, Codex, and the skip paths. They stub
  `launchctl` and ignore `CLAUDE_CONFIG_DIR`.

## [0.5.4-beta] — 2026-10-20

### Fixed
- A ping that works on retry after a failure is logged and notified as
  "recovered after N failed". It used to read as "Mac was asleep", because
  lateness was measured from the slot that failed, not the retry time.
- "codex binary not found" backs off like any other failure. It used to alert
  on every tick.
- A killed ping no longer writes bash's "Terminated: 15" job notice into the
  log, and `now` returns as soon as the timeout fires instead of 5 seconds
  later. A timeout is now flagged by the watchdog itself, so a ping that fails
  on its own after the Mac slept through it is not mislabelled as a timeout.
- A usage-limit reset time lands on the minute (it kept the current seconds,
  so the resume could slip a tick), and "resets 6am" on the night of a DST
  change resolves to 06:00, not 05:00 or 07:00.
- The wait before `TIME` only happens when the tick at `TIME` would fire. It
  no longer holds the Mac awake on a guardrail or low-battery day, during a
  limit pause or failure back-off, after a daily ping, or inside an
  already-open window. It also sleeps one second past `TIME`.
- The failure streak restarts on the first failure of a new day, keyed on the
  failure itself. A late-evening failure's retry crossing midnight no longer
  carries the streak over and suppresses the next day's alert.
- Claude and Codex skips are deduped separately, so both backing off at once
  logs each reason once instead of on every tick.
- `status --json` reports `retry_at` as `null` once the retry time has passed.

## [0.5.3-beta] — 2026-10-20

### Fixed
- A failed ping no longer retries and alerts on every 5-minute tick. It backs
  off 15 minutes, then 30, then hourly, and only the first failure of the day
  notifies. A clean ping clears the back-off. Until 0.5.2 a failed ping's
  session log hid this by blocking retries for five hours.
- Claude Code's "You've hit your … limit" messages (session, weekly, and spend
  limits) are now recognized as usage limits. Prewarms pause until the reset
  time instead of logging FAILED.
- The morning anchor no longer misses the overnight wake. The `pmset` wake
  lands a minute before `TIME`, and macOS was back asleep within 15–87 seconds,
  before the tick could fire. A tick in the last 5 minutes before `TIME` now
  holds the Mac awake (`caffeinate`) and waits for `TIME`. Every ping also
  holds the Mac awake until it finishes.
- Open-window detection reads every model reply in the last day of session
  logs, not just each log's first line. A resumed session, or one that runs
  across a window boundary, now registers the window it opens. Our own pings
  are kept in `fire_history`, since they no longer leave a session log.
- A hung ping is killed after 3 minutes. launchd does not start a new tick
  while one is still running, so a hung ping stopped all prewarms.
- Countdown skips ("only 55m left before END", a draining battery %) log once
  a day instead of on every tick.

## [0.5.2-beta] — 2026-10-20

### Changed
- The Claude ping runs with `--no-session-persistence`, so it no longer leaves a
  session log in `~/.claude/projects` (or clutters `claude --resume`). Window
  detection is unaffected: our own pings are tracked via `last_fire`.

## [0.4.2-beta] — 2026-07-09

### Added
- First-run onboarding: running a bare `claude-prewarm` in an interactive
  terminal with no saved config now offers to start the guided setup
  (`Start guided setup now? [Y/n]`) instead of printing help. TTY-guarded, so
  scripts and non-interactive callers still fall through to help, and it only
  nudges until a config exists.

### Changed
- The guided setup (`claude-prewarm install`) now opens with a colored welcome
  banner and a short orientation message (what it does, that nothing is applied
  until you confirm, and how to cancel). The banner rule is built with `sed`
  rather than a shell loop to sidestep a bash 3.2 multibyte-concatenation bug
  that corrupted repeated box-drawing characters.
- `claude-prewarm status` output is restyled: a framed header with a rule under
  it and the fields grouped under section headings (Schedule, Ping, Guardrails,
  Activity) for readability. The `status --json` output is unchanged.

## [0.4.1-beta] — 2026-07-09

Make the tool relocatable so it can be installed from a package manager
(Homebrew tap) rather than only a `git clone` + `install.sh`.

### Added
- `CLAUDE_PREWARM_SHARE_DIR` env override for the support-file root (libs,
  assets, notifier app), alongside the existing `CLAUDE_PREWARM_LIB_DIR`.
- `scripts/build-notifier.sh` — the notifier-app build, extracted from
  `install.sh` so `install.sh` and the Homebrew formula build an identical
  bundle.

### Fixed
- The generated launchd agents now forward `CLAUDE_PREWARM_LIB_DIR` /
  `CLAUDE_PREWARM_SHARE_DIR` into their environment, so the background `tick`
  (and `keepawake`) resolve their libraries and notifier app when installed
  outside the default `~/.local/share` location. Previously a non-default
  install location broke the background agents.

## [0.4.0-beta] — 2026-07-09

First release with a real source tree and packaging. The runtime is unchanged
except for the uninstall improvement below.

### Added
- `install.sh` — an idempotent installer that lays down the binary, libraries,
  assets, and the compiled notifier app into the standard locations. macOS-only
  guard; no `sudo`, no schedule created (that stays with `claude-prewarm
  install`).
- `notifier/notifier.applescript` — source for the notifier app, compiled by
  the installer (previously shipped only as a prebuilt `.app`).
- `tests/run.sh` — a dependency-free bash test suite (137 assertions): pure
  logic (time/JSON helpers, validators, weekday parsing, holiday calendars,
  usage-limit parsing, config validation, schedule computation) plus a stubbed
  runtime layer exercising `fire.bash`/`launchd.bash` — plist generation, the
  tick fire/skip decision, delayed self-healing recovery, the Codex ping,
  usage-limit back-off, notification gating, `window_anchor`, and pmset wake —
  without touching the real system.
- `README.md`, `LICENSE` (MIT), and this changelog.
- `uninstall --purge`: fully removes the binary, libraries, notifier app,
  config, and logs. Plain `uninstall` still keeps config + logs.
- `tests/regression.sh` — a second suite covering install/notifier regressions
  (bundle identity, signature, icon, notifier source pitfalls) plus syntax
  checks on every shipped script.

### Changed
- `uninstall` now accepts flags in any order and confirms exactly what will be
  removed (agents, wake schedule, and — with `--purge` — all files).
- `install.sh` now adds the bin directory to the user's shell profile when it
  is missing from `PATH` (idempotent, `$HOME`-relative line), instead of just
  printing a note.
- First-run notification setup is skipped when a previous install already
  registered the notifier with Notification Center, so reinstalls no longer
  re-fire the test notification.

### Fixed
- The notifier app's custom icon now actually shows: the installer strips
  osacompile's `Assets.car`/`CFBundleIconName` (which overrode `applet.icns`),
  pins a stable bundle identifier (`com.claude-prewarm.notifier`) so granted
  notification permission survives reinstalls, and re-signs the bundle ad-hoc
  so macOS still presents its notifications.

## [0.3.1-beta]

Runtime baseline: self-healing tick schedule, real-usage window detection from
Claude Code session logs, usage-limit back-off with reset-time parsing, US/
Canada holiday calendars and custom skip dates, battery and end-of-day
guardrails, overnight `pmset` wake with AC-power warnings, no-sudo `caffeinate`
keep-awake, optional Codex ping, `status --json`, and icon-carrying
notifications.
