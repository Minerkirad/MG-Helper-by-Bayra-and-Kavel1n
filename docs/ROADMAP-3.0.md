# MG Helper 3.0 — план перехода

Документ переводит «MG HELPER 3.0 — техническое ревью и дорожная карта»
(22.11.2026, `MG_Helper_3.0_Technical_Review_and_Roadmap.docx`; машинный текст —
`_analysis\roadmap-3.0.txt`) на язык файлов этого репозитория: что где лежит,
что считается готовым, в каком порядке пилить и чем доказывать, что новый
компонент не хуже старого.

Источники истины, на которые опирается план:

| Документ | Роль |
|---|---|
| `_analysis\CONTRACT-2.6.1.md` | замороженный контракт поведения 2.6.1 (инварианты §7 — критерий регресса) |
| `_analysis\ANALYSIS-v2.6-vs-v1.md` | разбор причин расхождения 2.6 с v1 (разделы 3.1–3.11) |
| `_analysis\roadmap-3.0.txt` | §4 (фиксы), §13 (тесты), §14 (план миграции), §15 (этапы A–E), §16 (риски), §17 (backlog MG3-*) |
| [architecture.md](architecture.md) | фактическая архитектура 2.6.1: компоненты, состояние, форматы |

Сроки в неделях здесь сознательно не указаны: в документе 3.0 их нет, а объём
каждого этапа зависит от того, сколько итераций parity-набора потребуется.
Оценка дана классами S/M/L.

## 1. Что уже закрыто в 2.6.1

| ID (backlog 3.0) | Задача | Статус | Чем подтверждается в репозитории |
|---|---|---|---|
| MG3-001 | Повторно подтвердить findings на 2.6.0 | закрыто | `_analysis\ANALYSIS-v2.6-vs-v1.md` — файлы, строки, живой `watcher.log`, воспроизводимый `_analysis\replay.ps1` |
| MG3-002 | Health heartbeat schema | закрыто | `common.ps1`: `Write-WatcherHealth` / `Get-WatcherHealth` (порог 15/30 с, битый JSON → Unknown); `gta-settings-watcher.ps1`: `Update-Health` на каждом тике и на смене фазы, `status=stopping` при выходе; потребители — `MG-Helper-Tray.cs`, `diagnose.ps1`. DoD «stale heartbeat не Healthy» закрыт тестом `tools\check.ps1` §11s (свежий/20 с/45 с/`stopping`/битый JSON/нет файла) |
| MG3-003 | PID identity validation | закрыто | новая сессия объявляется только когда записанный PID игры исчез, выбор процесса детерминирован (сортировка по Id), takeover проверяет процесс по `gameProcesses` и путь exe из `state.json` (`Read-MgState` восстанавливает `gamePath`). Остаётся: детект игры по-прежнему по имени/exe-токенам, нет `installationId` и проверки командной строки watcher'а — это §4.6 документа 3.0 и MG3-014 |
| MG3-004 | Safe READY handshake | закрыто частично | `watcher.ready` пишется после загрузки конфига, восстановления журнала (`Invoke-OpReconciliation`) и первой записи health; установщик стирает старый маркер и ждёт новый 30 с. Остаётся: READY не включает открытие IPC (его пока нет) |
| MG3-005 | Atomic version activation | закрыто частично | `install-gta-watcher.ps1`: staging-каталог → проверка копии (наличие, размер, BOM, парсинг ps1, `version.json`) → promote → `package_hashes.txt` → READY. Сбой до promote установку не трогает, но сам promote — пофайловое копирование в `HelperDir`, поэтому kill посреди него теоретически может оставить смесь версий. Каталогов `Versions/<ver>` и указателя `current.json` нет — полная схема на этапе E |
| MG3-006 | Единый источник версии | закрыто для PS-пакета | `version.json` — единственный источник, `common.ps1` (`$script:Version`) — fallback; `tools\check.ps1` §8 валит сборку при рассинхроне, CI гоняет его на каждый push. Для 3.0 нужен `Directory.Build.props` (AssemblyVersion/FileVersion/InformationalVersion) и проверка tag == manifest == installer |
| MG3-007 | Убрать blanket Unblock-File | закрыто | в точке входа массового `Unblock-File` нет; установщик снимает метку только с файлов пакета расширений `.ps1/.bat/.cs` (scoped по расширению, без сверки хэшей — сверка манифеста остаётся задачей MG3-005) |

