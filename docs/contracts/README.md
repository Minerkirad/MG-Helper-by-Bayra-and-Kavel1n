# Контракты форматов MG Helper

Схемы того, чем обмениваются watcher, трей и диагностика. До 3.0 форматы жили только
в коде; здесь они зафиксированы как JSON Schema (MG3-011 в
[ROADMAP-3.0](../ROADMAP-3.0.md)).

| Файл | Что описывает | Кто пишет | Кто читает |
|---|---|---|---|
| [state.schema.json](state.schema.json) | `state.json` — состояние сессии watcher'а | `gta-settings-watcher.ps1` (`Save-State`) | watcher при старте (`Read-MgState`), трей (legacy fallback) |
| [health.schema.json](health.schema.json) | `watcher.health.json` — heartbeat | `Write-WatcherHealth` (common.ps1) | трей, `diagnose.ps1` (`Get-WatcherHealth`) |
| [events.schema.json](events.schema.json) | одна строка `events.jsonl` | `Ev` в watcher'е | трей (баллуны, SAFE MODE), диагностика |

## Правила версионирования

- В документах есть явная версия: `schema` (state, сейчас `2`) и `schemaVersion`
  (health, сейчас `1`). Читатель обязан трактовать неизвестную версию как
  «неизвестно», а не как «всё в порядке».
- **Добавить поле** можно без смены версии: читатели игнорируют незнакомые поля
  (`additionalProperties` в `state` и `events` не запрещён). У `health` список
  полей закрыт — это компактный файл, который читают все.
- **Удалить или переименовать поле, изменить смысл** — только со сменой версии и
  миграцией. Имена событий `events.jsonl` — часть контракта: на них завязаны
  баллуны трея, поэтому переименование запрещено.
- Пути пользователя в события не попадают (см. `SECURITY.md`); `data` — короткая
  строка-причина, а не диагностический дамп.

## Проверка

```powershell
# схемы вообще читаемы (есть $schema/$id/title)
powershell -NoProfile -File .\tools\validate-contracts.ps1 -SelfTest

# конкретный файл против схемы (код возврата 1 при нарушении)
powershell -NoProfile -File .\tools\validate-contracts.ps1 -Schema .\docs\contracts\health.schema.json -Data "$env:LOCALAPPDATA\MG_Helper\watcher.health.json"
```

`tools\check.ps1` проверяет это же автоматически: свежий `watcher.health.json`,
дефолтный `state.json` и живая строка `events.jsonl` обязаны проходить свои схемы,
а испорченный документ — нет. Валидатор реализует подмножество JSON Schema
(`type`, `const`, `enum`, `pattern`, `minimum`, `required`, `properties`,
`additionalProperties`, `items`) и не требует внешних модулей — CI и живая машина
работают под PowerShell 5.1 без установки чего-либо.

## Зачем

Parity-набор 3.0 (см. ROADMAP §4) сравнивает PS-watcher и будущее C#-ядро по
трём уровням: решения (чистые функции), файлы (`settings.xml`, `state.json`) и
события. Схемы — это контракт второго и третьего уровня: без них «сравнить
выход» означает сравнить текст, а не смысл.