# Architecture (MG Helper)

Версия 2.6.1. Источник истины по поведению — контракт итерации
(`_analysis\CONTRACT-2.6.1.md`), здесь — как это разложено по файлам и какие
форматы при этом пишутся.

## Компоненты
| Компонент | Файл | Жизненный цикл |
|---|---|---|
| Watcher (ядро) | `gta-settings-watcher.ps1` | Задача `MG_Helper_Watcher` (логон + повтор 10 мин), single instance через `Local\MG_Helper_Watcher` mutex; кооперативный стоп через событие `Local\MG_Helper_Stop` |
| Hidden host | `MG-Helper-Host.exe` (компилируется из `MG-Helper-Host.cs` при установке) | Запускается задачей; возвращает exit 0 если watcher жив; время жизни задачи == времени жизни watcher |
| Tray | `MG-Helper-Tray.exe` (из `MG-Helper-Tray.cs`) | Startup-папка; статус только из `watcher.health.json` + `events.jsonl`, баллуны, меню действий |
| Меню | `MG-Helper.ps1` / `MG-Helper.bat` | Интерактив, пункты 1–15 |
| Общий модуль | `common.ps1` | Discovery, config, атомарные записи, golden, бины, журнал, diff, health |
| Beta C# core | `MGCore.cs` → `MGCore.exe` | Только при `coreMode: "csharp"`; установщик компилирует и smoke-запускает, при сбое остаётся PS-watcher |

## Политика сессии (2.6.1)
| Ключ `config.json` | По умолчанию | Поведение |
|---|---|---|
| `allowAdopt` | `false` | единственный включатель adopt; при `false` эталон при выходе восстанавливается |
| `onExit` | `'restore'` | deprecated, adopt не включает (пишется предупреждение в лог при `'adopt'`) |
| `sessionGuard` | `true` | kill-switch охраны |
| `guardWindowSec` | `0` | `0` — охрана всей сессии; `>0` — первые N секунд, истечение видно как `guard.window_expired` |
| `cfgVersion` | `2` | одноразовая миграция политики 2.5/2.6 (`Update-MgConfigPolicy`) |

## State-машина watcher
```
        старт, state доверенный (Idle)
       ┌──────────────────────────────┐
       ▼                              │
  ┌────────┐  игра стартует    ┌──────┴─┐
  │  Idle  ├──────────────────►│ InGame │  launch: снапшот MG, pre-apply backup,
  └────────┘                   └────────┘  apply эталона (если ключ совпал)
       ▲                              │
       │ игра закрылась:              │ вся сессия (guardWindowSec=0):
       │ adopt (только при            │ чужая перезапись → golden.applied/guard
       │ allowAdopt+applied+changed)  │
       │ иначе restore эталона        │
       │                              ▼
       │                       ┌───────────────┐
       └───────────────────────┤UnknownSession │  игра уже запущена, state не доверенный
              игра закрылась:  └───────────────┘  или ключ эталона не совпал:
              ничего не пишем,                      ни apply, ни adopt,
              reset → Idle                          трей: SAFE MODE
```
- `UnknownSession` — SAFE MODE: watcher наблюдает, но не применяет эталон и не
  усыновляет изменения; выход из него — по закрытию игры (reset в `Idle`) либо
  новым эталоном: меню [11] пишет эталон и ключ и перезапускает watcher, чтобы
  тот перечитал их.
- Adopt возможен только при `allowAdopt=true` **и** `applied` (эталон применён
  нами в этой сессии) **и** файл изменился после нашей записи. Все сравнения
  времени — в UTC (`ConvertTo-UtcTime`).
- Новая сессия объявляется только когда записанный PID игры действительно
  исчез; выбор процесса детерминирован (сортировка по Id).

## Состояния трея (по `watcher.health.json`)
| Состояние | Условие | UI |
|---|---|---|
| Healthy | `status=running`, heartbeat ≤ 15 с | зелёный, «Защищено» (игра запущена / ожидание) |
| Degraded | heartbeat 15–30 с или `status=starting` | жёлтый, «Watcher не отвечает» |
| Stopped | `status=stopping`, heartbeat > 30 с, либо файла нет | красный (есть признаки процесса) / серый, «Watcher не работает (меню [9])» |
| Unknown | JSON битый/нечитаемый | жёлтый, «Статус неизвестен» |
| SAFE MODE | `phase=UnknownSession` или неразрешённый `golden.mismatch`/`session.unknown` в хвосте `events.jsonl` | жёлтый, «SAFE MODE: защита выключена» даже при свежем heartbeat |

`watcher.ready` в решении о статусе не участвует: это маркер готовности для
установщика, он не проверяется на свежесть. Процесс watcher'а (строгое
совпадение командной строки) — только дополнительная улика, когда health-файла нет.

