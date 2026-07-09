# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
