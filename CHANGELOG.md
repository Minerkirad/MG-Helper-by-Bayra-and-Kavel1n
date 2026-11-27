# Changelog

All notable changes to MG Helper are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]
### Added
- 3.0 stage 4 (C# core): CoreDecisions.cs implements the same decisions as the PS
  core (adopt matrix, guard, golden selection, apply, XML compare, policy migration)
  and answers MgCore.exe --decide <request.json> <response.json>. tools\parity.ps1
  -Implementation core runs it against the same expected.json, and -Both compares the
  two implementations field by field. Both are 21/21 and cross-checked on every
  commit; a static check keeps the C# core free of registry/process/network calls.
  Suite: 97 checks, ALL GREEN.
- 3.0 stage 3 (PS core module): the eight pure decisions (adopt matrix, guard window,
  golden-key match, UTC conversion, state read/defaults, policy migration, settings key
  parsing) moved out of common.ps1 into `MgHelper.Core.ps1`, which common.ps1 dot-sources.
  One source of truth for the PS implementation and the C# core that will replace it;
  the module is in the installer deploy list and the suite asserts it is defined there,
  not duplicated in common.ps1, loaded by dot-source and shipped by the installer.
  Suite: 95 checks, ALL GREEN.
- 3.0 stage 1 (testability): `MG_HELPER_DIR` redirects every piece of watcher state
  to a sandbox (default path unchanged, and in that mode the single-instance mutex
  and the stop event use a separate test namespace), and `tools\integration.ps1`
  runs the REAL watcher loop end to end: start/ready, a session with a game
  process (golden applied, pre-apply backup made), exit back to Idle with
  `settings.xml` byte-identical, then `stop.request` -> `watcher.stop`,
  `status=stopping` and `watcher.ready` removed. 17 assertions, wired into
  `tools\check.ps1` §11y; the suite now takes ~30 s of which ~20 s is this run.
- Detailed migration plan: `docs/PLAN-3.0.md` - eight stages with tasks (MG3-021…
  044), file-level scope, DoD per stage, dependency graph, quality gates, risks,
  rollback and the checklist for retiring the PS watcher. Stage 0 (contracts,
  parity, release, backups) and stage 1 are closed.
- Parity runner (3.0 stage B): `tools\parity\expected.json` holds 21 scenarios as
  data (`guard`, `adopt`, `golden-source`, `apply`, `compare`, `policy`) and
  `tools\parity.ps1` executes them against the selected implementation - today the
  PS watcher, later the C# core via `-Implementation core`. Divergence exits 1;
  `tools\check.ps1` §11x requires at least 20 scenarios and a fully green run.
  This is the strangler contract: "the new component produces the same decisions
  on the same inputs", checked on every commit instead of by eye.
- Contracts (MG3-011): `docs\contracts\` now holds JSON Schemas for the three
  formats that cross a process boundary - `state.json`, `watcher.health.json` and
  one `events.jsonl` line - plus `tools\validate-contracts.ps1`, a dependency-free
  validator that runs under PowerShell 5.1 (the subset of JSON Schema the project
  uses). `tools\check.ps1` gained six contract checks: the schemas themselves, a
  fresh health file, a health file without `status` (must be rejected), the
  `Read-MgState` defaults, a real event line, and an unknown event name (must be
  rejected). These are the file/event levels the 3.0 parity runner compares, so
  "same output" now means "same meaning" instead of "same text".

## [2.6.1] - 2026-11-27
### Fixed
- Adopt is opt-in: `allowAdopt` (default `false`) is the only switch, `onExit`
  no longer enables it. Cause: with `onExit=adopt` any write that arrived after
  the guard window was adopted as the new golden - one launcher overwrite
  silently replaced the settings the protection was meant to keep, and the loss
  was irreversible (the old golden survived only as `.old_*`/`.bak`).
- Time is compared in UTC: `lastApplyUtc` and `sessionStart` go through
  `ConvertTo-UtcTime` before any comparison. Cause: a timestamp read back from
  `state.json` came back as Local, so after a watcher restart (takeover) "the
  file changed after us" was always false - adopt never fired and the player's
  in-game edits were rolled back with the line "nobody wrote after our apply".
- A new game session is declared only when the recorded game PID is really gone;
  the process pick is deterministic (sorted by Id). Cause: Majestic starts the
  game from its own `backup` folder, two processes matched the pattern and
  `Select-Object -First 1` was non-deterministic - up to six false "new session"
  events per session re-snapshotted MG and re-applied the golden mid-game.
- Drift-guard covers the whole session by default (`guardWindowSec: 0`). Cause:
  guarding only the first 120 s moved the hole to the end of the session - a
  write after 120 s was neither rolled back nor distinguishable from a user edit.
  A finite window stays available, but its expiry is now logged and emitted as
  `guard.window_expired` instead of passing silently.
- Guard rollback obeys the same pre-apply backup precondition as the launch
  branch (MG-CR-006). Cause: the in-session branch called `Apply-Golden` without
  `$preBackupOk` and without refreshing `settings.before_apply.bak`, so a
  rollback could overwrite the file with no recoverable copy of the user's
  settings.
- SAFE MODE on a golden-key mismatch is no longer one-way: the mismatch emits
  `session.unknown` (+ `golden.mismatch`) and is visible in the tray, an adopted
  golden refreshes `golden_key.json`, and menu [11] restarts the watcher so the
  new key is picked up immediately. Cause: the flag was set and never cleared
  while the protection stayed off, and nothing told the user that.
- MG snapshot restore works again: `$flat` is defined and each file's source root
  comes from the generation manifest (`roots.json`). Cause: the reader lost the
  variable when the snapshot writer moved into `common.ps1`, so the filter
  degenerated to `__*.json` and matched 0 of 22 files - menu [7] and the tray
  action always printed "no files for the current MG folder" and exited 1.
- Apply and adopt are visible: `golden.applied` (`launch`/`reapply`/`guard`/
  `exit-restore`), `adopt.accepted`, `apply.failed`, `session.start`,
  `session.end`, `session.unknown`, `guard.window_expired`. Cause: the tray
  balloon handlers were wired to events emitted only by the beta C# core, so in
  the default configuration `events.jsonl` had no record of a single successful
  apply, and a failed apply was logged by nothing at all.
- Tray status comes from `watcher.health.json` plus heartbeat age (Healthy /
  Degraded / Stopped / Unknown, plus SAFE MODE) instead of "`watcher.ready`
  exists or any powershell window is alive". Cause: the old rule showed green
  exactly when there was no protection (`UnknownSession`, golden mismatch, or a
  dead watcher whose ready marker stayed behind).
- Broad `Unblock-File` is gone from the menu entry point; only the installer
  unblocks package files with runnable extensions (`.ps1`/`.bat`/`.cs`) and
  reports how many it touched (MG3-007). Cause: the entry point stripped
  Mark-of-the-Web from every file of the folder on every start of the menu.
- Watcher stop is no longer a single point of failure: if the named event
  `Local\MG_Helper_Stop` cannot be opened, the menu writes a `stop.request` flag
  and the watcher consumes it on the next tick; a stale flag is removed at start.
  Cause: on a real machine the event could not be opened at all
  (`MG-E-0105`), so `Restart-Watcher` after [2]/[11] only warned "not guaranteed"
  and the watcher kept running with an outdated golden/key.
- The 2.6.x config is actually migrated: `cfgVersion` defaults to 3 and a config
  without the key is treated as legacy (0), plus a repair branch for configs the
  first 2.6.1 build stamped `cfgVersion: 2` without migrating. Cause: the gate
  compared the in-memory default (2) with itself, so `guardWindowSec: 120` and
  `onExit: adopt` survived the upgrade and the whole-session guard never became
  active on updated installs.

### Changed
- New `watcher.health.json` (MG3-002): atomic write (tmp + replace), UTF-8
  without BOM, one flat JSON object, refreshed every 5 s and on every phase
  change; `status` is `starting`/`running`/`stopping`. Consumers: the tray and
  `diagnose.ps1`, both through `Get-WatcherHealth` (fresh <= 15 s, stale 15-30 s,
  dead > 30 s or no file). A corrupt file is Unknown, never Healthy. `watcher.ready`
  stays as the installer handshake and is removed after `status=stopping`.
- Config defaults: `allowAdopt: false`, `onExit: 'restore'`, `guardWindowSec: 0`;
  `cfgVersion: 3` marks the one-time migration of the values 2.5/2.6 installers
  wrote (`onExit: "adopt"`, `guardWindowSec: 120`), so an existing `config.json`
  keeps working and gets the v1 policy without manual edits. Once the config is
  at version 3 its values are never touched again - that is a user choice.
- Self-heal chain narrowed: `Get-ValidGolden` heals only from
  `settings.golden.xml` / `.bak`; live `settings.xml` and
  `settings.before_apply.bak` are reachable only with `-AllowLiveFallback`
  (kept for deliberate recovery; the installer makes its own explicit choice).
  Cause: a torn golden used to be "healed" with whatever the
  launcher had just written, including inside a guard rollback.
- Golden/apply decisions documented and covered: `Test-AdoptCandidate` now takes
  `$AllowAdopt` as its second parameter instead of `$OnExitAdopt`.
- Fault-injection coverage in `tools\check.ps1`: a torn or foreign `state.json`
  falls back to defaults (and therefore to SAFE MODE, never to a trusted session),
  a stale `<target>.<pid>.mgtmp` from a killed write cannot become the target,
  and a relaunched game re-arms the guard window from its own start.
- Docs: README, `docs/architecture.md` and `docs/errors.md` describe the 2.6.1
  behaviour; new `docs/ROADMAP-3.0.md` maps stages A-E of the 3.0 review onto
  this repository.

### Deprecated
- `onExit`: ignored for adopt. Set `"allowAdopt": true` instead; the watcher logs
  a deprecation line when it finds `onExit: "adopt"`.

## [2.5.0-beta.1] - 2026-11-20
### Added (ROADMAP phase 3 - strangler step 1, BETA)
- MGCore.cs: minimal C# core (net48, ~21 KB exe) - state machine, golden
  apply/adopt, drift-guard window, .bin insurance with .incomplete markers,
  journal reconciliation, events/state/ready formats fully compatible with
  the PS tooling. Selected by config "coreMode": "csharp" (default 'ps');
  installer compiles it, smoke-runs it and switches the task action; any
  failure falls back to the PS watcher. Known beta limits: process detection
  by name only, GPU golden-key check stays on the PS core.
- Pre-release: install only if you want to test the compiled core.

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
