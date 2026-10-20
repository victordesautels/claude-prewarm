# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.10-beta] — 2026-10-20

### Fixed
- **Window detection saw none of your own Claude Code use in 0.5.9.** It took
  each record's first `"type"` as its kind, but a real assistant record puts
  its message, with a nested `"type":"message"`, before its top-level
  `"type":"assistant"`. Only our own pings counted, so the tool could ping
  inside a window you had opened and misalign the day. A reply is now read
  from the `"type":"assistant","uuid","timestamp"` run, which always sits
  together, and a request from a record whose first type is `"user"`. On
  today's real logs the result matches a `jq` ground truth exactly (8,008
  requests). The test fixtures now use Claude Code's real key order; the old
  ones put `"type"` first, which hid this.
- `last_fire` and the ping history are stamped when the ping finishes, not
  before `claude` starts. The window opens when the request reaches the API,
  which can be tens of seconds in while MCP servers start. Stamping before
  start could let the next boundary ping land inside the old window and be
  wasted, leaving no window for up to 5 hours. A boundary is now waited for
  when it is up to 150s away (was 70s).
- The cached window anchor is rescanned in the window's last 30 minutes (was
  15): the slowest reply in two weeks of real logs came 15 minutes after its
  request.
- A config that parses but fails to load (`PROMPT=good morning` runs
  `morning`) is treated like a syntax error rather than killing every command.
  With such a config, `config set` and `install` refuse to run; before, they
  overwrote the whole config with defaults, and `install` re-ran the `pmset`
  wake.
- An invalid config value (`END=25:00`) now alerts once a day while prewarms
  are paused, as a broken config does. Before, it only logged an error every
  tick.
- A session-log path containing `:` no longer drops that file from window
  detection.
- A usage-limit reset time that has only just passed (the message rounds
  down, or the limit lingers a moment) is retried in 15 minutes. A dated one
  ("resets Oct 27, 6am" read at 06:00:05) rolled to next year and paused
  prewarms for a year; an undated one waited until tomorrow. A date is only
  read as next year's when it is months in the past ("Jan 2" read in December).
- The cached window anchor is rescanned near its window's end. A reply
  arriving late for an earlier request (another session's long generation)
  can move the real window's start, and so its end, earlier.
- The wait for a boundary that is almost due rechecks the guardrails
  afterwards, so it cannot ping past `END` or the `MIN_REMAINING_MIN` cutoff.
- The broken-config alert is sent only once its once-a-day marker is saved;
  an unsaveable marker no longer means an alert every tick.
- The boundary-wait and other tests that seed a time hours back now check by
  epoch that it is still today, which is DST-safe.

## [0.5.9-beta] — 2026-10-20

### Fixed
- Window detection dates each model reply by its request, the session record
  just before it, not by when the reply streamed back. A request sent just
  inside a window whose reply landed just past its end no longer invents a new
  5-hour window that holds back the next ping.
- Window detection reads only each record's own top-level timestamp (the one
  right after its `uuid`). It ignores a `timestamp` nested in tool-call
  arguments, and anything dated in the future.
- An open window's anchor is now cached until that window ends. Reading every
  record costs ~4s on a heavy day, and a tick held back by your own window
  used to repeat that every 5 minutes.
- A 5-hour boundary no longer fires a tick (5 minutes) late. `last_fire` is
  stamped a second or more into its tick, so on launchd's steady 5-minute phase
  the tick 5 hours on checked a hair early (e.g. 06:24:19 to 11:29:19). A
  boundary due within the next minute is now waited for, to 10s past due so the
  ping clears the old window's end. Codex's cadence and a usage-limit pause
  with no parsed reset time are stamped from the tick's start for the same
  reason.
- `prewarm.log` is no longer parsed for pings at all. Its stamps are local time
  with no UTC offset, and even the one-time import misread them from a shell in
  another `TZ`. Pings from 0.5.1 and older left session logs, which window
  detection reads directly.
- A config with a syntax error no longer kills every invocation at startup.
  Ticks pause and alert once a day, other commands warn and run on defaults,
  and `config edit` reverts a broken edit instead of crashing before it can.
- `config edit` no longer rejects, and reverts, every edit to a config that
  still says `MODE=aggressive` (or another retired mode name). The edited file
  now gets the same migration as at startup.
- An unwritable `fail_backoff` or `last_tick` no longer causes repeated false
  alerts. The failure is logged without an alert, and the previous tick counts
  as unknown.
- A dated reset ("resets Oct 27, 6am", a weekly limit) pauses until that day,
  not until the next 6am.

## [0.5.8-beta] — 2026-10-20

### Fixed
- The log is no longer merged into window detection once `fire_history`
  exists. This reverts 0.5.7's always-merge. Log stamps are local time with
  no UTC offset, so a shell with another `TZ`, travel, or the fall-back hour
  read them back hours off. The phantom pings that produced could leave a
  7-hour gap. The log now only stands in until `fire_history` exists, and
  the first ping imports it once.
- Retries are judged with a minute of slack, stamped from the tick's start
  rather than rounded. 0.5.7's rounding still missed when the minute rolled
  over mid-tick. Codex's retry was stamped after Claude's ping, which can take
  minutes, so it ran a tick late far more often; it now uses the same tick time.
- `uninstall` forgets `last_tick`, and every tick records it before config
  validation. A reinstall days later, or a stretch of invalid config, no longer
  reads as a sleeping Mac.
- An unwritable `last_tick` or back-off file no longer aborts every tick
  under `set -e`.
- The skip dedupe treats "only 56m left" and "only 6m left" as one reason.
- Tests that build `TIME` from the wall clock skip themselves when that time is
  not really N minutes away: across a DST change, and around midnight.

## [0.5.7-beta] — 2026-10-20

### Fixed
- A failed ping's retry time now falls on the minute. It was taken a second
  or two into the failing tick, so the tick 15 minutes later skipped it as a
  hair early. Every retry ran 5 minutes late, and a retry at the day's last
  possible prewarm never ran at all. `status` now says "No retry today" past
  that cutoff too.
- The day's logged pings are always merged into window detection, not only
  when `fire_history` is missing. An upgrade through 0.5.3–0.5.5 had started
  a history without the earlier 0.5.2 pings.
- A NUL byte in `prewarm.log` or a session log (a crash mid-write) no longer
  makes BSD grep treat it as binary and silently drop its lines.
- The first tick after an install or upgrade has no previous tick to tell a
  sleeping Mac by. A late fire on that tick is now logged as `held … (first
  tick, cause unknown)` with no "Mac was asleep" alert.
- Tests that failed only at certain times now pass at any time: the
  daily-mode test on the fall-back DST evening, the backfill test in the
  repeated hour, and the delayed-recovery test just after midnight.

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
