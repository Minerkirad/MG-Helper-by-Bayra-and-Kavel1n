# Changelog

All notable changes to MG Helper are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/).

## [2.0.0] - 2026-11-20
### Added (ROADMAP phase 1-2, partial)
- Operation journal + reconciliation at watcher start: multi-file operations
  (profiles, reset, import) are recorded step-by-step; a kill mid-operation is
  rolled back automatically (`journal_*.json`, `Invoke-OpReconciliation`).
- Structured event log `events.jsonl` (`golden.applied`, `guard.rollback`,
  `adopt.accepted`, `bins.archived`, `insurance.*`, `error`) with rotation.
- FileSystemWatcher hybrid: an overwrite of settings.xml wakes the loop within
  200 ms (guard checks react immediately instead of waiting a full tick).

## [1.9.1] - 2026-11-20
### Fixed (REVIEW.md rounds 1-2)
- Partial .bin restore now CONTINUES on the next tick (was stuck on "at least one bin").
- Exit-restore only runs when the golden was actually applied this session.
- Archive generations are copied to `<name>.incomplete` and renamed only after
  verification - a kill mid-copy can no longer produce a trusted torn generation.
- Uninstall returns exit code 1 when incomplete; the menu does not claim success.
- Exit branch re-checks the game after the 3 s wait (fast-relaunch race).
- CIM calls have -OperationTimeoutSec 15 (a hung WMI no longer hangs the watcher).
- Host mutex check wrapped in try/catch (no WER dialog over a fullscreen game).
- Shared `Get-WatcherProcess` filter; golden -> .bak rotation on adopt; real XML
  validators in repair/import/diagnose; dlccache retention; verified bin copies.

## [1.9.0] - 2026-11-20
### Added
- Staged deployment with verification (no mixed-version installs).
- SHA256 manifest of deployed files (`package_hashes.txt`).
- READY handshake between the watcher and the installer.
- Structural XML comparison; takeover verifies the game exe path.

## [1.8.x] - 2026-11-19
- Data-safety hardening MG-CR-001..012: non-destructive config save, validated
  golden apply, real XML validation, UnknownSession safe mode, verified bin
  restore, atomic reset, transactional profiles, LIVE-confirm in repair, masked
  diagnose report, honest uninstall summary.

## [1.6.x - 1.7.x] - 2026-11-19
- State-machine watcher with adopt-on-exit, drift-guard launch window,
  hidden GUI host (no console flash), process detection by exe tokens,
  staged smoke harness (`tools/check.ps1`).
