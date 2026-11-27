// MG Helper tray - by Bayra & Kavel1n
// net48 WinForms NotifyIcon (ROADMAP 5.1). Status model per CONTRACT-2.6.1 §5:
// the ONLY source of truth is watcher.health.json (status + freshness of
// lastHeartbeatUtc). The 2.6.0 rule "<watcher.ready exists> or <any powershell
// window is alive>" is gone: the marker is not age-checked and is deleted only on
// a normal exit, so a dead watcher was reported green (ANALYSIS 3.8). The legacy
// watcher.ready marker and a STRICT watcher process probe (command line contains
// gta-settings-watcher) are extra evidence only, used when the health file is
// absent - they never turn a dead watcher green.
// Balloons: every NEW line of events.jsonl is handled by byte offset, so paired
// and rapid events are no longer lost (ANALYSIS 3.7/3.8). The offset is primed at
// the CURRENT end of file, so a tray start never replays the history (no balloon
// spam) while anything the watcher writes afterwards is handled on the first poll.
// Compiled at install from this readable source.
using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Diagnostics;

static class Program
{
    // ---- CONTRACT-2.6.1 §2/§5 status model ----
    const double HeartbeatFreshSec = 15.0;   // <= fresh   -> Healthy
    const double HeartbeatStaleSec = 30.0;   // 15-30      -> Degraded, > 30 -> Stopped
    const int WatcherProbeCacheSec = 30;     // CIM probe is expensive; only used for a missing health file
    const int EventTailBytes = 65536;        // how far back the SAFE MODE seed looks in events.jsonl

    enum Health { Healthy, Degraded, Stopped, Unknown }

    static string helperDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MG_Helper");
    static NotifyIcon tray;
    static Icon iconGray, iconGreen, iconYellow, iconRed;

