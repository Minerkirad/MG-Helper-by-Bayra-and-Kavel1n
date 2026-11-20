# Changelog

All notable changes to MG Helper are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/).

## [2.3.0] - 2026-11-20
### Added (ROADMAP 5.3/5.4/6)
- Diff-preview everywhere: reset/import/profiles/custom-profile show
  "key: old -> new" and ask for confirmation before touching anything.
- Golden history / undo: menu [13] lists timestamped backups (validated),
  restores the picked one, rotates the current golden first.
- Custom profiles v2: menu [15] saves the current golden as a named profile
  (`profiles.json`), menu [14] applies it through the same transactional engine
  (journal + rollback + diff-preview).
- Error codes MG-E-XXXX in watcher warnings + docs/errors.md.
- docs/architecture.md (state machine, file formats, races), CONTRIBUTING.md,
  SECURITY.md.

## [2.2.0] - 2026-11-20
### Added (ROADMAP phase 2-4)
- Tray icon (net48 WinForms, compiled at install from readable source):
  status tooltip from the watcher's own files (no IPC races), balloon
  notifications on golden.applied / adopt / guard.rollback / insurance /
  golden.mismatch / errors, action menu (menu, diagnostics, profiles,
  restore, update), launched at logon via Startup-folder shortcut.
- Opt-in auto-update (ROADMAP 5.2): menu [12] downloads the latest release,
  verifies SHA256 against the hash published in the release notes, stages and
  runs the installer; any failure keeps the previous install intact.
- config.json reload on every heartbeat (30 min) - manual edits no longer
  require a watcher restart (REVIEW-#7).

## [2.1.0] - 2026-11-20
### Added (ROADMAP 2.3 + 2.4)
- Per-variant/per-GPU golden key: mismatch (game update to Enhanced, GPU
  change) -> SAFE MODE + menu [11] one-click new golden; diagnose shows key status.
- MG snapshot generations (newest 5, per-gen manifest); restore offers a
  generation picker; pre-restore backup names unique; traversal guard;
  MG-running check.

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