Следствие для 3.0: этап A (стабилизация) в основном выполнен, но его DoD
закрывается не «галочками», а зелёным сценарным набором — см. §4.

## 2. Что остаётся

| ID | Задача | Куда ложится в этом репозитории | Предусловие |
|---|---|---|---|
| MG3-008 | Разделить InstallRoot и DataRoot | сейчас всё в `%LOCALAPPDATA%\MG_Helper` (`$script:HelperDir` в `common.ps1`); цель — `App\Versions\<ver>` + отдельный `Data` | этап E (установщик), иначе обновление снова будет менять Data |
| MG3-009 | C# state recovery parity | эталон — восстановление сессии в `gta-settings-watcher.ps1` (`state.json` schema 2: `phase`, `gamePid`, `applied`, `lastApplyUtc`, `sessionStart`); в `MGCore.cs` это пока beta | MG3-012 |
| MG3-010 | Корректный rollback status | эталон — `Invoke-OpReconciliation` в `common.ps1` и честные итоги `uninstall.ps1`; нужны статусы `rollback_failed` / `recovery_required` вместо «recovered» | MG3-011 |
| MG3-011 | Contracts + schemaVersion | схемы сегодня живут в коде: `state.json` schema 2, `watcher.health.json` schemaVersion 1, `profiles.json`, `journal_*.json`; вынести в JSON Schema + типизированные DTO | этап B |
| MG3-012 | Core library | чистые функции из `common.ps1`: `Test-AdoptCandidate`, `Test-GuardActive`, `Test-SameSettings`, `Test-GoldenKeyMatchPure`, `Get-SettingsKeyValues`, `Get-ValidGolden`/`Apply-Golden` — в C# с parity-тестами | MG3-011 |
| MG3-013 | WPF dashboard | заменяет `MG-Helper.ps1` как UI; трей (`MG-Helper-Tray.cs`) остаётся | MG3-012, MG3-014 |
| MG3-014 | Named Pipe IPC | сейчас «IPC» = файлы (`watcher.health.json`, `state.json`, `events.jsonl`) + событие `Local\MG_Helper_Stop`; команды трея запускают скрипты напрямую. Нужны `schemaVersion/requestId/command/payload`, ACL по SID, таймауты | MG3-011, MG3-012 |
| MG3-015 | Profiles UI | `save-custom-profile.ps1` / `apply-custom-profile.ps1` / `profiles.json` — функциональный эталон | MG3-013 |
| MG3-016 | Diagnostics center | `diagnose.ps1` (проверки health/живого settings/задачи) — эталон отчёта, нужен экспорт из GUI | MG3-013 |
| MG3-017 | Inno Setup wizard | `install-gta-watcher.ps1`, `uninstall.ps1`, `update-helper.ps1` — текущая логика, которую мастер должен воспроизвести | MG3-008 |
| MG3-018 | Update rollback | `update-helper.ps1` (SHA256 + staged install) + `current.json` | MG3-005, MG3-017 |
| MG3-019 | Authenticode signing | CI (`.github\workflows\ci.yml`) + релизные артефакты | MG3-017 |
| MG3-020 | Notification center | `events.jsonl` уже содержит все события, трей читает новые строки с байтового курсора; нет истории и центра уведомлений в UI | MG3-013 |

## 3. Этапы A–E → файлы и DoD

Нумерация — §14 документа 3.0 (0…6), буквы — §15. Порядок ниже и есть
strangler-порядок: каждый следующий этап опирается на зелёный parity предыдущего.

