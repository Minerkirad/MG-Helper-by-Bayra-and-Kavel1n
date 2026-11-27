// MG Core (beta) - C# strangler core v1 - by Bayra & Kavel1n
// ROADMAP phase 3, strangler step 1: a minimal compiled core that coexists
// with the PS watcher and is selected by config.json "coreMode": "csharp"
// (installer points the scheduled task here). Everything it writes is
// format-compatible with the PS tooling (state.json schema 2, events.jsonl,
// watcher.ready, golden_key.json, journal files) so either core can take over
// from the other at any time.
//
// Beta scope (deliberate): process detection by NAME only (renamed exes stay
// on the PS core), no menus/tray/update (PS owns those), no CIM (name polling
// is enough for the core loop). RAM ~15-25 MB, no PowerShell child processes.
//
// Exit codes: 0 normal/stop, 2 bad args, 3 fatal init error.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

static class MGCore
{
    static string helperDir, goldenPath, stateFile, readyFile, eventsFile, configPath;
    static JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 50 * 1000 * 1000 };
    static Dictionary<string, object> cfg;
    static Dictionary<string, object> state;
    static string goldenKeyVariant = null, goldenKeyGpu = null;
    static DateTime sessionStart = DateTime.MinValue;
    static DateTime lastApplyUtc = DateTime.MinValue;
    static bool appliedThisSession = false;
    static DateTime lastGuardReapply = DateTime.MinValue;
    static DateTime lastBeat = DateTime.MinValue;
    static EventWaitHandle stopEvent;
    static string logFile;

    const int GuardWindowSec = 120;

    static string JGet(Dictionary<string, object> d, string k, string def)
    {
        if (d != null && d.ContainsKey(k) && d[k] != null) return d[k].ToString();
        return def;
    }

    static void Log(string msg)
    {
        try
        {
            if (File.Exists(logFile) && new FileInfo(logFile).Length > 1024 * 1024)
                File.Move(logFile, logFile + ".old");
            File.AppendAllText(logFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  [core] " + msg + Environment.NewLine,
                new UTF8Encoding(true));
        }
        catch { }
    }

    static void Ev(string ev, string data)
    {
        try
        {
            if (File.Exists(eventsFile) && new FileInfo(eventsFile).Length > 1024 * 1024)
                File.Move(eventsFile, eventsFile + ".old");
            string phase = JGet(state, "phase", "Idle");
            string line = "{\"ts\":\"" + DateTime.UtcNow.ToString("o") + "\",\"phase\":\"" + phase +
                          "\",\"event\":\"" + ev + "\",\"data\":\"" + (data ?? "").Replace("\"", "'") + "\"}";
            File.AppendAllText(eventsFile, line + Environment.NewLine, new UTF8Encoding(false));
        }
        catch { }
    }

    static void WriteState()
    {
        try
        {
            string tmp = stateFile + ".tmp";
            File.WriteAllText(tmp, json.Serialize(state), new UTF8Encoding(false));
            if (File.Exists(stateFile)) File.Replace(tmp, stateFile, null);
            else File.Move(tmp, stateFile);
        }
        catch (Exception ex)
        {
            Log("[MG-E-0101] state.json save FAILED: " + ex.Message);
            try { File.Delete(stateFile + ".tmp"); } catch { }
        }
    }

    // atomic write: temp + File.Replace (MG-CR-001 pattern)
    static bool AtomicWrite(string path, byte[] bytes)
    {
        string tmp = path + "." + Process.GetCurrentProcess().Id + ".mgtmp";
        try
        {
            File.WriteAllBytes(tmp, bytes);
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
            return true;
        }
        catch { try { File.Delete(tmp); } catch { } return false; }
    }

    static bool GoldenValid(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists || fi.Length <= 100) return false;
            var doc = new System.Xml.XmlDocument { XmlResolver = null };
            doc.Load(path);
            return doc.DocumentElement != null && doc.DocumentElement.Name == "Settings";
        }
        catch { return false; }
    }

    static string[] GameNames()
    {
        var list = new List<string>();
        if (cfg != null && cfg.ContainsKey("gameProcesses"))
        {
            var arr = cfg["gameProcesses"] as IEnumerable<object>;
            if (arr != null) foreach (var o in arr) list.Add(o.ToString());
        }
        if (list.Count == 0) { list.Add("GTA5"); list.Add("GTA5_Enhanced"); }
        return list.ToArray();
    }

    static Process FindGame()
    {
        var names = GameNames();
        foreach (var p in Process.GetProcesses())
        {
            foreach (var n in names)
                if (p.ProcessName.IndexOf(n, StringComparison.OrdinalIgnoreCase) >= 0) return p;
        }
        return null;
    }

    static Process FindLauncher()
    {
        foreach (var p in Process.GetProcesses())
        {
            var n = p.ProcessName;
            if (n.IndexOf("majestic", StringComparison.OrdinalIgnoreCase) >= 0) return p;
        }
        return null;
    }

    static bool GoldenKeyMatches()
    {
        // beta: variant check only (GPU lives inside settings.xml, which the game
        // may hold locked); the PS core keeps the full GPU check
        try
        {
            if (goldenKeyVariant == null) return true;   // no key recorded - conservative
            var root = FindGtaRoot();
            if (root == null) return true;               // cannot determine - conservative
            bool isEnhanced = Directory.Exists(Path.Combine(root, "GTA V Enhanced")) ||
                              root.IndexOf("Enhanced", StringComparison.OrdinalIgnoreCase) >= 0;
            string cur = isEnhanced ? "GTA V Enhanced" : "GTA V";
            return cur == goldenKeyVariant;
        }
        catch { return true; }
    }

    static string FindGtaRoot()
    {
        try
        {
            var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                "SOFTWARE\\WOW6432Node\\Valve\\Steam");
            if (key == null) return null;
            string steam = (key.GetValue("SteamPath") as string ?? "").Replace('/', '\\');
            if (string.IsNullOrEmpty(steam)) return null;
            string vdf = Path.Combine(steam, "steamapps\\libraryfolders.vdf");
            var roots = new List<string> { steam };
            if (File.Exists(vdf))
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(
                    File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                    roots.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
            foreach (var r in roots)
            {
                foreach (var tail in new[] { "steamapps\\common\\Grand Theft Auto V", "steamapps\\common\\Grand Theft Auto V Enhanced" })
                {
                    string full = Path.Combine(r, tail);
                    if (Directory.Exists(full) && File.Exists(Path.Combine(full, "GTA5.exe"))) return full;
                }
            }
        }
        catch { }
        return null;
    }

    static bool ApplyGolden(string settingsXml)
    {
        try
        {
            if (!GoldenValid(goldenPath)) return false;
            var fi = new FileInfo(settingsXml);
            if (fi.Exists && fi.IsReadOnly) fi.IsReadOnly = false;
            return AtomicWrite(settingsXml, File.ReadAllBytes(goldenPath));
        }
        catch { return false; }
    }

    static string MajesticBackupDir(Dictionary<string, object> cfgLocal)
    {
        try
        {
            string mj = JGet(cfgLocal, "majesticJson", null);
            if (!string.IsNullOrEmpty(mj) && File.Exists(mj))
            {
                string d = Path.Combine(Path.GetDirectoryName(mj), "backup");
                if (Directory.Exists(d)) return d;
            }
        }
        catch { }
        string std = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "majestic-launcher\\Multiplayer\\backup");
        return Directory.Exists(std) ? std : null;
    }

    static string LatestBinGen()
    {
        var arcRoot = Path.Combine(helperDir, "vanilla_backup_archive");
        try
        {
            foreach (var d in new DirectoryInfo(arcRoot).GetDirectories("*.incomplete"))
                try { d.Delete(true); } catch { }
        }
        catch { }
        if (!Directory.Exists(arcRoot)) return null;
        var gens = new DirectoryInfo(arcRoot).GetDirectories()
            .Where(x => !x.Name.EndsWith(".incomplete"))
            .OrderByDescending(x => x.Name).ToArray();
        foreach (var g in gens)
            if (g.GetFiles("*.bin").Length > 0) return g.FullName;
        return null;
    }

    static string EnsureBins()
    {
        // 'present' / 'restored' / 'partial' / 'failed' / 'none'
        try
        {
            string bk = MajesticBackupDir(cfg);
            if (bk == null) return 'n'.ToString() == "n" ? "none" : "none";
            var arcGen = LatestBinGen();
            if (arcGen == null) return "none";
            var missing = Directory.GetFiles(arcGen, "*.bin")
                .Where(f => !File.Exists(Path.Combine(bk, Path.GetFileName(f)))).ToArray();
            if (missing.Length == 0) return "present";
            int copied = 0, failed = 0;
            foreach (var f in missing)
            {
                try
                {
                    File.Copy(f, Path.Combine(bk, Path.GetFileName(f)), true);
                    if (new FileInfo(Path.Combine(bk, Path.GetFileName(f))).Length == new FileInfo(f).Length) copied++;
                    else failed++;
                }
                catch { failed++; }
            }
            if (failed > 0) return "partial";
            return copied == missing.Length ? "restored" : "failed";
        }
        catch { return "failed"; }
    }

    static void RestoreBins()
    {
        try
        {
            string bk = MajesticBackupDir(cfg);
            if (bk == null) return;
            var arcGen = LatestBinGen();
            if (arcGen == null) return;
            foreach (var f in Directory.GetFiles(arcGen, "*.bin"))
            {
                string dst = Path.Combine(bk, Path.GetFileName(f));
                if (File.Exists(dst)) continue;
                try
                {
                    File.Copy(f, dst, true);
                    if (new FileInfo(dst).Length != new FileInfo(f).Length) { File.Delete(dst); }
                }
                catch { }
            }
        }
        catch { }
    }

    static void ArchiveBins(EventWaitHandle stopEvent)
    {
        // copy-only, .incomplete -> verified rename, keep 2 generations
        try
        {
            string bk = MajesticBackupDir(cfg);
            if (bk == null) return;
            var bins = Directory.GetFiles(bk, "*.bin");
            if (bins.Length == 0) return;
            var arcRoot = Path.Combine(helperDir, "vanilla_backup_archive");
            var latest = LatestBinGen();
            if (latest != null)
            {
                bool unchanged = true;
                foreach (var b in bins)
                {
                    string p = Path.Combine(latest, Path.GetFileName(b));
                    if (!File.Exists(p)) { unchanged = false; break; }
                    var li = new FileInfo(p);
                    var lb = new FileInfo(b);
                    if (li.Length != lb.Length || li.LastWriteTimeUtc != lb.LastWriteTimeUtc) { unchanged = false; break; }
                }
                if (unchanged) return;
            }
            string stamp = DateTime.Now.ToString("yyyy-MM-dd_HHmmss");
            string finalDst = Path.Combine(arcRoot, stamp);
            int u = 0;
            while (Directory.Exists(finalDst)) { u++; finalDst = Path.Combine(arcRoot, stamp + "-" + u); }
            string inc = finalDst + ".incomplete";
            Directory.CreateDirectory(inc);
            int okFiles = 0;
            foreach (var b in bins)
            {
                if (stopEvent != null && stopEvent.WaitOne(0)) { try { Directory.Delete(inc, true); } catch { } return; }
                try
                {
                    string d = Path.Combine(inc, Path.GetFileName(b));
                    File.Copy(b, d, true);
                    if (new FileInfo(d).Length == new FileInfo(b).Length) okFiles++;
                }
                catch { }
            }
            if (okFiles != bins.Length) { try { Directory.Delete(inc, true); } catch { } return; }
            Directory.Move(inc, finalDst);
            var all = new DirectoryInfo(arcRoot).GetDirectories()
                .Where(x => !x.Name.EndsWith(".incomplete"))
                .OrderByDescending(x => x.Name).ToArray();
            for (int i = 2; i < all.Length; i++) try { all[i].Delete(true); } catch { }
        }
        catch { }
    }

    static void Reconcile()
    {
        // journals left 'running' with write-golden done -> rollback from backup
        try
        {
            string goldenP = Path.Combine(helperDir, "settings.golden.xml");
            foreach (var f in Directory.GetFiles(helperDir, "journal_*.json"))
            {
                try
                {
                    var j = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(f));
                    if (j == null || JGet(j, "status", "") != "running") continue;
                    bool goldenDone = false; string bak = null;
                    if (j.ContainsKey("steps"))
                    {
                        foreach (var s in (IEnumerable<object>)j["steps"])
                        {
                            var sd = s as Dictionary<string, object>;
                            if (sd == null) continue;
                            if (JGet(sd, "step", "") == "write-golden" && JGet(sd, "status", "") == "done") goldenDone = true;
                            if (JGet(sd, "step", "") == "backup" && JGet(sd, "status", "") == "done") bak = JGet(sd, "path", null);
                        }
                    }
                    if (goldenDone && bak != null && File.Exists(bak))
                    {
                        if (AtomicWrite(goldenP, File.ReadAllBytes(bak)))
                            Log("[i] reconciliation: '" + JGet(j, "op", "?") + "' rolled golden back from " + bak);
                        else
                            Log("[!] reconciliation: rollback FAILED from " + bak);
                    }
                    j["status"] = "recovered";
                    File.WriteAllText(f, json.Serialize(j), new UTF8Encoding(false));
                }
                catch (Exception ex) { Log("[!] reconciliation error on " + f + ": " + ex.Message); }
            }
            try
            {
                var arcRoot = Path.Combine(helperDir, "vanilla_backup_archive");
                if (Directory.Exists(arcRoot))
                    foreach (var d in new DirectoryInfo(arcRoot).GetDirectories("*.incomplete"))
                        try { d.Delete(true); } catch { }
            }
            catch { }
        }
        catch (Exception ex) { Log("[!] reconciliation error: " + ex.Message); }
    }

    static int Main(string[] args)
    {
        helperDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MG_Helper");
        logFile = Path.Combine(helperDir, "watcher.log");
        stateFile = Path.Combine(helperDir, "state.json");
        readyFile = Path.Combine(helperDir, "watcher.ready");
        eventsFile = Path.Combine(helperDir, "events.jsonl");
        configPath = Path.Combine(helperDir, "config.json");
        goldenPath = Path.Combine(helperDir, "settings.golden.xml");

        // smoke mode (installer launchability check): run powershell on the given
        // script exactly like the hidden host does
        bool smoke = false; string smokeScript = null;
        foreach (var a in args)
        {
            if (a == "-Smoke") smoke = true;
            else if (!a.StartsWith("-") && smokeScript == null) smokeScript = a;
        }
        if (smoke)
        {
            if (smokeScript == null || !File.Exists(smokeScript)) return 2;
            try
            {
                var psi = new ProcessStartInfo(
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"),
                    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + smokeScript + "\"")
                { UseShellExecute = false, CreateNoWindow = true };
                var sp = Process.Start(psi);
                sp.WaitForExit(30000);
                if (!sp.HasExited) { try { sp.Kill(); } catch { } return 1; }
                return sp.ExitCode;
            }
            catch { return 3; }
        }

        Log("MGCore " + System.Reflection.Assembly.GetExecutingAssembly().GetName().Version +
            " started (beta C# core, config coreMode=csharp)");

        // config
        try { cfg = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(configPath)); }
        catch (Exception ex) { Log("[!] config.json unreadable: " + ex.Message); return 3; }
        if (cfg == null) { Log("[!] config.json empty"); return 3; }

        string settingsXml = JGet(cfg, "settingsXml", null);
        if (string.IsNullOrEmpty(settingsXml) || !File.Exists(settingsXml))
        {
            Log("[!] settingsXml not found in config - run the PS installer first");
            return 3;
        }

        string onExit = JGet(cfg, "onExit", "adopt");
        bool guardEnabled = JGet(cfg, "sessionGuard", "true") == "true";
        int guardWindow = 120;
        int.TryParse(JGet(cfg, "guardWindowSec", "120"), out guardWindow);

        // golden key (ROADMAP 2.3)
        try
        {
            var kf = Path.Combine(helperDir, "golden_key.json");
            if (File.Exists(kf))
            {
                var k = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(kf));
                goldenKeyVariant = JGet(k, "variant", null);
                goldenKeyGpu = JGet(k, "gpu", null);
            }
        }
        catch { }
        if (GoldenKeyMatches() == false)
        {
            Log("[MG-E-0301] golden key mismatch (variant/GPU changed) - beta core refuses to run; use the PS watcher");
            return 3;
        }

        // mutex: SAME name as the PS watcher - mutual exclusion across cores
        Mutex mutex;
        bool ownsMutex;
        try
        {
            mutex = new Mutex(false, "Local\\MG_Helper_Watcher");
            ownsMutex = false;
            try { ownsMutex = mutex.WaitOne(0); }
            catch (System.Threading.AbandonedMutexException) { ownsMutex = true; }
            if (!ownsMutex) { Log("another watcher holds the mutex - exiting"); return 0; }
        }
        catch (Exception ex)
        {
            Log("[!] mutex error: " + ex.Message);
            return 3;
        }

        // cooperative stop (same event name as the PS watcher)
        try { stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, "Local\\MG_Helper_Stop"); }
        catch { stopEvent = null; }
        try { if (stopEvent != null) stopEvent.Reset(); } catch { }

        Reconcile();
        try { File.WriteAllText(readyFile, "ready=" + DateTime.Now.ToString("o") + " core=csharp" + Environment.NewLine, new UTF8Encoding(false)); }
        catch { }
        Log("[i] MGCore READY (config loaded, state initialised)");
        Ev("watcher.start", "core=csharp");

        // restore state
        state = new Dictionary<string, object>();
        state["schema"] = 2;
        state["phase"] = "Idle";
        state["gamePid"] = null;
        state["gamePath"] = null;
        state["applied"] = false;
        state["lastApplyUtc"] = null;
        try
        {
            var loaded = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(stateFile));
            if (loaded != null && JGet(loaded, "phase", "") == "InGame")
            {
                // takeover only if the recorded pid is still the game
                int oldPid = 0;
                int.TryParse(JGet(loaded, "gamePid", "0"), out oldPid);
                var gp = oldPid > 0 ? Process.GetProcessById(oldPid) : null;   // may throw -> caught
                if (gp != null && gp.ProcessName.IndexOf("GTA5", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    state["phase"] = "InGame";
                    state["gamePid"] = oldPid;
                    Log("[i] adopting InGame session (PID " + oldPid + ")");
                }
            }
        }
        catch { }
        WriteState();

        bool wasRunning = JGet(state, "phase", "Idle") == "InGame";
        int exitCode = 0;

        try
        {
            while (true)
            {
                System.Threading.Thread.Sleep(5000);
                bool stopped = false;
                try { stopped = stopEvent != null && stopEvent.WaitOne(0); } catch { }
                if (stopped) { Log("stop requested (event)"); break; }

                try
                {
                    if (!File.Exists(settingsXml)) continue;
                    var game = FindGame();
                    bool running = game != null;
                    var phase = JGet(state, "phase", "Idle");

                    if (running && phase == "Idle")
                    {
                        // launch: backup -> apply golden
                        Ev("session.start", "pid=" + game.Id);
                        try
                        {
                            File.Copy(settingsXml, Path.Combine(helperDir, "settings.before_apply.bak"), true);
                        }
                        catch (Exception ex)
                        {
                            Log("[MG-E-0102] pre-apply backup FAILED: " + ex.Message + " - golden NOT applied");
                        }
                        appliedThisSession = false;
                        sessionStart = DateTime.Now;
                        if (ApplyGolden(settingsXml))
                        {
                            Log("GTA5 launched -> settings applied");
                            Ev("golden.applied", "launch");
                            appliedThisSession = true;
                            lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
                        }
                        EnsureBins();
                        phase = "InGame";
                        state["phase"] = "InGame";
                        state["gamePid"] = game.Id;
                        state["gamePath"] = SafePath(game);
                        state["sessionStart"] = sessionStart.ToString("o");
                        state["guardRollbacks"] = 0;
                        state["applied"] = appliedThisSession;
                        state["lastApplyUtc"] = lastApplyUtc == DateTime.MinValue ? null : lastApplyUtc.ToString("o");
                        WriteState();
                    }
                    else if (!running && phase == "InGame")
                    {
                        System.Threading.Thread.Sleep(3000);
                        if (FindGame() != null) continue;   // REVIEW-#21: recheck
                        if (onExit == "adopt" && appliedThisSession && !SameAsGolden(settingsXml))
                        {
                            // adopt: rotate old golden -> .bak, atomic write
                            try { File.Copy(goldenPath, goldenPath + ".bak", true); } catch { }
                            if (AtomicWrite(goldenPath, File.ReadAllBytes(settingsXml)))
                            {
                                Log("exit: settings changed in game - adopted as new golden");
                                Ev("adopt.accepted", "in-game changes");
                            }
                        }
                        else if (appliedThisSession && !SameAsGolden(settingsXml))
                        {
                            if (ApplyGolden(settingsXml))
                            {
                                Log("GTA5 closed -> golden restored");
                                Ev("golden.restored", "exit");
                            }
                        }
                        else
                        {
                            Log("GTA5 closed -> golden kept");
                        }
                        RestoreBins();
                        ArchiveBins(stopEvent);
                        phase = "Idle";
                        state["phase"] = "Idle";
                        state["gamePid"] = null;
                        state["gamePath"] = null;
                        state["applied"] = false;
                        state["lastApplyUtc"] = null;
                        WriteState();
                        appliedThisSession = false;
                    }
                    else if (running && phase == "InGame")
                    {
                        // drift-guard inside the launch window
                        bool inWindow = (DateTime.Now - sessionStart).TotalSeconds < guardWindow;
                        bool cooldown = (DateTime.Now - lastGuardReapply).TotalSeconds >= 10;
                        if (guardEnabled && inWindow && cooldown && !SameAsGolden(settingsXml))
                        {
                            if (ApplyGolden(settingsXml))
                            {
                                Log("session guard: foreign overwrite in launch window - golden re-applied");
                                Ev("guard.rollback", "launch window");
                                lastApplyUtc = File.GetLastWriteTimeUtc(settingsXml);
                                appliedThisSession = true;
                                state["applied"] = true;
                                state["lastApplyUtc"] = lastApplyUtc.ToString("o");
                                var gr = 0;
                                int.TryParse(JGet(state, "guardRollbacks", "0"), out gr);
                                state["guardRollbacks"] = gr + 1;
                                WriteState();
                            }
                            lastGuardReapply = DateTime.Now;
                        }
                    }

                    // heartbeat 30 min
                    if ((DateTime.Now - lastBeat).TotalMinutes >= 30)
                    {
                        Log("heartbeat: alive (phase: " + phase + ")");
                        lastBeat = DateTime.Now;
                    }
                }
                catch (Exception ex)
                {
                    Log("[!] loop error: " + ex.Message);
                }
            }
        }
        finally
        {
            try { File.Delete(readyFile); } catch { }
            Log("watcher stopped");
            try { mutex.ReleaseMutex(); } catch { }
            mutex.Dispose();
        }
        return exitCode;
    }

    static string SafePath(Process p)
    {
        try { return p.MainModule.FileName; } catch { return null; }
    }

    static bool SameAsGolden(string settingsXml)
    {
        try
        {
            var doc = new System.Xml.XmlDocument { XmlResolver = null };
            doc.Load(settingsXml);
            var gd = new System.Xml.XmlDocument { XmlResolver = null };
            gd.Load(goldenPath);
            return doc.DocumentElement.OuterXml == gd.DocumentElement.OuterXml;
        }
        catch
        {
            try
            {
                string a = File.ReadAllText(settingsXml).Replace(" ", "").Replace("\r", "").Replace("\n", "");
                string b = File.ReadAllText(goldenPath).Replace(" ", "").Replace("\r", "").Replace("\n", "");
                return a == b;
            }
            catch { return true; }   // unreadable -> assume same, do not fight the game
        }
    }
}