    // events.jsonl cursor: byte offset of the already-seen region (not a line text -
    // that is what dropped paired events in 2.6.0). Primed at EOF on start.
    static long eventOffset = 0L;
    // golden.mismatch / session.unknown seen and not resolved since: SAFE MODE
    static bool safeModeFromEvents = false;
    // cached result of the STRICT watcher process probe (command-line match only)
    static bool watcherProbeAlive = false;
    static DateTime watcherProbeAtUtc = DateTime.MinValue;

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var menu = new ContextMenuStrip();
        menu.Items.Add("Открыть меню MG Helper", null, (s, e) => Run("MG-Helper.bat"));
        menu.Items.Add("Диагностика + отчёт", null, (s, e) => RunScript("diagnose.ps1"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("MAX FPS", null, (s, e) => RunScript("max-fps.ps1"));
        menu.Items.Add("Отключить тени", null, (s, e) => RunScript("cut-shadows.ps1"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Новый эталон (сменилась игра/GPU)", null, (s, e) => RunScript("reset-settings.ps1"));
        menu.Items.Add("Восстановить MG", null, (s, e) => RunScript("restore-mg-snapshot.ps1"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Проверить обновления", null, (s, e) => RunScript("update-helper.ps1"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Выход (иконка)", null, (s, e) =>
        {
            // REVIEW: намеренный выход - пишем флаг, чтобы watcher не перезапускал трей.
            // Флаг НЕ удаляется при старте трея: его снимает установщик/Repair
            // (CONTRACT-2.6.1: иначе упавший трей никогда не поднимется).
            try { File.WriteAllText(Path.Combine(helperDir, "tray_exit.flag"), DateTime.Now.ToString("o")); } catch { }
            tray.Visible = false;
            Application.Exit();
        });

        // иконки создаются ОДИН раз на состояние (GDI-хэндлы не пересоздаются
        // каждый опрос - пересоздание каждые 5 с течёт по GDI-хэндлам и убивает
        // трей через ~14 часов; найдено по падению на машине пользователя)
        iconGray = MakeIcon(Color.Gray);
        iconGreen = MakeIcon(Color.Green);
        iconYellow = MakeIcon(Color.Gold);
        iconRed = MakeIcon(Color.Red);

        SeedSafeMode();       // is an unresolved golden.mismatch/session.unknown in the event tail?
        PrimeEventCursor();   // start at the current EOF: no history replay, no skipped first poll

        tray = new NotifyIcon
        {
            Icon = iconGray,
            Text = "MG Helper - запуск...",
            ContextMenuStrip = menu,
            Visible = true
        };

        var timer = new Timer { Interval = 5000 };
        timer.Tick += (s, e) => Poll();
        timer.Start();
        Poll();

        Application.Run();
        timer.Dispose();
        if (tray != null) tray.Visible = false;
    }

    static void Poll()
    {
        // каждая итерация обёрнута: любой сбой опроса не должен убить трей
        try
        {
            PollInner();
        }
        catch { }
    }

    static void PollInner()
    {
        string phase; double? ageSec; string detail;
        Health health = EvaluateHealth(out phase, out ageSec, out detail);
        bool safeMode = IsSafeMode(phase);

        Color color;
        string tip;
        if (health == Health.Stopped)
        {
            // красный: health-файл есть и говорит "мёртв", или строгий признак процесса
            // есть, а health-файла нет. Серый: признаков watcher'а нет вовсе.
            bool processEvidence = false;
            bool noHealthFile = detail != null && detail.StartsWith("нет watcher.health.json", StringComparison.Ordinal);
            if (noHealthFile && ageSec == null && phase == null) processEvidence = WatcherProcessAlive();
            if (processEvidence || !noHealthFile)
            {
                color = Color.Red;
                tip = "MG Helper - WATCHER НЕ РАБОТАЕТ (меню [9] Repair)";
            }
            else
            {
                color = Color.Gray;
                tip = "MG Helper - Watcher не установлен или не запускался";
            }
        }
        else if (health == Health.Unknown)
        {
            color = Color.Gold;
            tip = "MG Helper - Статус неизвестен (watcher.health.json нечитаем)";
        }
        else if (safeMode)
        {
            // жёлтый даже при свежем heartbeat: защита выключена (CONTRACT-2.6.1 §5)
            color = Color.Gold;
            tip = "MG Helper - SAFE MODE: защита выключена (меню [11])";
        }
        else if (health == Health.Degraded)
        {
            color = Color.Gold;
            // status=starting is a Degraded status, not a phase name
            if (detail != null && detail.StartsWith("status=starting", StringComparison.Ordinal))
                tip = "MG Helper - Watcher запускается...";
            else if (ageSec != null)
                tip = string.Format(CultureInfo.InvariantCulture, "MG Helper - Watcher не отвечает (heartbeat {0:N0} с)", ageSec.Value);
            else
                tip = "MG Helper - Watcher не отвечает";
        }
        else
        {
            color = Color.Green;
            tip = string.Equals(phase, "InGame", StringComparison.OrdinalIgnoreCase)
                ? "MG Helper - Защищено (игра запущена)"
                : "MG Helper - Защищено (ожидание)";
        }

        try
        {
            // иконка переиспользуется из кэша (4 состояния) - GDI-хэндлы не текут
            if (color == Color.Red) tray.Icon = iconRed;
            else if (color == Color.Gold) tray.Icon = iconYellow;
            else if (color == Color.Gray) tray.Icon = iconGray;
            else tray.Icon = iconGreen;
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        }
        catch { }

        CheckEvents();
    }

    // ---------------- watcher.health.json (CONTRACT-2.6.1 §2/§5) ----------------

    static Health EvaluateHealth(out string phase, out double? ageSec, out string detail)
    {
        phase = null;
        ageSec = null;
        detail = null;
        string hp = Path.Combine(helperDir, "watcher.health.json");
        if (!File.Exists(hp))
        {
            // CONTRACT §5: no file -> Stopped (the watcher is not running at all).
            // The legacy watcher.ready marker is NOT the status source any more.
            detail = "нет watcher.health.json";
            if (File.Exists(Path.Combine(helperDir, "watcher.ready"))) detail = detail + " (есть только watcher.ready)";
            phase = LegacyPhaseFromState();
            return Health.Stopped;
        }

        string json;
        try { json = File.ReadAllText(hp, Encoding.UTF8); }
        catch { detail = "файл не читается"; return Health.Unknown; }

        json = (json == null) ? "" : json.Trim();
        int lb = json.IndexOf('{');
        int rb = json.LastIndexOf('}');
        if (lb < 0 || rb < lb) { detail = "битый JSON"; return Health.Unknown; }
        json = json.Substring(lb, rb - lb + 1);

        string status = JsonField(json, "status");
        phase = JsonField(json, "phase");
        if (string.IsNullOrEmpty(status)) { detail = "нет поля status"; return Health.Unknown; }
        if (string.Equals(status, "stopping", StringComparison.OrdinalIgnoreCase)) { detail = "status=stopping"; return Health.Stopped; }
        if (string.Equals(status, "starting", StringComparison.OrdinalIgnoreCase)) { detail = "status=starting"; return Health.Degraded; }
        if (!string.Equals(status, "running", StringComparison.OrdinalIgnoreCase)) { detail = "status=" + status; return Health.Unknown; }

        ageSec = HeartbeatAgeSec(json);
        if (ageSec == null) { detail = "нет lastHeartbeatUtc"; return Health.Unknown; }
        if (ageSec.Value > HeartbeatStaleSec) { detail = string.Format(CultureInfo.InvariantCulture, "heartbeat {0:N0} с", ageSec.Value); return Health.Stopped; }
        if (ageSec.Value > HeartbeatFreshSec) { detail = string.Format(CultureInfo.InvariantCulture, "heartbeat {0:N0} с", ageSec.Value); return Health.Degraded; }
        detail = string.Format(CultureInfo.InvariantCulture, "heartbeat {0:N0} с", ageSec.Value);
        return Health.Healthy;
    }

    static double? HeartbeatAgeSec(string json)
    {
        string s = JsonField(json, "lastHeartbeatUtc");
        if (string.IsNullOrEmpty(s)) return null;
        DateTime dt;
        if (!DateTime.TryParse(s, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out dt)) return null;
        double age = (DateTime.UtcNow - dt).TotalSeconds;
        if (age < 0) age = 0;   // a clock jump backwards must not look like a stale watcher
        return age;
    }

    // minimal JSON reader for the flat one-line health object: no JSON assembly is
    // referenced by the installer's Add-Type call, so no serializer is available
    static string JsonField(string json, string key)
    {
        if (string.IsNullOrEmpty(json)) return null;
        int i = json.IndexOf("\"" + key + "\"", StringComparison.Ordinal);
        if (i < 0) return null;
        i = json.IndexOf(':', i);
        if (i < 0) return null;
        i++;
        while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
        if (i >= json.Length || json[i] == 'n') return null;   // null
        if (json[i] == '"')
        {
            // walk to the matching UNESCAPED quote and decode the value: config.json
            // stores Windows paths with doubled backslashes
            var sb = new StringBuilder();
            for (int k = i + 1; k < json.Length; k++)
            {
                char c = json[k];
                if (c == '\\' && k + 1 < json.Length) { sb.Append(c); sb.Append(json[++k]); continue; }
                if (c == '"') return Unescape(sb.ToString());
                sb.Append(c);
            }
            return null;
        }
        int j = i;
        while (j < json.Length && json[j] != ',' && json[j] != '}') j++;
        return json.Substring(i, j - i).Trim();
    }

    static string Unescape(string s)
    {
        if (s.IndexOf('\\') < 0) return s;
        var sb = new StringBuilder(s.Length);
        for (int k = 0; k < s.Length; k++)
        {
            char c = s[k];
            if (c != '\\' || k + 1 >= s.Length) { sb.Append(c); continue; }
            char n = s[++k];
            switch (n)
            {
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                case 'b': sb.Append('\b'); break;
                case 'f': sb.Append('\f'); break;
                case '"': sb.Append('"'); break;
                case '\\': sb.Append('\\'); break;
                case '/': sb.Append('/'); break;
                case 'u':
                    if (k + 4 < s.Length)
                    {
                        int code;
                        if (int.TryParse(s.Substring(k + 1, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                        {
                            sb.Append((char)code);
                            k += 4;
                            break;
                        }
                    }
                    sb.Append('u');
                    break;
                default: sb.Append(n); break;
            }
        }
        return sb.ToString();
    }

    static string LegacyPhaseFromState()
    {
        // fallback evidence only: health.json is authoritative when it exists
        try
        {
            string st = File.ReadAllText(Path.Combine(helperDir, "state.json"));
            if (st.Contains("\"UnknownSession\"")) return "UnknownSession";
            if (st.Contains("\"InGame\"")) return "InGame";
        }
        catch { }
        return null;
    }

    static bool IsSafeMode(string healthPhase)
    {
        if (string.Equals(healthPhase, "UnknownSession", StringComparison.OrdinalIgnoreCase)) return true;
        if (safeModeFromEvents) return true;
        // CONTRACT-2.6.1 §5: a golden-key mismatch is SAFE MODE even with a fresh
        // heartbeat. The watcher reports it as golden.mismatch (seed/tail events),
        // and the GPU half is re-checked here so a rotated event log cannot hide it.
        if (GoldenKeyMismatch()) return true;
        if (string.IsNullOrEmpty(healthPhase))
            return string.Equals(LegacyPhaseFromState(), "UnknownSession", StringComparison.OrdinalIgnoreCase);
        return false;
    }

    static bool GoldenKeyMismatch()
    {
        // Mirrors Test-GoldenKeyMatchPure conservatism: only a value that is
        // present in BOTH golden_key.json and the live settings may be a mismatch;
        // anything unreadable means "cannot determine" (no yellow, no false alarm).
        // The game-variant half is covered by the watcher's golden.mismatch event
        // (it re-emits it at every start while the key does not match).
        try
        {
            string kf = Path.Combine(helperDir, "golden_key.json");
            if (!File.Exists(kf)) return false;
            string storedGpu = JsonField(File.ReadAllText(kf, Encoding.UTF8), "gpu");
            if (string.IsNullOrEmpty(storedGpu)) return false;

            string sx = SettingsXmlPath();
            if (string.IsNullOrEmpty(sx) || !File.Exists(sx)) return false;
            string raw = File.ReadAllText(sx, Encoding.UTF8);
            Match m = Regex.Match(raw, "<VideoCardDescription>([^<]+)</VideoCardDescription>");
            if (!m.Success) return false;
            string curGpu = m.Groups[1].Value;
            return !string.IsNullOrEmpty(curGpu) && !string.Equals(curGpu, storedGpu, StringComparison.Ordinal);
        }
        catch { return false; }
    }

    static string SettingsXmlPath()
    {
        try
        {
            string cf = Path.Combine(helperDir, "config.json");
            if (!File.Exists(cf)) return null;
            string p = JsonField(File.ReadAllText(cf, Encoding.UTF8), "settingsXml");
            return string.IsNullOrEmpty(p) ? null : p;
        }
        catch { return null; }
    }

    // ---------------- events.jsonl ----------------

    static void SeedSafeMode()
    {
        // SAFE MODE must also be visible right after a tray start (the old code
        // showed the very first mismatch balloon only once - CONTRACT §5).
        string last = null;
        try
        {
            foreach (var raw in TailLines(Path.Combine(helperDir, "events.jsonl"), EventTailBytes))
            {
                string line = raw.Trim();
                if (line.Length == 0) continue;
                last = MatchedEventName(line, "golden.mismatch") ? "golden.mismatch"
                     : MatchedEventName(line, "session.unknown") ? "session.unknown"
                     : IsSafeModeResolvingEvent(line) ? "resolved"
                     : last;
            }
        }
        catch { }
        if (last == "golden.mismatch" || last == "session.unknown") safeModeFromEvents = true;
    }

    static string[] TailLines(string path, int maxBytes)
    {
        if (!File.Exists(path)) return new string[0];
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            long len = fs.Length;
            long start = len > maxBytes ? len - maxBytes : 0;
            fs.Seek(start, SeekOrigin.Begin);
            var buf = new byte[len - start];
            int read = 0;
            while (read < buf.Length)
            {
                int n = fs.Read(buf, read, buf.Length - read);
                if (n <= 0) break;
                read += n;
            }
            string txt = new UTF8Encoding(false).GetString(buf, 0, read);
            if (start > 0)   // the first line is cut by the tail window - drop it
            {
                int nl = txt.IndexOf('\n');
                if (nl >= 0) txt = txt.Substring(nl + 1);
            }
            return txt.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
        }
    }

    static bool IsSafeModeResolvingEvent(string line)
    {
        // A mismatch is an in-memory decision of ONE watcher process: it is
        // re-evaluated at the next game start, so a watcher (re)start, a
        // successful apply and the end of an unprotected session all mean
        // "this is no longer a current fact".
        return MatchedEventName(line, "golden.applied")
            || MatchedEventName(line, "adopt.accepted")
            || MatchedEventName(line, "watcher.start")
            || MatchedEventName(line, "watcher.ready")
            || MatchedEventName(line, "session.end");
    }

    static bool MatchedEventName(string line, string name)
    {
        string ev = JsonField(line, "event");
        if (!string.IsNullOrEmpty(ev)) return string.Equals(ev, name, StringComparison.Ordinal);
        // legacy fallback: a line without parseable "event" is matched by text
        return line.Contains("\"" + name + "\"") || line.Contains(":" + name);
    }

    static string EventName(string line)
    {
        string ev = JsonField(line, "event");
        if (!string.IsNullOrEmpty(ev)) return ev;
        string[] known = new string[] { "golden.applied", "adopt.accepted", "apply.failed", "session.unknown",
            "session.start", "session.end", "guard.window_expired", "guard.rollback",
            "insurance.restored", "insurance.risk", "golden.mismatch", "watcher.stop", "watcher.start",
            "watcher.ready", "tray.restart", "auto-update.start", "bins.archived", "error" };
        foreach (var k in known) if (MatchedEventName(line, k)) return k;
        return null;
    }

    static void TrackSafeMode(string name)
    {
        if (name == "golden.mismatch" || name == "session.unknown") safeModeFromEvents = true;
        else if (name == "golden.applied" || name == "adopt.accepted" || name == "watcher.start"
            || name == "watcher.ready" || name == "session.end")
            safeModeFromEvents = false;
    }

    static void PrimeEventCursor()
    {
        // History must not balloon on every tray start, but new events must not be
        // skipped either: start at the CURRENT size and read everything appended
        // after it - already on the very first poll, not one tick later.
        eventOffset = CurrentEventsLength();
    }

    static long CurrentEventsLength()
    {
        try
        {
            string ef = Path.Combine(helperDir, "events.jsonl");
            return File.Exists(ef) ? new FileInfo(ef).Length : 0L;
        }
        catch { return 0L; }
    }

    static void CheckEvents()
    {
        string ef = Path.Combine(helperDir, "events.jsonl");
        string chunk;
        try
        {
            if (!File.Exists(ef)) return;
            long len = new FileInfo(ef).Length;
            if (len < eventOffset) eventOffset = 0;   // rotated/truncated -> read the new file from the start
            if (len == eventOffset) return;

            using (var fs = new FileStream(ef, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Seek(eventOffset, SeekOrigin.Begin);
                int want = (int)Math.Min(len - eventOffset, 1 << 20);
                var buf = new byte[want];
                int read = 0;
                while (read < want)
                {
                    int n = fs.Read(buf, read, want - read);
                    if (n <= 0) break;
                    read += n;
                }
                if (read <= 0) return;
                int lastNl = -1;
                for (int i = read - 1; i >= 0; i--) { if (buf[i] == 0x0A) { lastNl = i; break; } }
                if (lastNl < 0) return;   // only a half-written line so far: take it on the next poll
                eventOffset += lastNl + 1;
                chunk = new UTF8Encoding(false).GetString(buf, 0, lastNl + 1);
            }
        }
        catch { return; }

        foreach (var raw in chunk.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            string line = raw.Trim();
            if (line.Length == 0) continue;
            string name = EventName(line);
            TrackSafeMode(name);
            string msg; ToolTipIcon ico;
            if (Balloon(name, line, out msg, out ico)) ShowBalloon(msg, ico);
        }
    }

    static bool Balloon(string name, string line, out string msg, out ToolTipIcon ico)
    {
        msg = null;
        ico = ToolTipIcon.Info;
        string data = Truncate(JsonField(line, "data"), 120);
        switch (name)
        {
            case "golden.applied":
                msg = "Настройки графики применены";
                break;
            case "adopt.accepted":
                msg = "Изменения в игре сохранены как новый эталон";
                break;
            case "apply.failed":
                msg = "НЕ УДАЛОСЬ записать эталон: " + (string.IsNullOrEmpty(data) ? "причина в логе" : data);
                ico = ToolTipIcon.Error;
                break;
            case "session.unknown":
                msg = "SAFE MODE: сессия не защищается (UnknownSession)";
                ico = ToolTipIcon.Warning;
                break;
            case "guard.window_expired":
                msg = "Окно охраны истекло - чужие перезаписи больше не откатываются";
                ico = ToolTipIcon.Warning;
                break;
            case "guard.rollback":
                msg = "Чужая перезапись настроек откачена";
                ico = ToolTipIcon.Warning;
                break;
            case "insurance.restored":
                msg = "Бэкапы .bin возвращены лаунчеру";
                break;
            case "insurance.risk":
                msg = "Риск ошибки 1002 при следующем запуске Majestic!";
                ico = ToolTipIcon.Error;
                break;
            case "golden.mismatch":
                msg = "Сменилась игра/GPU - создай новый эталон (меню [11])";
                ico = ToolTipIcon.Warning;
                break;
            case "bins.archived":
                msg = "Архив .bin обновлён";
                break;
            case "watcher.start":
                msg = "Watcher запущен";
                break;
            case "tray.restart":
                msg = "Иконка MG Helper перезапущена";
                break;
            case "auto-update.start":
                msg = "Запущено авто-обновление" + (string.IsNullOrEmpty(data) ? "" : ": " + data);
                break;
            case "error":
                msg = "Ошибка в watcher - см. диагностику";
                ico = ToolTipIcon.Error;
                break;
            default:
                // insurance.* without a dedicated message: still visible, never silent
                if (name != null && name.StartsWith("insurance.", StringComparison.Ordinal))
                {
                    msg = "Страховка .bin: подробности в диагностике";
                    break;
                }
                return false;
        }
        return true;
    }

    static void ShowBalloon(string msg, ToolTipIcon ico)
    {
        try
        {
            tray.BalloonTipTitle = "MG Helper";
            tray.BalloonTipText = msg;
            tray.BalloonTipIcon = ico;
            tray.ShowBalloonTip(5000);
        }
        catch { }
    }

    static string Truncate(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return s;
        return s.Length > max ? s.Substring(0, max) : s;
    }

    // extra evidence only (never the status decision): STRICT command-line match,
    // the 2.6.0 "any powershell with a window title" heuristic is deliberately gone
    static bool WatcherProcessAlive()
    {
        if ((DateTime.UtcNow - watcherProbeAtUtc).TotalSeconds < WatcherProbeCacheSec) return watcherProbeAlive;
        watcherProbeAtUtc = DateTime.UtcNow;
        watcherProbeAlive = false;
        try
        {
            foreach (var p in Process.GetProcessesByName("powershell"))
                if (IsWatcherCmdline(p.Id)) { watcherProbeAlive = true; break; }
            if (!watcherProbeAlive)
                foreach (var p in Process.GetProcessesByName("pwsh"))
                    if (IsWatcherCmdline(p.Id)) { watcherProbeAlive = true; break; }
        }
        catch { }
        return watcherProbeAlive;
    }

    static bool IsWatcherCmdline(int pid)
    {
        try
        {
            using (var searcher = new System.Management.ManagementObjectSearcher(
                "SELECT CommandLine FROM Win32_Process WHERE ProcessId = " + pid))
                foreach (var o in searcher.Get())
                    return ((o["CommandLine"] as string) ?? "").Contains("gta-settings-watcher");
        }
        catch { }
        return false;
    }

    static Icon MakeIcon(Color c)
    {
        using (var bmp = new Bitmap(16, 16))
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            using (var b = new SolidBrush(c)) g.FillEllipse(b, 1, 1, 14, 14);
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    static void Run(string file)
    {
        try { Process.Start(new ProcessStartInfo("cmd.exe", "/c \"\"" + Path.Combine(helperDir, file) + "\"\"") { CreateNoWindow = false }); } catch { }
    }

    static void RunScript(string file)
    {
        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(helperDir, file) + "\"")
            { CreateNoWindow = false, UseShellExecute = false };
            Process.Start(psi);
        }
        catch { }
    }
}
