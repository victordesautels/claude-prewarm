# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0-beta] — unreleased

First release with a real source tree and packaging. The runtime is unchanged
except for the uninstall improvement below.

### Added
- `install.sh` — an idempotent installer that lays down the binary, libraries,
  assets, and the compiled notifier app into the standard locations. macOS-only
  guard; no `sudo`, no schedule created (that stays with `claude-prewarm
  install`).
- `notifier/notifier.applescript` — source for the notifier app, compiled by
  the installer (previously shipped only as a prebuilt `.app`).
- `tests/run.sh` — a dependency-free bash test suite for the pure logic
  (time/JSON helpers, validators, weekday parsing, holiday calendars,
  usage-limit parsing, config validation, schedule computation).
- `README.md`, `LICENSE` (MIT), and this changelog.
- `uninstall --purge`: fully removes the binary, libraries, notifier app,
  config, and logs. Plain `uninstall` still keeps config + logs.

### Changed
- `uninstall` now accepts flags in any order and confirms exactly what will be
  removed (agents, wake schedule, and — with `--purge` — all files).

## [0.3.1-beta]

Runtime baseline: self-healing tick schedule, real-usage window detection from
Claude Code session logs, usage-limit back-off with reset-time parsing, US/
Canada holiday calendars and custom skip dates, battery and end-of-day
guardrails, overnight `pmset` wake with AC-power warnings, no-sudo `caffeinate`
keep-awake, optional Codex ping, `status --json`, and icon-carrying
notifications.
