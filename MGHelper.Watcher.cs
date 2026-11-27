// ============================================================
//  MGHelper.Watcher.cs - C# watcher for MG Helper 3.0 (stage 5b)
//  by Bayra & Kavel1n
//
//  Same loop as gta-settings-watcher.ps1, but every decision comes from MgCore
//  (CoreDecisions.cs) and the command surface is the Named Pipe from HelperPipe.cs.
//  Files stay the contract: config.json, state.json, events.jsonl,
//  watcher.health.json, watcher.ready, settings.golden.xml, settings.before_apply.bak,
//  stop.request / reload.request / apply.request.
//
//  Built with Add-Type (CodeDom, C# 5, net48) together with HelperPipe.cs and with
//  CoreDecisions.cs compiled as MgCore.exe. DataRoot is MG_HELPER_DIR when set
//  (tests), otherwise %LOCALAPPDATA%\MG_Helper.
// ============================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class MgWatcherProgram
{
    private static string dataDir;
    private static string configPath;
    private static string settingsXml;
    private static string goldenPath;
    private static string beforeApplyPath;
    private static string statePath;
    private static string eventsPath;
    private static string healthPath;
    private static string readyPath;
    private static string logPath;
    private static string versionPath;
    private static string keyPath;
    private static Dictionary<string, object> config;

    private static string phase = "Idle";
    private static int? gamePid;
    private static string gamePath;
    private static DateTime? sessionStart;
    private static DateTime lastApplyUtc = DateTime.MinValue;
    private static bool appliedThisSession;
    private static int guardRollbacks;
    private static bool goldenMismatch;
    private static DateTime lastGuardCheck = DateTime.MinValue;
    private static int healthSequence;
    private static bool wasRunning;
    private static Mutex mutex;
    private static EventWaitHandle stopEvent;
    private static string pipeName;

    public static int Main(string[] args)
    {
        try
        {
            dataDir = Environment.GetEnvironmentVariable("MG_HELPER_DIR");
            if (string.IsNullOrEmpty(dataDir))
                dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MG_Helper");
            dataDir = Path.GetFullPath(dataDir);
            Directory.CreateDirectory(dataDir);
            pipeName = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MG_HELPER_DIR")) ? "MG_Helper" : "MG_Helper_test";

            configPath = Path.Combine(dataDir, "config.json");
            statePath = Path.Combine(dataDir, "state.json");
            eventsPath = Path.Combine(dataDir, "events.jsonl");
            healthPath = Path.Combine(dataDir, "watcher.health.json");
            readyPath = Path.Combine(dataDir, "watcher.ready");
            logPath = Path.Combine(dataDir, "watcher.log");
            goldenPath = Path.Combine(dataDir, "settings.golden.xml");
            beforeApplyPath = Path.Combine(dataDir, "settings.before_apply.bak");
            versionPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "version.json");
            keyPath = Path.Combine(dataDir, "golden_key.json");

            mutex = new Mutex(false, pipeName == "MG_Helper" ? "Local\\MG_Helper_Watcher" : "Local\\MG_Helper_Watcher_test");
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) return 0;

            try
            {
                stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, pipeName == "MG_Helper" ? "Local\\MG_Helper_Stop" : "Local\\MG_Helper_Stop_test");
                try { stopEvent.Reset(); } catch { }
            }
            catch { stopEvent = null; }
            // stale requests must not act on a fresh process
            TryDelete(Path.Combine(dataDir, "stop.request"));

            if (!LoadConfig()) { Log("[!] config.json is unusable - exiting"); return 1; }
            if (!File.Exists(settingsXml)) { Log("[!] settings.xml not found - edit config.json or run GTA V once"); return 1; }

            WriteHealth("starting");
            File.WriteAllText(readyPath, "ready=" + DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + " version=" + ProductVersion + "\r\n", new UTF8Encoding(false));
            Log("[i] watcher READY (" + pipeName + ", data: " + dataDir + ")");
            Ev("watcher.ready", "version=" + ProductVersion);
            WriteHealth("running");

            bool pipeOk = MgPipe.Start(pipeName, dataDir);
            if (pipeOk) Log("[i] command pipe ready (\\\\.\\pipe\\" + pipeName + ")");
            else Log("[MG-E-0106] command pipe did not start - file fallback only");

            goldenMismatch = KeyMismatch();

            DateTime lastHealth = DateTime.MinValue;
            while (true)
            {
                Thread.Sleep(1000);
                if (CheckStop()) break;
                ConsumeRequests();
                TickSession();
                if ((DateTime.UtcNow - lastHealth).TotalSeconds >= 5)
                {
                    WriteHealth(goldenMismatch || phase == "UnknownSession" ? "running" : "running");
                    lastHealth = DateTime.UtcNow;
                }
            }

            try { MgPipe.Stop(); } catch { }
            WriteHealth("stopping");
            Ev("watcher.stop", "version=" + ProductVersion);
            Log("watcher stopped");
            TryDelete(readyPath);
            return 0;
        }
        catch (Exception ex)
        {
            try { Log("[!] fatal: " + ex.ToString()); } catch { }
            return 1;
        }
    }

    private const string ProductVersion = "3.0.0";

    // ---------------- config ----------------

    private static bool LoadConfig()
    {
        try
        {
            config = MgJson.ReadObject(configPath);
        }
        catch
        {
            return false;
        }
        settingsXml = MgJson.GetString(config, "settingsXml");
        return !string.IsNullOrEmpty(settingsXml);
    }

    private static string[] GetPatterns(string key)
    {
        object raw = MgJson.Get(config, key);
        List<string> list = new List<string>();
        IEnumerable<object> items = raw as IEnumerable<object>;
        if (items != null)
        {
            foreach (object item in items)
            {
                string text = Convert.ToString(item, CultureInfo.InvariantCulture);
                if (!string.IsNullOrEmpty(text)) list.Add(text);
            }
        }
        return list.ToArray();
    }

    private static bool GetConfigBool(string key, bool fallback)
    {
        object raw = MgJson.Get(config, key);
        if (raw == null) return fallback;
        if (raw is bool) return (bool)raw;
        string text = Convert.ToString(raw, CultureInfo.InvariantCulture);
        if (string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(text, "false", StringComparison.OrdinalIgnoreCase)) return false;
        return fallback;
    }

    private static int GetConfigInt(string key, int fallback)
    {
        object raw = MgJson.Get(config, key);
        if (raw == null) return fallback;
        try { return Convert.ToInt32(raw, CultureInfo.InvariantCulture); } catch { return fallback; }
    }

    // ---------------- helpers ----------------

    private static string HelperVersion()
    {
        try
        {
            Dictionary<string, object> v = MgJson.ReadObject(versionPath);
            string text = MgJson.GetString(v, "version");
            if (!string.IsNullOrEmpty(text)) return text;
        }
        catch { }
        return ProductVersion;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void TryDeleteTree(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { }
    }

    private static void Log(string message)
    {
        try
        {
            FileInfo info = new FileInfo(logPath);
            if (info.Exists && info.Length > 1024 * 1024) File.Move(logPath, logPath + ".old");
        }
        catch { }
        try
        {
            File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message + "\r\n", new UTF8Encoding(true));
        }
        catch { }
    }

    private static void Ev(string name, string data)
    {
        try
        {
            FileInfo info = new FileInfo(eventsPath);
            if (info.Exists && info.Length > 1024 * 1024) File.Move(eventsPath, eventsPath + ".old");
        }
        catch { }
        try
        {
            string line = "{\"ts\":\"" + Escape(DateTime.Now.ToString("o", CultureInfo.InvariantCulture)) + "\",\"phase\":\"" + Escape(phase) + "\",\"event\":\"" + Escape(name) + "\",\"data\":\"" + Escape(data ?? "") + "\"}";
            File.AppendAllText(eventsPath, line + "\r\n", new UTF8Encoding(false));
        }
        catch { }
    }

    private static string Escape(string text)
    {
        if (text == null) return "";
        return text.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
    }

    private static string Iso(DateTime value)
    {
        return value.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
    }

    private static void WriteHealth(string status)
    {
        healthSequence++;
        try
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"schemaVersion\":1,\"pid\":").Append(System.Diagnostics.Process.GetCurrentProcess().Id);
            sb.Append(",\"processStartUtc\":\"").Append(Escape(StartUtc())).Append('"');
            sb.Append(",\"version\":\"").Append(Escape(HelperVersion())).Append('"');
            sb.Append(",\"status\":\"").Append(Escape(status)).Append('"');
            sb.Append(",\"phase\":\"").Append(Escape(phase)).Append('"');
            sb.Append(",\"gamePid\":").Append(gamePid.HasValue ? gamePid.Value.ToString(CultureInfo.InvariantCulture) : "null");
            sb.Append(",\"lastHeartbeatUtc\":\"").Append(Escape(Iso(DateTime.UtcNow))).Append('"');
            sb.Append(",\"sequence\":").Append(healthSequence.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"lastErrorCode\":\"\"}");
            WriteAtomic(healthPath, new UTF8Encoding(false).GetBytes(sb.ToString()));
        }
        catch (Exception ex) { Log("[!] health write failed: " + ex.Message); }
    }

    private static string StartUtc()
    {
        try { return Iso(System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime()); }
        catch { return Iso(DateTime.UtcNow); }
    }

    private static void WriteState()
    {
        try
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"schema\":2,\"phase\":\"").Append(Escape(phase)).Append('"');
            sb.Append(",\"gamePid\":").Append(gamePid.HasValue ? gamePid.Value.ToString(CultureInfo.InvariantCulture) : "null");
            sb.Append(",\"gamePath\":").Append(gamePath == null ? "null" : "\"" + Escape(gamePath) + "\"");
            sb.Append(",\"sessionStart\":").Append(sessionStart.HasValue ? "\"" + Escape(Iso(sessionStart.Value)) + "\"" : "null");
            sb.Append(",\"lastApplyUtc\":").Append(lastApplyUtc == DateTime.MinValue ? "null" : "\"" + Escape(Iso(lastApplyUtc)) + "\"");
            sb.Append(",\"applied\":").Append(appliedThisSession ? "true" : "false");
            sb.Append(",\"guardRollbacks\":").Append(guardRollbacks.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"restarts\":0}");
            WriteAtomic(statePath, new UTF8Encoding(false).GetBytes(sb.ToString()));
        }
        catch (Exception ex) { Log("[!] state write failed: " + ex.Message); }
    }

    private static bool WriteAtomic(string path, byte[] bytes)
    {
        string tmp = path + "." + System.Diagnostics.Process.GetCurrentProcess().Id + ".mgtmp";
        try
        {
            File.WriteAllBytes(tmp, bytes);
            if (File.Exists(path))
            {
                FileInfo info = new FileInfo(path);
                if ((info.Attributes & FileAttributes.ReadOnly) != 0) info.Attributes = info.Attributes & ~FileAttributes.ReadOnly;
                File.Replace(tmp, path, null);
            }
            else File.Move(tmp, path);
            return true;
        }
        catch
        {
            TryDelete(tmp);
            return false;
        }
    }

    // ---------------- stop / requests ----------------

    private static bool CheckStop()
    {
        try { if (stopEvent != null && stopEvent.WaitOne(0)) { Log("stop requested (event)"); return true; } } catch { }
        if (File.Exists(Path.Combine(dataDir, "stop.request")))
        {
            TryDelete(Path.Combine(dataDir, "stop.request"));
            Log("stop requested (file flag)");
            return true;
        }
        return false;
    }

    private static void ConsumeRequests()
    {
        string reload = Path.Combine(dataDir, "reload.request");
        if (File.Exists(reload))
        {
            TryDelete(reload);
            if (LoadConfig())
            {
                Log("[i] config reloaded (pipe request)");
                Ev("config.reloaded", "pipe");
            }
        }
        string apply = Path.Combine(dataDir, "apply.request");
        if (File.Exists(apply))
        {
            TryDelete(apply);
            if (ApplyGolden())
            {
                appliedThisSession = true;
                lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
                Log("golden applied (pipe request)");
                Ev("golden.applied", "manual");
            }
            else
            {
                Log("[MG-E-0104] gold apply failed (pipe request)");
                Ev("apply.failed", "manual");
            }
            WriteState();
        }
    }

    // ---------------- session ----------------

    private static void TickSession()
    {
        List<int> pids = FindGamePids();
        bool running = pids.Count > 0;
        if (running && !wasRunning) Launch(pids[0]);
        else if (running && wasRunning && phase == "InGame" && gamePid.HasValue && !pids.Contains(gamePid.Value)) Launch(pids[0]);
        else if (running && wasRunning) GuardTick();
        else if (!running && wasRunning) ExitSession();
        wasRunning = running;
    }

    private static List<int> FindGamePids()
    {
        List<int> hits = new List<int>();
        string[] patterns = GetPatterns("gameProcesses");
        if (patterns.Length == 0) return hits;
        foreach (System.Diagnostics.Process process in System.Diagnostics.Process.GetProcesses())
        {
            try
            {
                string name = process.ProcessName;
                string lower = name.ToLowerInvariant();
                if (lower == "powershell" || lower == "pwsh" || lower == "explorer") continue;
                foreach (string pattern in patterns)
                {
                    if (pattern.Length > 0 && lower.Contains(pattern.ToLowerInvariant())) { hits.Add(process.Id); break; }
                }
            }
            catch { }
        }
        return hits;
    }

    private static string ProcessPath(int pid)
    {
        try { return System.Diagnostics.Process.GetProcessById(pid).MainModule.FileName; }
        catch { return null; }
    }

    private static bool ApplyGolden()
    {
        Dictionary<string, object> inputs = new Dictionary<string, object>();
        Dictionary<string, object> paths = new Dictionary<string, object>();
        paths["golden"] = goldenPath;
        paths["goldenBak"] = goldenPath + ".bak";
        paths["beforeApply"] = beforeApplyPath;
        paths["live"] = settingsXml;
        Dictionary<string, object> request = new Dictionary<string, object>();
        request["kind"] = "apply";
        request["inputs"] = inputs;
        request["paths"] = paths;
        Dictionary<string, object> actual = MgDecisions.Run(request);
        object applied = MgJson.Get(actual, "applied");
        return applied is bool && (bool)applied;
    }

    private static bool? SameSettingsNow()
    {
        return MgDecisions.SameSettings(settingsXml, goldenPath);
    }

    private static void Launch(int pid)
    {
        if (File.Exists(goldenPath) && !MgDecisions.GoldenValid(goldenPath))
        {
            Log("[!] golden is not valid - NOT applying; run menu [2] or [11]");
            Ev("apply.failed", "launch");
        }
        bool preBackupOk = false;
        try
        {
            if (File.Exists(settingsXml)) { File.Copy(settingsXml, beforeApplyPath, true); preBackupOk = true; }
        }
        catch { Log("[MG-E-0102] pre-apply backup FAILED: golden will NOT be applied"); }
        goldenMismatch = KeyMismatch();
        appliedThisSession = false;
        lastApplyUtc = DateTime.MinValue;
        guardRollbacks = 0;
        sessionStart = DateTime.UtcNow;
        gamePid = pid;
        gamePath = ProcessPath(pid);
        if (goldenMismatch)
        {
            Log("[!] golden mismatch - NOT applying; create a fresh golden via menu [11]");
            Ev("golden.mismatch", "session start");
        }
        else if (preBackupOk)
        {
            if (ApplyGolden())
            {
                lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
                appliedThisSession = true;
                Log("GTA5 launched -> settings applied");
                Ev("golden.applied", "launch");
            }
            else
            {
                Log("[MG-E-0104] apply FAILED - settings.xml NOT written");
                Ev("apply.failed", "launch");
            }
        }
        else Ev("apply.failed", "pre-apply backup failed");
        phase = "InGame";
        WriteState();
        Ev("session.start", "pid=" + pid.ToString(CultureInfo.InvariantCulture));
    }

    private static void GuardTick()
    {
        if (goldenMismatch) return;
        if ((DateTime.UtcNow - lastGuardCheck).TotalSeconds < 10) return;
        bool guardEnabled = GetConfigBool("sessionGuard", true);
        int windowSec = GetConfigInt("guardWindowSec", 0);
        if (!sessionStart.HasValue) return;
        Dictionary<string, object> inputs = new Dictionary<string, object>();
        inputs["sessionStart"] = Iso(sessionStart.Value);
        inputs["windowSec"] = windowSec;
        inputs["guardEnabled"] = guardEnabled;
        inputs["gameRunning"] = true;
        Dictionary<string, object> request = new Dictionary<string, object>();
        request["kind"] = "guard";
        request["inputs"] = inputs;
        Dictionary<string, object> actual = MgDecisions.Run(request);
        object active = MgJson.Get(actual, "active");
        lastGuardCheck = DateTime.UtcNow;
        if (!(active is bool) || !(bool)active) return;
        bool? same = SameSettingsNow();
        if (same != false) return;
        bool backupOk = File.Exists(beforeApplyPath);
        if (!backupOk)
        {
            try { File.Copy(settingsXml, beforeApplyPath, true); backupOk = true; Log("[i] guard: pre-apply backup created from the file about to be overwritten"); }
            catch { backupOk = false; }
        }
        if (!backupOk)
        {
            Log("[MG-E-0102] guard: no recovery copy - rollback SKIPPED");
            Ev("apply.failed", "guard: pre-apply backup failed");
            return;
        }
        if (ApplyGolden())
        {
            guardRollbacks++;
            lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
            appliedThisSession = true;
            Log("session guard: foreign overwrite - golden re-applied");
            Ev("guard.rollback", "foreign overwrite during session");
            Ev("golden.applied", "guard");
            WriteState();
        }
        else
        {
            Log("[MG-E-0104] session guard: rollback FAILED");
            Ev("apply.failed", "guard rollback");
        }
    }

    private static void ExitSession()
    {
        Thread.Sleep(1500);
        if (FindGamePids().Count > 0) { Log("[i] game is back already - exit handling deferred"); wasRunning = true; return; }
        if (phase == "UnknownSession")
        {
            Log("[i] unknown session ended - safe re-init (nothing was written)");
            Ev("session.end", "unknown-session");
            ResetSession();
            return;
        }
        bool? same = SameSettingsNow();
        bool changedAfterUs = lastApplyUtc != DateTime.MinValue && File.GetLastWriteTimeUtc(settingsXml) > lastApplyUtc.AddSeconds(2);
        bool allowAdopt = GetConfigBool("allowAdopt", false);
        Dictionary<string, object> inputs = new Dictionary<string, object>();
        inputs["changedAfterUs"] = changedAfterUs;
        inputs["allowAdopt"] = allowAdopt;
        if (same.HasValue) inputs["same"] = same.Value; else inputs["same"] = null;
        inputs["appliedThisSession"] = appliedThisSession;
        Dictionary<string, object> request = new Dictionary<string, object>();
        request["kind"] = "adopt";
        request["inputs"] = inputs;
        object adoptRaw = MgJson.Get(MgDecisions.Run(request), "adopt");
        bool adopt = adoptRaw is bool && (bool)adoptRaw;
        bool adopted = false;
        if (adopt)
        {
            try
            {
                File.Copy(goldenPath, goldenPath + ".bak", true);
                byte[] bytes = File.ReadAllBytes(settingsXml);
                if (WriteAtomic(goldenPath, bytes) && MgDecisions.GoldenValid(goldenPath))
                {
                    Log("exit: settings changed in game - adopted as new golden");
                    Ev("adopt.accepted", "session");
                    adopted = true;
                }
                else Log("[!] could not write golden - golden kept");
            }
            catch (Exception ex) { Log("[!] adopt failed: " + ex.Message); }
        }
        else if (same == null) Log("[i] exit: settings.xml unreadable - golden kept, adopt skipped");
        else if (same == true) Log("GTA5 closed -> settings unchanged, golden kept");
        else if (!appliedThisSession) Log("GTA5 closed -> golden never applied this session - adopt skipped (foreign overwrite?)");
        else if (!changedAfterUs) Log("GTA5 closed -> nobody wrote after our apply - golden kept");
        else Log("GTA5 closed -> adopt disabled (allowAdopt=" + (allowAdopt ? "True" : "False") + ") - user changes not adopted");
        if (!adopted && appliedThisSession && same == false)
        {
            if (ApplyGolden())
            {
                lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
                Log("GTA5 closed -> golden restored");
                Ev("golden.applied", "exit-restore");
            }
            else
            {
                Log("[MG-E-0104] exit-restore FAILED");
                Ev("apply.failed", "exit-restore");
            }
        }
        Ev("session.end", "game closed");
        ResetSession();
    }

    private static void ResetSession()
    {
        phase = "Idle";
        gamePid = null;
        gamePath = null;
        sessionStart = null;
        appliedThisSession = false;
        lastApplyUtc = DateTime.MinValue;
        guardRollbacks = 0;
        WriteState();
    }

    // ---------------- golden key ----------------

    private static bool KeyMismatch()
    {
        try
        {
            if (!File.Exists(keyPath)) return false;
            Dictionary<string, object> key = MgJson.ReadObject(keyPath);
            string storedGpu = MgJson.GetString(key, "gpu");
            string storedVariant = MgJson.GetString(key, "variant");
            string liveGpu = null;
            try
            {
                string text = File.ReadAllText(settingsXml);
                Match match = Regex.Match(text, "<VideoCardDescription>([^<]+)</VideoCardDescription>");
                if (match.Success) liveGpu = match.Groups[1].Value;
            }
            catch { }
            string liveVariant = null;
            if (!string.IsNullOrEmpty(gamePath))
                liveVariant = gamePath.ToLowerInvariant().Contains("enhanced") ? "GTA V Enhanced" : "GTA V";
            if (!string.IsNullOrEmpty(storedGpu) && !string.IsNullOrEmpty(liveGpu) && storedGpu != liveGpu) return true;
            if (!string.IsNullOrEmpty(storedVariant) && !string.IsNullOrEmpty(liveVariant) && storedVariant != liveVariant) return true;
            return false;
        }
        catch { return false; }
    }
}