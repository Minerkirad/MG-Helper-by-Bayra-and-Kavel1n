# Contributing

## Окружение
- Windows 10/11, Windows PowerShell 5.1 (`powershell.exe`). Тесты Windows-only.
- Git: работаем с одним `main`; релизы — теги `vX.Y.Z` + ZIP-ассет.

## Перед каждым коммитом
```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
```
ALL GREEN или коммит не уезжает. Харнесс проверяет: синтаксис всех ps1,
дубли функций, атомарные записи, golden-валидацию, adopt-матрицу, .bin-страховку,
снапшот round-trip, версии (common.ps1 == version.json), BOM, состав деплоя.

## Правила
- PS 5.1-совместимость: `[IO.File]::Replace` — только с `[NullString]::Value`;
  `Split-Path -LiteralPath` не сочетать с `-Parent`/`-Leaf` (ambiguous set);
  `Copy-Item`/`Remove-Item` — в try/catch приcaller-скопе EAP=Stop;
  кириллические скрипты — UTF-8 **с BOM**.
- Ни одна автоматическая операция не удаляет пользовательские данные без бэкапа
  и верификации (см. docs/architecture.md).
- Многофайловые операции — через operation journal.
- Новые [!]-сообщения получают код `MG-E-XXXX` (docs/errors.md).

## Релиз
1. Bump `$script:Version` в common.ps1 + version.json (синхронно!).
2. `tools\check.ps1` → ALL GREEN.
3. ZIP из корня пакета (только нужные файлы), SHA256.
4. GitHub Release: тег + ZIP + SHA256 в описании.
5. e2e-проверка: скачать ZIP, распаковать, установить на чистой машине/VM.

## Стиль
- Комментарии на английском в коде, пользовательские сообщения — на русском.
- Общий код — в common.ps1; скрипты — тонкие обвязки.
