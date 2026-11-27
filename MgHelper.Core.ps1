# ============================================================
#  MgHelper.Core.ps1 - чистые решения MG Helper (3.0, этап 3)
#  by Bayra & Kavel1n
#
#  Здесь только функции "входы -> выходы": никаких процессов, реестра и сети.
#  Это эталон поведения для C#-ядра (docs/adr/ADR-001): parity-раннер гоняет
#  один и тот же expected.json по этому файлу и по MGCore.exe.
#  Файл обязан быть UTF-8 с BOM (PS 5.1 иначе читает кириллицу как ANSI).
#  Подключается dot-source из common.ps1 - расширение .ps1, не .psm1: в PS 5.1
#  dot-source .psm1 уводит функции в область модуля, и вызывающий их не видит.
# ============================================================

function Update-MgConfigPolicy {
    # 2.6.1: миграция политики. В 2.5/2.6 config.json целиком писал установщик,
    # поэтому onExit='adopt' и guardWindowSec=120 - ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ, а не
    # выбор пользователя. Политика: эталон при выходе восстанавливается
    # (allowAdopt=false), охрана идёт всю сессию (guardWindowSec=0).
    # Версии:
    #   <2  - установки 2.5/2.6 (ключа cfgVersion нет);
    #   2   - первый билд 2.6.1: гейт сравнивал дефолт с дефолтом и не мигрировал,
    #         но cfgVersion=2 уже записал - такие конфиги лечим здесь;
    #   >=3 - миграция выполнена, значения не трогаем (это выбор пользователя).
    param($Config)
    try {
        $v = 0
        if ($null -ne $Config.cfgVersion) { $v = [int]$Config.cfgVersion }
        if ($v -ge 3) { return $false }
        if ($null -eq $Config.allowAdopt) { $Config.allowAdopt = $false }
        if ([int]$Config.guardWindowSec -eq 120) { $Config.guardWindowSec = 0 }
        $Config.cfgVersion = 3
        # $true всегда: даже когда значения уже верные, cfgVersion надо записать,
        # иначе миграция будет пересчитываться на каждом старте
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------
# state.json: устойчивое чтение (fault-injection: битый/чужой state)
# Битый JSON не должен ронять watcher и не должен считаться доверенным
# состоянием: возвращаем defaults, а решение "safe mode" принимает watcher.
# ------------------------------------------------------------
function Get-DefaultState {
    return @{ schema = 2; phase = 'Idle'; gamePid = $null; sessionStart = $null; guardRollbacks = 0
              restarts = 0; applied = $false; lastApplyUtc = $null; gamePath = $null }
}

function Read-MgState {
    param([string]$Path)
    $default = Get-DefaultState
    if (-not (Test-Path -LiteralPath $Path)) { return $default }
    try {
        $loaded = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        if (-not $loaded -or -not $loaded.phase) { return $default }
        if ([string]$loaded.phase -notin @('Idle', 'InGame', 'UnknownSession')) { return $default }
        # schema 1 had sessionReapplied - deliberately dropped: it silently killed adopt
        return @{ schema = 2; phase = [string]$loaded.phase; gamePid = $loaded.gamePid
                  sessionStart = $loaded.sessionStart; guardRollbacks = [int]$loaded.guardRollbacks
                  restarts = [int]$loaded.restarts; applied = [bool]$loaded.applied
                  lastApplyUtc = $loaded.lastApplyUtc
                  # MG-CR-014: путь exe нужен takeover-проверке; без него она
                  # пропускается и PID-reuse снова неотличим от своей игры
                  gamePath = $loaded.gamePath }
    } catch { return $default }
}

function ConvertTo-UtcTime {
    # 2.6.1: ЛЮБОЕ время из state.json перед сравнением с mtime приводится к UTC.
    # Без этого [datetime] разбирает "…+03:00" как Local и сравнивает локальные
    # тики с UTC-тиками Get-FileMtimeUtc: после перезапуска watcher'а
    # "файл изменился после нас" становилось всегда ложным (adopt молча отключался).
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        $d = [datetime]$Value
        if ($d.Kind -eq [System.DateTimeKind]::Unspecified) {
            $d = [datetime]::SpecifyKind($d, [System.DateTimeKind]::Local)
        }
        return $d.ToUniversalTime()
    } catch { return $null }
}

function Test-GuardActive {
    # 2.6.1: охрана идёт ВСЮ сессию (WindowSec <= 0). Окно в 120 с было главной
    # дырой: перезапись, пришедшая позже, не откатывалась и на выходе уходила в эталон.
    # WindowSec > 0 - старое поведение (только первые N секунд). Время - в UTC:
    # SessionStart может быть прочитан из state.json (Local) - см. ConvertTo-UtcTime.
    param($SessionStart, [int]$WindowSec, [bool]$GuardEnabled, [bool]$GameRunning)
    if (-not $GuardEnabled -or -not $GameRunning -or -not $SessionStart) { return $false }
    $start = ConvertTo-UtcTime $SessionStart
    if (-not $start) { return $false }
    if ($WindowSec -le 0) { return $true }
    return (((Get-Date).ToUniversalTime() - $start).TotalSeconds -lt $WindowSec)
}

function Test-AdoptCandidate {
    # pure decision: may the on-disk settings become the new golden?
    # $Same is the tri-state result of Test-SameSettings.
    # $ChangedAfterUs: сравнение mtime и lastApplyUtc должно быть в UTC.
    # $AllowAdopt: 2.6.1 - adopt выполняет ТОЛЬКО config "allowAdopt": true
    #   (ключ onExit устарел). Без него эталон при выходе восстанавливается,
    #   как в первой версии, и чужая перезапись не может стать эталоном.
    # $AppliedThisSession: WE must have applied the golden at least once this
    # session. Otherwise $lastApplyUtc is MinValue, "changed after us" is always
    # true, and a Majestic overwrite could be adopted as the user's choice.
    param([bool]$ChangedAfterUs, [bool]$AllowAdopt, $Same, [bool]$AppliedThisSession)
    return ($AllowAdopt -and $AppliedThisSession -and $ChangedAfterUs -and ($Same -eq $false))
}

# ------------------------------------------------------------
# vanilla bins: ensure present in the launcher backup dir
# (safety net against the error-1002 stuck state)
# ------------------------------------------------------------
# ------------------------------------------------------------
# ROADMAP 2.3: per-variant / per-GPU golden key. The golden belongs to one
# game variant (GTA V / Enhanced) + one video card; on a mismatch the watcher
# refuses to auto-apply/adopt and offers the user a fresh Reset instead.
# ------------------------------------------------------------
function Test-GoldenKeyMatchPure {
    # pure tri-state decision (unit-tested):
    #   $true  - match (or nothing contradicts)
    #   $false - variant or GPU changed since the key was recorded
    #   $null  - cannot determine (no key / nothing readable) - be conservative, treat as match
    param([string]$StoredVariant, [string]$StoredGpu, [string]$CurVariant, [string]$CurGpu)
    if (-not $StoredVariant -and -not $StoredGpu) { return $null }
    if (-not $CurVariant -and -not $CurGpu) { return $null }
    if ($StoredVariant -and $CurVariant -and ($StoredVariant -ne $CurVariant)) { return $false }
    if ($StoredGpu -and $CurGpu -and ($StoredGpu -ne $CurGpu)) { return $false }
    return $true
}

# ------------------------------------------------------------
# ROADMAP 5.3: diff-preview - show "key: old -> new" BEFORE destructive ops
# ------------------------------------------------------------
function Get-SettingsKeyValues {
    # key -> value map of a settings.xml TEXT (see unit tests in tools/check.ps1)
    param([string]$XmlText)
    $res = @{}
    foreach ($m in [regex]::Matches($XmlText, '<(\w+) value="([^"]*)"')) { $res[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $res
}