## Форматы файлов
| Файл | Формат | Кто пишет |
|---|---|---|
| `config.json` | JSON | `Resolve-MgPaths` / installer (single writer; watcher перечитывает на heartbeat раз в 30 мин) |
| `state.json` | JSON schema 2: `phase`, `gamePid`, `gamePath`, `sessionStart`, `guardRollbacks`, `restarts`, `applied`, `lastApplyUtc` | watcher (single writer), атомарно |
| `watcher.health.json` | JSON schemaVersion 1, одна строка: `pid`, `processStartUtc`, `version`, `status`, `phase`, `gamePid`, `lastHeartbeatUtc`, `sequence`, `lastErrorCode` | watcher: атомарно (tmp + replace), каждые 5 с и на каждом изменении фазы; `status` = `starting`/`running`/`stopping` |
| `watcher.ready` | маркер-файл | watcher; установщик ждёт его (MG-CR-021); снимается после `status=stopping` |
| `events.jsonl` | JSONL `{ts, phase, event, data}` | watcher; трей читает новые строки с байтового курсора (в памяти, стартует с текущего конца файла), diagnose читает хвост |
| `journal_*.json` | JSON `{op,status,steps[]}` | профили/reset/import; reconciliation при старте watcher |
| `golden_key.json` | JSON `{variant,gpu,created}` | installer/reset; обновляется watcher'ом при adopt |
| `profiles.json` | JSON `{profiles:{name:{values}}}` | save-custom-profile |
| `package_hashes.txt` | SHA256 список | installer |
| `mg_snapshot\<stamp>\manifest.json` | JSON: имя файла снапшота → путь внутри папки-источника | watcher (`Snapshot-MgFiles`) |
| `mg_snapshot\<stamp>\roots.json` | JSON: имя файла снапшота → **полный** путь папки-источника | watcher; читает `restore-mg-snapshot.ps1` |

Свежесть `lastHeartbeatUtc` (единственное правило для всех потребителей):
≤ 15 с — свежий, 15–30 с — просроченный, > 30 с или нет файла — мёртвый.

`roots.json` появился в 2.6.1 отдельным файлом, а не ключом внутри
`manifest.json`: манифест читают уже установленные версии, и лишний ключ в нём
сломал бы их разбор. Восстановление без `roots.json` (снапшоты 2.6.0 и старше)
опознаёт источник по flatten-префиксу имени файла.

## События
| Событие | Когда | `data` |
|---|---|---|
| `watcher.start` / `watcher.ready` / `watcher.stop` | старт, готовность, остановка | версия |
| `session.start` / `session.end` | границы сессии | pid / причина |
| `session.unknown` | вход в `UnknownSession` (SAFE MODE) | причина |
| `golden.applied` | эталон записан | `launch` / `reapply` / `guard` / `exit-restore` |
| `adopt.accepted` | правки приняты как эталон | `session` |
| `apply.failed` | запись эталона не удалась | краткая причина |
| `guard.rollback` | откат чужой перезаписи | причина |
| `guard.window_expired` | истекло окно при `guardWindowSec > 0` | секунды |
| `golden.mismatch` | ключ эталона не совпал | причина |
| `insurance.restored` / `insurance.risk` / `bins.archived` | страховка `.bin` | статус |
| `error`, `tray.restart`, `auto-update.start` | прочее | — |

## Политика бэкапов
- golden: `old_<stamp>` (10 последних) + `.bak` (ротация при adopt) + `before_apply.bak`
- профили: `before_maxfps/before_shadows/before_profile` (10 последних)
- .bin: `vanilla_backup_archive\<stamp>` — 2 поколения, копия никогда не move
- снапшоты MG: 5 поколений, каждое со своим манифестом
- journal-восстановление: `running` + `write-golden` done → откат из backup step

## Гонки и их закрытие
| Гонка | Закрытие |
|---|---|
| kill посреди .bin-копии | `.incomplete` → rename после верификации |
| kill посреди профиля | journal + rollback + reconciliation |
| лаунчер перезаписал на любой секунде сессии | drift-guard всей сессии (`guardWindowSec=0`), FSW-пробуждение + проверка не чаще раза в 10 с |
| рестарт игры за 3 с | recheck после сна; новая сессия только если записанный PID исчез |
| PID reuse при takeover | проверка процесса по `cfg.gameProcesses`; записанный `gamePath` сверяется, если он есть в `state.json` |
| перезапуск watcher'а посреди сессии | `applied`/`lastApplyUtc` восстанавливаются из `state.json`, время — UTC |
| watcher убит/завис | `watcher.health.json` протухает: 15/30 с → Degraded/Stopped, затем `watcher.ready` не считается доказательством жизни |