| Этап | Фаза §14 | Файлы этого репозитория | DoD (чем проверяем) |
|---|---|---|---|
| **A. Стабилизация 2.6.x** | 0. Hardening | `common.ps1`, `gta-settings-watcher.ps1`, `MG-Helper-Tray.cs`, `diagnose.ps1`, `restore-mg-snapshot.ps1`, `tools\check.ps1`, `tests\MGHelper.Tests.ps1`, `install-gta-watcher.ps1`, `version.json` | `tools\check.ps1` и Pester зелёные; инварианты §7 контракта покрыты: сценарный блок §11r (сессия целиком), health §11s, статические гарантии §11t. Осталось добавить сценарии restart-inside-window и corrupt-state |
| **B. Contracts** | 1. Contracts | новые: `docs\contracts\*.schema.json` (health, state, events, profile, journal), ADR в `docs\adr\`; источник — существующие форматы из [architecture.md](architecture.md) | схема health/state описана и проверяется тестом на реальных файлах 2.6.1; неизвестная major-схема не интерпретируется молча |
| **B2. Core library** | 2. Core | новые: `src\MGHelper.Core\` + `tests\MGHelper.Core.Tests\`; эталон — функции `common.ps1`, перечисленные в MG3-012 | Core тестируется без UI и без PowerShell; parity-набор §4 зелёный на всех сценариях; миграция схем покрыта тестами |
| **C. Watcher** | 3. C# Watcher | `MGCore.cs` (beta-ядро, `coreMode: "csharp"`) → `src\MGHelper.Watcher\`; эталон — `gta-settings-watcher.ps1` | heartbeat/health и IPC по контракту; детект игры по пути/конфигу, а не только по имени; восстановление полного session state (`phase`, `gamePid`, `applied`, `lastApplyUtc`, `sessionStart`); при повреждённом `state.json` — UnknownSession, а не auto-apply; rollback failure не помечается recovered |
| **D. WPF shell** | 4. WPF | новые `src\MGHelper.App\`; функциональный эталон — `MG-Helper.ps1` (пункты 1–15), `MG-Helper-Tray.cs` (статусы, баллуны) | закрытие окна не останавливает watcher; статусы только из health; GUI не пишет settings.xml в обход Core; все пункты меню имеют эквивалент |
| **D2. Графика и профили** | 6. Feature completion | `max-fps.ps1`, `cut-shadows.ps1`, `reset-settings.ps1`, `import-settings.ps1`, `restore-golden-history.ps1`, `profiles.json`, `restore-mg-snapshot.ps1` | diff-preview и подтверждение до записи; неизвестные XML-узлы не теряются (round-trip тест); любое применение транзакционно; откат профиля и восстановление эталона/MG проверены |
| **E. Installer 3.0** | 5. Installer | `install-gta-watcher.ps1`, `uninstall.ps1`, `update-helper.ps1`, `repair.ps1`, `tools\check.ps1` (§10 состав деплоя) | fresh install / upgrade / rollback / uninstall на чистой Windows VM; Data переживает upgrade и обычное удаление; uninstall останавливает watcher и снимает автозапуск; manifest + SHA256 + (при наличии сертификата) подпись |

Зависимости: `A → B → B2 → C`; `D` требует `B2` и `MG3-014`; `E` требует
`MG3-008` и может идти параллельно `D` после `B2`; `D2` — после `D`.

## 4. Strangler-порядок и parity-тесты

Правило: **новый компонент становится основным только когда parity-набор
зелёный**. До этого PS-watcher остаётся default (`coreMode: "ps"`), а C#-ядро —
opt-in; переключение обязано быть обратимым одной настройкой.

Что уже есть и становится основой parity-набора:

| Инструмент | Что делает | Роль в parity |
|---|---|---|
| `_analysis\replay.ps1` | прогоняет **реальные** функции `common.ps1` (`Test-GuardActive`, `Test-AdoptCandidate`, `Test-SameSettings`, `Get-ValidGolden`, `Apply-Golden`) по сценариям A/A2/B/C/D в песочнице `%TEMP%\mg_replay` | decision-level oracle: показывает, что именно решает старая реализация на заданном входе, включая таймлайн (`t+150 s`) и часовой пояс |
| `tools\check.ps1` | функциональные проверки: adopt-матрица (`Test-AdoptCandidate`), guard (`Test-GuardActive`), снапшот round-trip (`Snapshot-MgFiles`), journal-откат, golden-валидация, состав деплоя; сценарный блок §11r (сессия целиком: чужая запись посреди сессии, выход без `allowAdopt`, adopt при `allowAdopt=true`, UTC-round-trip), health §11s, статические гарантии контракта §11t | регрессия PS-реализации; §11r — первый parity-сценарий |
| `tests\MGHelper.Tests.ps1` | Pester 5 на чистые функции (golden key, XML, tri-state compare, config) | то же для CI |

Как из этого получается parity-набор:

1. **Сценарии становятся данными, а не кодом.** Сценарий из `replay.ps1`
   превращается в каталог `tests\parity\scenarios\<name>\`: `config.json`,
   `state.json`, `golden.xml`, `settings.xml`, `timeline.json` (события с
   относительным временем: `t0 apply`, `t+150 overwrite`, `exit`,
   `restart-mid-session`, `gpu-change`). Ожидаемый результат —
   `expected.json`: `{guardActive, adopt, restore, goldenChanged, events[]}`.
2. **Обе реализации читают одни и те же файлы.** PS-реализация — `tools\parity.ps1`
   (уже написан, 21 сценарий из `tools\parity\expected.json`), новая — через Core
   (`-Implementation core`). Сравнивается не текст, а запись решений; расхождение =
   FAIL с diff'ом.
3. **Сценарный блок `tools\check.ps1` §11r — уже написанный первый сценарий.**
   Он прогоняет настоящие функции на файлах в песочнице: чужая запись посреди
   сессии откатывается, выход без `allowAdopt` возвращает эталон, `allowAdopt=true`
   усыновляет правку, сделанную после нашего применения, `Test-AdoptCandidate`
   не срабатывает без применения и без записи после нас, а время из `state.json`
   с локальным смещением сравнивается в UTC. Этого блока не хватало
   (`ANALYSIS` 3.11.5); теперь он переиспользуется parity-раннером, а не
   дублируется. Сценарный блок `11u` закрывает три бывших пробела: перезапуск игры
   внутри окна охраны (окно отсчитывается от нового `sessionStart`), повреждённый
   `state.json` при живой игре (`Read-MgState` → defaults → `UnknownSession`) и
   kill посреди записи (битый `<target>.<pid>.mgtmp` не может стать целью).
   Чего в нём пока нет: kill посреди самого `Apply-Golden` (журнал покрывает
   профили/reset, но не apply) и «диск заполнен во время записи».
4. **`expected.json` уже лежит данными и проверяется на каждом прогоне.**
   `tools\parity\expected.json` (схема 1) описывает 21 сценарий пяти видов:
   `guard`, `adopt`, `golden-source`, `apply`, `compare`, `policy`. `tools\parity.ps1`
   исполняет их против выбранной реализации и возвращает exit 1 при расхождении;
   `tools\check.ps1` (§11x) дополнительно требует, чтобы сценариев было не меньше 20
   и все они сходились. Ожидания снимаются с эталонной реализации, когда инварианты
   §7 контракта проходят; правка `expected.json` — это решение, которое проходит
   ревью, а не «перегенерируем, чтобы позеленело».
5. **Три уровня сравнения:** решение (чистые функции), файл (структурное
   сравнение `settings.xml` и `state.json`), события (`events.jsonl` —
   последовательность имён и `data`). Минимум для переключения — все три.
   Сейчас раннер покрывает решение и файл (`apply` пишет живые файлы и проверяет
   результат); уровень событий появится вместе с C#-ядром, потому что требует
   прогона самого watcher'а, а не одной функции.

Критерий допуска C#-watcher к default (из §4.6 документа 3.0, адаптировано):
parity зелёный на всех сценариях + fault-injection §5 ниже + отдельный релиз,
в котором C#-watcher работал opt-in и не имел откатов по health.

## 5. Fault-injection: что покрыто, чего нет

Сценарии — §13.1 документа 3.0. «Покрыто» = есть код, который это переживает
**и** автоматическая проверка.

| Сценарий | Состояние в 2.6.1 | Чего не хватает |
|---|---|---|
| Оборвать копирование версии после первого файла | частично: `install-gta-watcher.ps1` копирует в staging, проверяет и только потом promotes; сбой до promote оставляет HelperDir нетронутым | promote — пофайловое копирование, kill посреди него может дать смесь версий; нет каталогов версий и указателя, то есть «оборвали» = «повезло/не повезло», а не откат указателя; автотеста нет |
| Убить установщик после распаковки, до переключения active pointer | частично: переключения как такового нет, staging чистится | сам сценарий появится только с `current.json` (этап E) |
| Убить watcher посреди транзакции | да, для journal-операций: `Invoke-OpReconciliation` + проверка `journal: reconciliation rolled the golden back` в `tools\check.ps1` | kill посреди apply/adopt (это не journal-операция) не тестируется |
| Повредить backup: recovery не должен писать ложный success | частично: валидация эталона (`Test-GoldenValid`), честный откат journal, честный uninstall | нет статусов `rollback_failed` / `recovery_required` (MG3-010) |
| Повредить `state.json` при запущенной игре | да: `Read-MgState` на битом/чужом JSON отдаёт defaults, запущенная игра → `UnknownSession`, ни apply, ни adopt; тесты `state:` в `tools\check.ps1` §11u | — |
| Оставить stale health и завершить процесс | да по коду: 15/30 с, `status=stopping`, трей и diagnose; состояния health (свежий/20 с/45 с/`stopping`/битый/нет файла) покрыты тестом `tools\check.ps1` §11s | не покрыты два случая: процесс убит, а health остался свежим (нужен probe PID + `processStartUtc`), и поведение самой иконки |
| Перезапустить игру внутри окна охраны | да: recheck через 3 с + «новая сессия только если записанный PID исчез»; окно от нового `sessionStart` (тест `guard: a relaunched game re-arms the window`) | — |
| Подменить PID / оставить stale READY | частично: health приоритетнее `watcher.ready`, строгий probe командной строки | нет `installationId`, проверки `processStartUtc` у watcher'а (MG3-003/014) |
| Сменить GPU/variant после создания golden | да: `Test-GoldenKeyMatchPure` покрыт Pester и `tools\check.ps1`, SAFE MODE виден в трее и событиях | нет интеграционного теста «сменили GPU → сессия не защищается, но это видно» |
| Диск read-only или заполнен во время backup | частично: locked-источник (`MG-CR-005`) и read-only `settings.xml` обрабатываются; перед копированием `.bin` есть проверка свободного места (копия не начинается, если её нельзя докончить) | нет общего теста «диск заполнен» и нет такой проверки для снапшотов MG/бэкапов эталона |
| Uninstall при живом watcher | частично: кооперативный стоп + точечный kill + честный итог (`MG-E-0501/0502`) | автотеста нет; MG3-017 требует проверки завершения процесса мастером |

## 6. Риски и точки невозврата

**Когда старый PS-watcher ещё можно удалить.** Только при выполнении всех
условий одновременно:

1. parity-набор §4 зелёный на полном списке сценариев, включая сценарный блок
   сессии и все детерминированные fault-injection кейсы;
2. `expected.json` зафиксированы и хранятся в репозитории, то есть PS-код больше
   не нужен как oracle;
3. потребители переведены на новый источник: трей, диагностика, установщик,
   repair не читают `state.json`/`watcher.health.json` PS-формата;
4. миграция Data (v2.x → 3.0) проверена на копии реальной установки, а не
   только на чистой машине.

**Когда удалять уже нельзя** (точки невозврата):

- после удаления PS-реализации и PS-форматов состояния — откат на 2.6.x
  возможен только через резервную копию Data;
- после первой необратимой миграции схемы (`schemaVersion` без обратного
  мигратора) — старые сборки перестанут читать Data;
- после удаления `tools\check.ps1`-сценариев как единственного oracle —
  доказывать эквивалентность станет нечем.

**Что считать регрессом.** Инварианты §7 контракта 2.6.1 — это и есть
определение регресса; к ним добавляются проверки, которые следуют из 3.0:

| № | Инвариант | Как ловится |
|---|---|---|
| 1 | При конфигурации по умолчанию эталон на диске не меняется из-за записи Majestic: ни в окне охраны, ни после него | сценарный тест «чужая запись → эталон не изменился» |
| 2 | При `allowAdopt=true` adopt только если эталон применён нами в этой сессии и файл изменился после нашей записи (время в UTC) | parity-сценарий adopt-матрицы |
| 3 | Охрана не выключается, пока идёт сессия (`guardWindowSec: 0`) и не отключается сменой PID | сценарий «второй процесс/новый PID» |
| 4 | Любой переход в «не защищаю» виден: событие + жёлтый/красный статус | тест: на каждый переход есть событие и статус |
| 5 | `tools\check.ps1` зелёный, включая сценарный блок | CI |

Дополнительно регрессом считается: зелёный трей при выключенной защите;
смешанная версия после обновления; любое изменение эталона без `allowAdopt`;
потеря пользовательских данных при update/uninstall/restore.

**Риски этапов** (из §16 документа 3.0, с поправкой на этот репозиторий):

| Риск | Решение |
|---|---|
| WPF начнёт дублировать файловую логику | GUI вызывает Core через IPC; запись settings.xml — только в Core |
| Два watcher'а одновременно (PS + C#) | named mutex с идентификатором установки на этапе C, до включения C#-ядра по умолчанию |
| Data окажется в AppRoot и потеряется при обновлении | InstallRoot/DataRoot (MG3-008) до первого релиза 3.0 |
| «Тихие» SAFE MODE вернутся в новом ядре | инвариант 4 в parity-наборе как обязательный тест, а не как пожелание |
| Beta C#-ядро (`MGCore.cs`) примут за готовое | до parity оно остаётся opt-in (`coreMode: "csharp"`), default — `ps` |
| Смена формата схем без обратного мигратора | мигратор v1→v2→v3 с тестами до смены формата; неизвестную major-схему не интерпретировать |

## 7. Объём и последовательность

| Этап | Объём | Зависит от | Замечание |
|---|---|---|---|
| A. Стабилизация 2.6.x | S | — | основной код приведён к контракту; остались отдельные сценарии тестов и разрывы из §5 |
| B. Contracts + схемы | S | A | в основном документирование существующих форматов + JSON Schema |
| B2. Core library | L | B | перенос чистых функций + parity; самый дорогой по тестам |
| C. C# Watcher | L | B2 | детект игры, session state, recovery, IPC; PS-версия остаётся oracle |
| D. WPF shell | L | B2, MG3-014 | 15 пунктов меню + статусы трея как эталон объёма |
| D2. Графика и профили | M | D | diff-preview, транзакции, restore center |
| E. Installer 3.0 | M | B2, MG3-008 | версии/указатель, миграция, uninstall с выбором судьбы Data |
| F. Feature completion (MG3-015/016/020) | M | D | профили, диагностика, уведомления |

Последовательность: `A → B → B2 → C → D → D2 → E`; `E` можно начинать
параллельно `D` после `B2`, `F` — параллельно `E` после `D`.

Ближайшие шаги, которые не требуют нового кода на C#:

1. сценарии, которых нет в §11r: перезапуск игры внутри окна охраны,
   повреждённый `state.json` при живой игре, kill посреди записи эталона;
2. parity-раннер: `tests\parity\` + перевод §11r и `_analysis\replay.ps1` в
   данные (входы и `expected.json`);
3. `docs\contracts\` со схемами health/state/events (MG3-011) — на существующих
   форматах, без изменения поведения;
4. InstallRoot/DataRoot (MG3-008) — до того, как появится первый установщик 3.0.