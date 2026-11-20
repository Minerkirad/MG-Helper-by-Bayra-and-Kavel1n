# Architecture (MG Helper)

## Компоненты
| Компонент | Файл | Жизненный цикл |
|---|---|---|
| Watcher (ядро) | `gta-settings-watcher.ps1` | Задача `MG_Helper_Watcher` (логон + повтор 10 мин), single instance через `Local\MG_Helper_Watcher` mutex |
| Hidden host | `MG-Helper-Host.exe` (компилируется из `MG-Helper-Tray/Host.cs` при установке) | Запускается задачей; возвращает exit 0 если watcher жив; время жизни задачи == времени жизни watcher |
| Tray | `MG-Helper-Tray.exe` | Startup-папка; статус из файлов, баллуны, меню действий |
| Меню | `MG-Helper.ps1` / `MG-Helper.bat` | Интерактив, пункты 1–15 |
| Общий модуль | `common.ps1` | Discovery, config, атомарные записи, бины, журнал, diff |

## State-машина watcher
```
            старт, игра не запущена
           ┌────────────────────────┐
           ▼                        │
  ┌─────┐   игра стартует   ┌──────┐ │  игра закрылась:
  │ Idle├──────────────────►│InGame│ │  adopt (если applied)
  └─────┘                   └──────┘ │  else: restore (только applied)
      ▲  игра уже запущена,         │
      │  состояние недостоверно     │
      │   ┌───────────────┐         │
      └───┤UnknownSession │◄────────┘
          └───────┬───────┘
                  │ игра закрылась: ничего не трогаем, reset → Idle
```
- `UnknownSession`: game already running + нет доверенного state → наблюдение без записей.
- Golden key (variant+GPU) не совпал → SAFE MODE: не применять и не усыновлять (меню [11] — новый эталон).
- Fast-relaunch: новый PID при активной сессии = новая сессия.

## Форматы файлов
| Файл | Формат | Кто пишет |
|---|---|---|
| `config.json` | JSON | Resolve-MgPaths / installer (single writer — watcher читает reload на heartbeat) |
| `state.json` | JSON schema 2: phase, gamePid, gamePath, sessionStart, guardRollbacks, restarts, applied, lastApplyUtc | watcher (single writer) |
| `watcher.ready` | маркер-файл | watcher; установщик ждёт его (MG-CR-021) |
| `events.jsonl` | JSONL {ts, phase, event, data} | watcher; tray/diagnose читают |
| `journal_*.json` | JSON {op,status,steps[]} | профили/reset/import; reconciliation при старте watcher |
| `golden_key.json` | JSON {variant,gpu,created} | installer/reset |
| `profiles.json` | JSON {profiles:{name:{values}}} | save-custom-profile |
| `package_hashes.txt` | SHA256 список | installer |

## Политика бэкапов
- golden: `old_<stamp>` (10 последних) + `.bak` (ротация при adopt) + `before_apply.bak`
- профили: `before_maxfps/before_shadows/before_profile` (10 последних)
- .bin: `vanilla_backup_archive\<stamp>` — 2 поколения, копия никогда не move
- journal-восстановление: `running` + `write-golden` done → откат из backup step

## Гонки и их закрытие
| Гонка | Закрытие |
|---|---|
| kill посреди .bin-копии | `.incomplete` → rename после верификации |
| kill посреди профиля | journal + rollback + reconciliation |
| лаунчер перезаписал в окне запуска | drift-guard (FSW wake + окно 120 с) |
| рестарт игры за 3 с | recheck после сна + новый PID = новая сессия |
| PID reuse | takeover проверяет процесс и путь exe |
