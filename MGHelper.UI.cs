// ============================================================
//  MGHelper.UI.cs - MG Helper 3.1 desktop app (WebView2 host)
//  by Bayra & Kavel1n
//
//  Окно приложения + трей. Вся логика остаётся в C#-ядре и watcher'е: это приложение
//  только читает состояние (health/state/events) и отправляет команды файлами-запросами
//  и задачей планировщика. HTML/CSS/JS лежат в ui\ рядом с exe.
//
//  Сборка: tools\build-ui.ps1 (Add-Type/CodeDom, net48, без .NET SDK).
//  Режимы: обычный запуск; --smoke (отрисовать окно, проверить JS, выйти 0).
// ============================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

public static class MgHelperUi
{
    public const string UiVersion = "3.1.0-dev";
    private static string dataRoot;
    private static string appDir;
    private static string uiDir;
    private static Form form;
    private static WebView2 web;
    private static NotifyIcon tray;
    private static Icon trayIcon;
    private static Icon trayGreen;
    private static Icon trayGold;
    private static Icon trayRed;
    private static Icon trayGray;
    private static System.Windows.Forms.Timer pollTimer;
    private static bool smoke;
    private static bool uiFallback;
    private static string shotDir;
    private static string sourceLogged;

    [STAThread]
    public static int Main(string[] args)
    {
        smoke = args != null && Array.IndexOf(args, "--smoke") >= 0;
        int shotIdx = args == null ? -1 : Array.IndexOf(args, "--shot");
        if (shotIdx >= 0 && args.Length > shotIdx + 1) { shotDir = args[shotIdx + 1]; }
        appDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        dataRoot = Environment.GetEnvironmentVariable("MG_HELPER_DIR");
        if (string.IsNullOrEmpty(dataRoot))
            dataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MG_Helper");
        uiDir = Path.Combine(appDir, "ui");
        // Проверка окружения: приложение обязано работать и там, где нет WebView2
        // или ОС/права не такие, как на машине разработчика (docs/PORTABILITY.md).
        string envFlag = Environment.GetEnvironmentVariable("MG_UI_FORCE_FALLBACK");
        uiFallback = envFlag == "1" || !WebView2RuntimePresent();
        int envIdx = args == null ? -1 : Array.IndexOf(args, "--env");
        if (envIdx >= 0) { WriteEnvironmentReport(); return 0; }
        // нативная финализация установки: установщик вызывает exe, а не PowerShell
        int finIdx = args == null ? -1 : Array.IndexOf(args, "--install-finalize");
        if (finIdx >= 0) { return InstallFinalize(); }
        if (!Directory.Exists(uiDir))
        {
            string nested = Path.Combine(appDir, "App");
            try { Log("[!] ui folder not found next to the exe"); } catch { }
            return 3;
        }

        Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) { Trace("ThreadException: " + e.Exception); if (smoke) { Environment.Exit(4); } };
        AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { Trace("Unhandled: " + e.ExceptionObject); if (smoke) { Environment.Exit(5); } };
        Trace("start smoke=" + smoke + " data=" + dataRoot + " ui=" + uiDir);
        bool isFirst;
        // Диагностические режимы не занимают единственный экземпляр: иначе запущенное
        // приложение ломает --smoke/--env/--shot (и автотесты). В песочнице имя своё.
        bool diagnosticRun = smoke || !string.IsNullOrEmpty(shotDir) || (args != null && Array.IndexOf(args, "--env") >= 0);
        string mutexName = "Local\\MG_Helper_UI" + (Environment.GetEnvironmentVariable("MG_HELPER_DIR") != null ? "_test" : "");
        using (Mutex mutex = new Mutex(diagnosticRun, mutexName, out isFirst))
        {
            if (!diagnosticRun && !isFirst) return 0;
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                BuildWindow();
                if (!smoke) { Application.Run(form); }
                else { Application.Run(form); }
                return 0;
            }
            catch (Exception ex)
            {
                try { Log("[!] fatal: " + ex.ToString()); } catch { }
                if (!smoke) MessageBox.Show("Не удалось запустить MG Helper: " + ex.Message, "MG Helper", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                GC.KeepAlive(mutex);
            }
        }
    }

    // ---------------- window ----------------

    private static bool WebView2RuntimePresent()
    {
        try
        {
            using (Microsoft.Win32.RegistryKey k1 = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"))
            using (Microsoft.Win32.RegistryKey k2 = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"))
            {
                if (k1 != null && k1.GetValue("pv") != null) return true;
                if (k2 != null && k2.GetValue("pv") != null) return true;
            }
            // Edge может держать компонент в HKCU при per-user установке
            using (Microsoft.Win32.RegistryKey k3 = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"))
            {
                return k3 != null && k3.GetValue("pv") != null;
            }
        }
        catch { return false; }
    }

    private static string WebView2Version()
    {
        try
        {
            using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"))
            {
                if (k != null) { object v = k.GetValue("pv"); if (v != null) return Convert.ToString(v); }
            }
        }
        catch { }
        return "";
    }

    private static bool DirWritable(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            string probe = Path.Combine(path, ".mg-write-probe");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    private static void WriteEnvironmentReport()
    {
        try
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"schema\":1");
            sb.Append(",\"uiVersion\":\"").Append(Json(UiVersion)).Append('"');
            sb.Append(",\"osVersion\":\"").Append(Json(Environment.OSVersion.VersionString)).Append('"');
            sb.Append(",\"os64\":").Append(Environment.Is64BitOperatingSystem ? "true" : "false");
            sb.Append(",\"webView2\":").Append(WebView2RuntimePresent() ? "true" : "false");
            sb.Append(",\"webView2Version\":\"").Append(Json(WebView2Version())).Append('"');
            sb.Append(",\"fallbackMode\":").Append(uiFallback ? "true" : "false");
            sb.Append(",\"appDir\":\"").Append(Json(appDir)).Append('"');
            sb.Append(",\"dataRoot\":\"").Append(Json(dataRoot)).Append('"');
            sb.Append(",\"dataRootWritable\":").Append(DirWritable(dataRoot) ? "true" : "false");
            sb.Append(",\"dataRootIsDefault\":").Append(string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MG_HELPER_DIR")) ? "true" : "false");
            sb.Append(",\"pipe\":\"").Append(Json(Environment.GetEnvironmentVariable("MG_HELPER_DIR") != null ? "MG_Helper_test" : "MG_Helper")).Append('"');
            sb.Append(",\"taskPresent\":").Append(AutostartEnabled() ? "true" : "false");
            sb.Append(",\"uiDirPresent\":").Append(Directory.Exists(uiDir) ? "true" : "false");
            sb.Append(",\"user\":\"").Append(Json(Environment.UserName)).Append('"');
            sb.Append(",\"interactive\":").Append(Environment.UserInteractive ? "true" : "false");
            sb.Append("}");
            File.WriteAllText(Path.Combine(appDir, "ui-env.json"), sb.ToString(), new UTF8Encoding(true));
            Trace("env report written");
        }
        catch (Exception ex) { Trace("env report failed: " + ex.Message); }
    }

    private static void BuildFallbackWindow()
    {
        form = new Form();
        form.Text = "MG Helper " + UiVersion + " — упрощённый режим";
        form.Width = 720;
        form.Height = 420;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = Color.FromArgb(15, 17, 21);
        form.ForeColor = Color.FromArgb(232, 237, 244);
        form.Icon = LoadIcon();

        Label title = new Label();
        title.Text = "MG Helper работает, но без полноценного окна";
        title.Font = new Font("Segoe UI", 15F, FontStyle.Bold);
        title.AutoSize = false;
        title.Left = 24; title.Top = 22; title.Width = 660; title.Height = 34;
        form.Controls.Add(title);

        Label body = new Label();
        body.Text = "Не найден компонент Microsoft Edge WebView2 Runtime — он нужен для интерфейса.\r\n" +
                    "Защита настроек от этого не зависит: watcher работает отдельно и продолжает охранять эталон.\r\n\r\n" +
                    "Установите WebView2 Runtime (кнопка ниже), затем запустите MG Helper снова.";
        body.Left = 24; body.Top = 66; body.Width = 660; body.Height = 110;
        form.Controls.Add(body);

        Label status = new Label();
        status.Left = 24; status.Top = 186; status.Width = 660; status.Height = 40;
        status.Text = StatusLine();
        form.Controls.Add(status);

        Button dl = new Button();
        dl.Text = "Скачать WebView2 Runtime";
        dl.Left = 24; dl.Top = 240; dl.Width = 220; dl.Height = 34;
        dl.Click += delegate { try { Process.Start("https://go.microsoft.com/fwlink/p/?LinkId=2124703"); } catch { } };
        form.Controls.Add(dl);

        Button open = new Button();
        open.Text = "Открыть папку MG Helper";
        open.Left = 256; open.Top = 240; open.Width = 220; open.Height = 34;
        open.Click += delegate { try { Process.Start("explorer.exe", "\"" + dataRoot + "\""); } catch { } };
        form.Controls.Add(open);

        Button diag = new Button();
        diag.Text = "Диагностика";
        diag.Left = 488; diag.Top = 240; diag.Width = 196; diag.Height = 34;
        diag.Click += delegate { RunScript("diagnose.ps1", "-NoOpenReport", false); };
        form.Controls.Add(diag);

        System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        timer.Interval = 2000;
        timer.Tick += delegate { status.Text = StatusLine(); };
        timer.Start();
        form.FormClosed += delegate { timer.Stop(); };

        BuildTray();
        if (smoke)
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                Thread.Sleep(1500);
                try { File.WriteAllText(Path.Combine(appDir, "ui-smoke.txt"), "ok=1 title=MG Helper fallback=1", new UTF8Encoding(false)); } catch { }
                try { form.BeginInvoke(new Action(delegate { Application.Exit(); })); } catch { Application.Exit(); }
            });
        }
    }

    private static string StatusLine()
    {
        try
        {
            Dictionary<string, object> health = ParseFlatJson(PipeStatusJson());
            if (Get(health, "ok") != "true")
            {
                health = ParseFlatJson(ReadText(Path.Combine(dataRoot, "watcher.health.json"), 0));
            }
            string status = Get(health, "status");
            if (string.IsNullOrEmpty(status)) return "Watcher: нет данных (проверьте задачу MG_Helper_Watcher)";
            double age = HealthAgeSec(health);
            string phase = Get(health, "phase");
            return "Watcher: " + status + " · фаза " + (string.IsNullOrEmpty(phase) ? "?" : phase) +
                   " · heartbeat " + (age < 0 ? "?" : Math.Round(age).ToString(CultureInfo.InvariantCulture) + " c");
        }
        catch { return "Watcher: нет данных"; }
    }

    private static void BuildWindow()
    {
        if (uiFallback)
        {
            Trace("building fallback window (WebView2 missing or forced)");
            BuildFallbackWindow();
            pollTimer = new System.Windows.Forms.Timer();
            pollTimer.Interval = 5000;
            pollTimer.Tick += delegate { if (tray != null) UpdateTray(ParseFlatJson(ReadText(Path.Combine(dataRoot, "watcher.health.json"), 0)), 0); };
            pollTimer.Start();
            return;
        }
        form = new Form();
        form.Text = "MG Helper " + UiVersion;
        form.Width = 1120;
        form.Height = 760;
        form.MinimumSize = new Size(940, 620);
        form.StartPosition = FormStartPosition.CenterScreen;
        form.BackColor = Color.FromArgb(15, 17, 21);
        form.Icon = LoadIcon();

        web = new WebView2();
        try
        {
            CoreWebView2CreationProperties props = new CoreWebView2CreationProperties();
            props.UserDataFolder = Path.Combine(dataRoot, "ui-data");
            web.CreationProperties = props;
            Trace("creation properties set");
        }
        catch (Exception ex) { Trace("creation props failed: " + ex.Message); }
        web.Dock = DockStyle.Fill;
        form.Controls.Add(web);

        web.CoreWebView2InitializationCompleted += OnWebReady;
        try
        {
            web.EnsureCoreWebView2Async(null);
        }
        catch (Exception ex)
        {
            Log("[!] WebView2 init failed: " + ex.Message);
            if (!smoke) MessageBox.Show("WebView2 Runtime не найден. Установите Microsoft Edge WebView2 Runtime.", "MG Helper", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        BuildTray();
        pollTimer = new System.Windows.Forms.Timer();
        pollTimer.Interval = 1000;
        pollTimer.Tick += delegate { PushState(); };
        pollTimer.Start();
    }

    private static void OnWebReady(object sender, CoreWebView2InitializationCompletedEventArgs e)
    {
        Trace("OnWebReady success=" + e.IsSuccess);
        if (!e.IsSuccess || web.CoreWebView2 == null) { Log("[!] WebView2 not ready"); return; }
        CoreWebView2 core = web.CoreWebView2;
        try
        {
            core.SetVirtualHostNameToFolderMapping("app.mghelper", uiDir, CoreWebView2HostResourceAccessKind.Allow);
        }
        catch (Exception ex) { Log("[!] virtual host mapping: " + ex.Message); }
        core.WebMessageReceived += OnWebMessage;
        if (smoke)
        {
            core.NavigationCompleted += OnSmokeNavigation;
        }
        Trace("navigate app.mghelper");
        core.Navigate("https://app.mghelper/index.html");
    }

    private static void OnSmokeNavigation(object sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        Trace("NavigationCompleted success=" + e.IsSuccess + " error=" + e.WebErrorStatus);
        if (!e.IsSuccess && smoke)
        {
            try { File.WriteAllText(Path.Combine(appDir, "ui-smoke.txt"), "error=navigation " + e.WebErrorStatus, new UTF8Encoding(false)); } catch { }
            Application.Exit();
        }
    }

    private static Icon LoadIcon()
    {
        try
        {
            string iconPath = Path.Combine(uiDir, "assets", "mghelper.ico");
            if (File.Exists(iconPath)) return new Icon(iconPath);
        }
        catch { }
        return MakeTrayIcon(Color.FromArgb(59, 165, 93));
    }

    private static Icon MakeTrayIcon(Color color)
    {
        Bitmap bmp = new Bitmap(32, 32);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using (SolidBrush b = new SolidBrush(color)) { g.FillEllipse(b, 2, 2, 28, 28); }
            using (SolidBrush w = new SolidBrush(Color.White)) { g.FillEllipse(w, 12, 12, 8, 8); }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ---------------- tray ----------------

    private static Icon TrayIconFor(string name, Color fallback)
    {
        try
        {
            string path = Path.Combine(uiDir, "assets", "tray-" + name + ".ico");
            if (File.Exists(path)) return new Icon(path);
        }
        catch { }
        return MakeTrayIcon(fallback);
    }

    private static void BuildTray()
    {
        trayGreen = TrayIconFor("green", Color.FromArgb(59, 165, 93));
        trayGold = TrayIconFor("gold", Color.Goldenrod);
        trayRed = TrayIconFor("red", Color.FromArgb(200, 70, 70));
        trayGray = TrayIconFor("gray", Color.Gray);
        trayIcon = trayGray;
        tray = new NotifyIcon();
        tray.Icon = trayIcon;
        tray.Text = "MG Helper " + UiVersion;
        tray.Visible = true;
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Открыть", null, delegate { ShowWindow(); });
        menu.Items.Add("Перезапустить watcher", null, delegate { Command("restart-watcher"); });
        menu.Items.Add("Диагностика", null, delegate { Command("diagnose"); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Выход", null, delegate { tray.Visible = false; Application.Exit(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { ShowWindow(); };
    }

    private static void ShowWindow()
    {
        if (form == null) return;
        form.Show();
        form.WindowState = FormWindowState.Normal;
        form.Activate();
    }

    // ---------------- state ----------------

    private static string ReadText(string path, int maxBytes)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader sr = new StreamReader(fs, new UTF8Encoding(false)))
            {
                string text = sr.ReadToEnd();
                if (maxBytes > 0 && text.Length > maxBytes) text = text.Substring(text.Length - maxBytes);
                return text;
            }
        }
        catch { return null; }
    }

    private static Dictionary<string, object> ParseFlatJson(string json)
    {
        Dictionary<string, object> map = new Dictionary<string, object>();
        if (string.IsNullOrEmpty(json)) return map;
        foreach (Match m in Regex.Matches(json, "\"([A-Za-z0-9_]+)\"\\s*:\\s*(?:\"([^\"]*)\"|(true|false|null)|(-?[0-9.]+))"))
        {
            string key = m.Groups[1].Value;
            if (m.Groups[2].Success) map[key] = m.Groups[2].Value;
            else if (m.Groups[3].Success) map[key] = m.Groups[3].Value;
            else if (m.Groups[4].Success) map[key] = m.Groups[4].Value;
        }
        return map;
    }

    private static double HealthAgeSec(Dictionary<string, object> health)
    {
        object hb;
        if (!health.TryGetValue("lastHeartbeatUtc", out hb) || hb == null) return -1;
        try
        {
            DateTime parsed = DateTime.Parse(Convert.ToString(hb), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
            return (DateTime.UtcNow - parsed.ToUniversalTime()).TotalSeconds;
        }
        catch { return -1; }
    }

    private static string BuildEventsJson()
    {
        string raw = ReadText(Path.Combine(dataRoot, "events.jsonl"), 40000);
        if (string.IsNullOrEmpty(raw)) return "[]";
        string[] lines = raw.Replace("\r", "").Split('\n');
        List<string> items = new List<string>();
        int start = Math.Max(0, lines.Length - 300);
        for (int i = start; i < lines.Length; i++)
        {
            string line = lines[i].Trim();
            if (line.Length == 0) continue;
            Dictionary<string, object> ev = ParseFlatJson(line);
            items.Add("{\"ts\":\"" + Json(Get(ev, "ts")) + "\",\"phase\":\"" + Json(Get(ev, "phase")) +
                      "\",\"event\":\"" + Json(Get(ev, "event")) + "\",\"data\":\"" + Json(Get(ev, "data")) + "\"}");
        }
        return "[" + string.Join(",", items.ToArray()) + "]";
    }

    private static string Get(Dictionary<string, object> map, string key)
    {
        object v;
        if (map.TryGetValue(key, out v) && v != null) return Convert.ToString(v, CultureInfo.InvariantCulture);
        return "";
    }

    private static string Json(string s)
    {
        if (s == null) return "";
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
    }

    private static string ReadConfigText()
    {
        string path = Path.Combine(dataRoot, "config.json");
        return ReadText(path, 0) ?? "";
    }

    private static string PipeStatusJson()
    {
        string pipeName = Environment.GetEnvironmentVariable("MG_HELPER_DIR") != null ? "MG_Helper_test" : "MG_Helper";
        try
        {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
            {
                pipe.Connect(1500);
                // do not dispose the writer/reader: their Dispose closes the pipe itself,
                // and the second close throws ObjectDisposedException (verified live)
                StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false));
                StreamReader reader = new StreamReader(pipe, new UTF8Encoding(false));
                writer.AutoFlush = true;
                writer.WriteLine("{\"cmd\":\"status\"}");
                string line = reader.ReadLine();
                return string.IsNullOrEmpty(line) ? null : line;
            }
        }
        catch { return null; }
    }

    private static void PushState()
    {
        if (web == null || web.CoreWebView2 == null) return;

        try
        {
            string healthJson = ReadText(Path.Combine(dataRoot, "watcher.health.json"), 0);
            string stateJson = ReadText(Path.Combine(dataRoot, "state.json"), 0);
            string configText = ReadConfigText();
            Dictionary<string, object> health = ParseFlatJson(healthJson);
            // живой опрос через Named Pipe; файл health остаётся резервом (ADR-003)
            bool fromPipe = false;
            string pipeLine = PipeStatusJson();
            if (!string.IsNullOrEmpty(pipeLine))
            {
                Dictionary<string, object> pipeMap = ParseFlatJson(pipeLine);
                if (Get(pipeMap, "ok") == "true" && Get(pipeMap, "lastHeartbeatUtc").Length > 0)
                {
                    health = pipeMap;
                    healthJson = pipeLine;
                    fromPipe = true;
                }
            }
            Dictionary<string, object> st = ParseFlatJson(stateJson);
            Dictionary<string, object> cfg = ParseFlatJson(configText);
            double age = HealthAgeSec(health);
            if (sourceLogged != (fromPipe ? "pipe" : "file"))
            {
                sourceLogged = fromPipe ? "pipe" : "file";
                Trace("state source=" + sourceLogged + " status=" + Get(health, "status"));
            }
            string version = UiVersion;
            string vf = Path.Combine(appDir, "version.json");
            string vtext = ReadText(vf, 0);
            if (!string.IsNullOrEmpty(vtext))
            {
                Dictionary<string, object> v = ParseFlatJson(vtext);
                if (Get(v, "version").Length > 0) version = Get(v, "version");
            }

            StringBuilder sb = new StringBuilder();
            sb.Append("{\"version\":\"").Append(Json(version)).Append("\",");
            sb.Append("\"health\":").Append(healthJson == null ? "null" :
                "{\"status\":\"" + Json(Get(health, "status")) + "\",\"phase\":\"" + Json(Get(health, "phase")) +
                "\",\"pid\":" + Digits(Get(health, "pid")) + ",\"ageSec\":" + (age < 0 ? "null" : Math.Round(age, 1).ToString(CultureInfo.InvariantCulture)) +
                ",\"lastHeartbeatUtc\":\"" + Json(Get(health, "lastHeartbeatUtc")) + "\",\"source\":\"" + (fromPipe ? "pipe" : "file") + "\"}").Append(",");
            sb.Append("\"state\":{\"phase\":\"").Append(Json(Get(st, "phase"))).Append("\",\"applied\":").Append(Get(st, "applied") == "true" ? "true" : "false");
            sb.Append(",\"guardRollbacks\":").Append(Digits(Get(st, "guardRollbacks")));
            sb.Append(",\"gamePid\":").Append(Digits(Get(st, "gamePid")));
            sb.Append(",\"lastApplyUtc\":\"").Append(Json(Get(st, "lastApplyUtc"))).Append("\"},");
            sb.Append("\"events\":").Append(BuildEventsJson()).Append(",");
            sb.Append("\"ui\":{\"config\":{\"allowAdopt\":").Append(Get(cfg, "allowAdopt") == "true" ? "true" : "false");
            sb.Append(",\"sessionGuard\":").Append(Get(cfg, "sessionGuard") == "false" ? "false" : "true");
            sb.Append(",\"guardWindowSec\":").Append(Digits(Get(cfg, "guardWindowSec")));
            sb.Append("},\"autoSend\":").Append(Get(cfg, "autoSendReports") == "false" ? "false" : "true");
            sb.Append(",\"autostart\":").Append(AutostartEnabled() ? "true" : "false").Append("}}");

            string script = "window.mg && window.mg.update(" + sb.ToString() + ");";
            web.CoreWebView2.ExecuteScriptAsync(script);

            UpdateTray(health, age);
        }
        catch (Exception ex) { Log("[!] push state: " + ex.Message); }
    }

    private static string Digits(string s)
    {
        if (string.IsNullOrEmpty(s) || s == "null") return "null";
        string digits = Regex.Replace(s, "[^0-9]", "");
        return digits.Length == 0 ? "null" : digits;
    }

    private static void UpdateTray(Dictionary<string, object> health, double age)
    {
        if (tray == null) return;
        string phase = Get(health, "phase");
        string status = Get(health, "status");
        Color color = Color.Gray;
        string tip = "MG Helper: нет данных";
        if (status == "running" && age >= 0 && age <= 15)
        {
            if (phase == "UnknownSession") { color = Color.Goldenrod; tip = "MG Helper: SAFE MODE (защита выключена)"; }
            else { color = Color.FromArgb(59, 165, 93); tip = "MG Helper: защищено (" + (phase == "InGame" ? "игра запущена" : "ожидание") + ")"; }
        }
        else if (status == "running" && age > 15 && age <= 30) { color = Color.Goldenrod; tip = "MG Helper: watcher не отвечает"; }
        else { color = Color.FromArgb(200, 70, 70); tip = "MG Helper: watcher не работает"; }
        try
        {
            Icon next = trayGray;
            if (color.R == 59) { next = trayGreen; }
            else if (color.R == 218 || color.R == 217) { next = trayGold; }
            else if (color.R >= 190) { next = trayRed; }
            if (tray.Icon != next) { tray.Icon = next; }
            if (tip.Length > 63) tip = tip.Substring(0, 63);
            tray.Text = tip;
        }
        catch { }
    }

    private static bool AutostartEnabled()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("schtasks", "/Query /TN MG_Helper_Watcher");
            psi.CreateNoWindow = true; psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit(3000);
                return p.ExitCode == 0;
            }
        }
        catch { return false; }
    }

    // ---------------- messages ----------------

    private static void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            string json = e.WebMessageAsJson;
            Trace("message: " + json);
            Dictionary<string, object> msg = ParseFlatJson(json);
            string type = Get(msg, "type");
            Trace("parsed keys=" + msg.Count + " type=[" + type + "]");
            if (type == "ui-ready")
            {
                Trace("ui-ready title=" + Get(msg, "title") + " bridge=" + Get(msg, "bridge"));
                if (!string.IsNullOrEmpty(shotDir))
                {
                    form.BeginInvoke(new Action(TakeScreenshots));
                }
                if (smoke)
                {
                    try { File.WriteAllText(Path.Combine(appDir, "ui-smoke.txt"), "ok=1 title=" + Get(msg, "title") + " bridge=" + Get(msg, "bridge"), new UTF8Encoding(false)); } catch { }
                    form.BeginInvoke(new Action(delegate { Application.Exit(); }));
                }
                return;
            }
            string cmd = Get(msg, "cmd");
            Command(cmd, msg);
        }
        catch (Exception ex) { Log("[!] message: " + ex.Message); }
    }

    private static void TakeScreenshots()
    {
        try
        {
            Directory.CreateDirectory(shotDir);
            Shot("ui-dark.png", "document.body.classList.remove('light')");
            Thread.Sleep(500);
            Shot("ui-light.png", "document.body.classList.add('light')");
            Thread.Sleep(700);
        }
        catch (Exception ex) { Trace("shots failed: " + ex.Message); }
        finally { try { form.BeginInvoke(new Action(delegate { Application.Exit(); })); } catch { Application.Exit(); } }
    }

    private static void Shot(string fileName, string script)
    {
        string path = Path.Combine(shotDir, fileName);
        try
        {
            System.Threading.Tasks.Task<string> scriptTask = web.CoreWebView2.ExecuteScriptAsync(script);
            scriptTask.Wait(5000);
            form.Activate();
            form.TopMost = true;
            form.TopMost = false;
            Thread.Sleep(700);
            bool captured = false;
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
                {
                    System.Threading.Tasks.Task shotTask = web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
                    shotTask.Wait(8000);
                }
                captured = File.Exists(path) && new FileInfo(path).Length > 1000;
            }
            catch (Exception ex) { Trace("CapturePreview failed: " + ex.Message); }
            if (!captured) CaptureWindow(path);
            Trace("shot " + fileName + " bytes=" + (File.Exists(path) ? new FileInfo(path).Length.ToString() : "0"));
        }
        catch (Exception ex) { Trace("shot " + fileName + " failed: " + ex.Message); }
    }

    private static void CaptureWindow(string path)
    {
        try
        {
            Rectangle bounds = form.Bounds;
            using (Bitmap bmp = new Bitmap(bounds.Width, bounds.Height))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
        catch (Exception ex) { Trace("window capture failed: " + ex.Message); }
    }

    private static void Notify(string text)
    {
        try
        {
            if (web != null && web.CoreWebView2 != null)
                web.CoreWebView2.ExecuteScriptAsync("window.mg && window.mg.status(" + JsonString(text) + ");");
        }
        catch { }
        if (tray != null && !smoke) { tray.BalloonTipTitle = "MG Helper"; tray.BalloonTipText = text; tray.ShowBalloonTip(2500); }
    }

    private static string JsonString(string s) { return "\"" + Json(s) + "\""; }

    private static void RequestFile(string name)
    {
        File.WriteAllText(Path.Combine(dataRoot, name), DateTime.UtcNow.ToString("o"), new UTF8Encoding(false));
    }

    private static void Command(string cmd, Dictionary<string, object> msg = null)
    {
        if (string.IsNullOrEmpty(cmd)) return;
        try
        {
            switch (cmd)
            {
                case "restart-watcher":
                    RequestFile("stop.request");
                    Notify("Перезапускаю watcher…");
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        Thread.Sleep(3500);
                        RunHidden("schtasks", "/Run /TN MG_Helper_Watcher");
                        Thread.Sleep(2500);
                        Notify("Watcher перезапущен");
                    });
                    break;
                case "reload-config":
                    RequestFile("reload.request");
                    Notify("Конфиг перечитан");
                    break;
                case "apply-golden":
                    RequestFile("apply.request");
                    Notify("Эталон применён");
                    break;
                case "diagnose":
                    RunScript("diagnose.ps1", "-NoOpenReport", false);
                    Notify("Диагностика: отчёт сохранён в папке MG Helper");
                    break;
                case "send-report":
                    RunScript("diagnose.ps1", "-NoOpenReport -Send", false);
                    Notify("Отчёт отправлен (если настроена отправка)");
                    break;
                case "open-folder":
                    Process.Start("explorer.exe", "\"" + dataRoot + "\"");
                    break;
                case "new-golden":
                    RunScript("reset-settings.ps1", "", true);
                    break;
                case "reset-settings":
                    RunScript("repair.ps1", "", true);
                    break;
                case "restore-mg":
                    RunScript("restore-mg-snapshot.ps1", "", true);
                    break;
                case "open-menu":
                    string bat = Path.Combine(dataRoot, "MG-Helper.bat");
                    if (File.Exists(bat)) Process.Start(bat);
                    else Notify("MG-Helper.bat не найден");
                    break;
                case "save-config":
                    SaveConfig(msg);
                    Notify("Настройки сохранены");
                    break;
                case "set-autosend":
                    SetJsonBool(Path.Combine(dataRoot, "config.json"), "autoSendReports", Get(msg, "value") == "true");
                    break;
            }
        }
        catch (Exception ex) { Log("[!] command " + cmd + ": " + ex.Message); Notify("Ошибка: " + ex.Message); }
    }

    // ---------------- установка (нативный финализатор) ----------------
    // Установщик вызывает MGHelper.exe --install-finalize: никаких консольных окон и
    // никакого PowerShell на пути установки (раньше окно PowerShell висело на экране).
    private static int InstallFinalize()
    {
        try
        {
            string versionDir = appDir;
            string versionsDir = Path.GetDirectoryName(versionDir);
            string installRoot = Path.GetDirectoryName(versionsDir);
            string data = Environment.GetEnvironmentVariable("MG_HELPER_DIR");
            bool sandbox = !string.IsNullOrEmpty(data);
            if (sandbox) data = Path.GetFullPath(data);
            else data = Path.GetDirectoryName(installRoot);

            string version = UiVersion;
            string vf = Path.Combine(versionDir, "version.json");
            if (File.Exists(vf))
            {
                Dictionary<string, object> v = ParseFlatJson(ReadText(vf, 0));
                if (Get(v, "version").Length > 0) version = Get(v, "version");
            }

            NotifyInstallLine("[*] MG Helper " + version + " (version dir: " + versionDir + ")");

            // 1. остановить старый watcher: флаг + завершение задачи
            try { File.WriteAllText(Path.Combine(data, "stop.request"), DateTime.UtcNow.ToString("o"), new UTF8Encoding(false)); } catch { }
            RunHidden("schtasks", "/End /TN MG_Helper_Watcher");
            Thread.Sleep(1200);

            // 2. указатель версии
            string currentFile = Path.Combine(installRoot, "current.json");
            string payload = "{\"version\":\"" + Json(version) + "\",\"path\":\"Versions\\\\" + Json(version) +
                             "\",\"updated\":\"" + Json(DateTime.UtcNow.ToString("o")) + "\"}";
            string tmp = currentFile + ".tmp";
            File.WriteAllText(tmp, payload, new UTF8Encoding(false));
            if (File.Exists(currentFile)) File.Delete(currentFile);
            File.Move(tmp, currentFile);
            NotifyInstallLine("[+] current.json -> " + version);

            // 3. скрипты поддержки в DataRoot
            string[] tooling = new string[] {
                "common.ps1", "MgHelper.Core.ps1", "gta-settings-watcher.ps1", "MG-Helper.ps1", "MG-Helper.bat",
                "diagnose.ps1", "uninstall.ps1", "repair.ps1", "reset-settings.ps1", "import-settings.ps1",
                "clean-majestic-cache.ps1", "max-fps.ps1", "cut-shadows.ps1", "restore-mg-snapshot.ps1",
                "restore-golden-history.ps1", "save-custom-profile.ps1", "apply-custom-profile.ps1",
                "update-helper.ps1", "install-gta-watcher.ps1", "install-3.0.ps1", "install-3.1.ps1"
            };
            int copied = 0;
            foreach (string name in tooling)
            {
                string src = Path.Combine(versionDir, name);
                if (!File.Exists(src)) continue;
                try { File.Copy(src, Path.Combine(data, name), true); copied++; } catch { }
            }
            File.WriteAllText(Path.Combine(data, "version.json"), "{\r\n    \"version\": \"" + Json(version) + "\"\r\n}", new UTF8Encoding(false));
            NotifyInstallLine("[+] скрипты поддержки обновлены (" + copied + "), данные не тронуты");

            // 4. автозапуск: задача watcher'а + ярлык приложения
            if (!sandbox)
            {
                string watcherExe = Path.Combine(versionDir, "MGHelper.Watcher.exe");
                if (File.Exists(watcherExe))
                {
                    RunHidden("schtasks", "/Create /F /SC MINUTE /MO 10 /TN MG_Helper_Watcher /TR \"" + watcherExe + "\"");
                    RunHidden("schtasks", "/Run /TN MG_Helper_Watcher");
                }
                try
                {
                    string startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                    if (!string.IsNullOrEmpty(startup) && Directory.Exists(startup))
                    {
                        string appExe = Path.Combine(versionDir, "MGHelper.exe");
                        string lnk = Path.Combine(startup, "MG Helper.lnk");
                        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                        object shell = Activator.CreateInstance(shellType);
                        object shortcut = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
                        Type sc = shortcut.GetType();
                        sc.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { appExe });
                        sc.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { versionDir });
                        sc.InvokeMember("IconLocation", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { Path.Combine(versionDir, "ui", "assets", "mghelper.ico") });
                        sc.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] { "MG Helper - защита настроек GTA V" });
                        sc.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, shortcut, null);
                    }
                }
                catch (Exception ex) { NotifyInstallLine("[!] ярлык автозапуска: " + ex.Message); }
            }

            // 5. отчёт об установке
            string report = "{\"schema\":1,\"to\":\"" + Json(version) + "\",\"at\":\"" + Json(DateTime.UtcNow.ToString("o")) +
                            "\",\"layout\":{\"installRoot\":\"" + Json(installRoot) + "\",\"dataRoot\":\"" + Json(data) +
                            "\",\"versionDir\":\"" + Json(versionDir) + "\"},\"dataRootUntouched\":true,\"toolingCopied\":" + copied + "}";
            File.WriteAllText(Path.Combine(data, "migration-report.json"), report, new UTF8Encoding(false));
            NotifyInstallLine("[+] установка " + version + " завершена");

            // 6. запустить приложение (если не просили обратное)
            if (sandbox || (Environment.GetCommandLineArgs() != null && Array.IndexOf(Environment.GetCommandLineArgs(), "--no-start") >= 0))
            {
                return 0;
            }
            try { Process.Start(Path.Combine(versionDir, "MGHelper.exe")); } catch { }
            return 0;
        }
        catch (Exception ex)
        {
            NotifyInstallLine("[!] установка не завершена: " + ex.Message);
            return 1;
        }
    }

    private static void NotifyInstallLine(string text)
    {
        try
        {
            string logPath = Path.Combine(dataRoot ?? appDir, "install.log");
            File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + text + "\r\n", new UTF8Encoding(true));
        }
        catch { }
    }

    private static void RunHidden(string exe, string args)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.CreateNoWindow = true; psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi)) { p.WaitForExit(15000); }
        }
        catch (Exception ex) { Log("[!] run " + exe + ": " + ex.Message); }
    }

    private static void RunScript(string name, string extraArgs, bool visible)
    {
        string script = Path.Combine(dataRoot, name);
        if (!File.Exists(script)) { Notify("Скрипт не найден: " + name); return; }
        ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"));
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + extraArgs;
        psi.UseShellExecute = visible;
        psi.CreateNoWindow = !visible;
        if (visible) psi.WindowStyle = ProcessWindowStyle.Normal;
        Process.Start(psi);
    }

    private static void SaveConfig(Dictionary<string, object> msg)
    {
        string path = Path.Combine(dataRoot, "config.json");
        if (!File.Exists(path)) { Notify("config.json не найден"); return; }
        SetJsonBool(path, "allowAdopt", Get(msg, "allowAdopt") == "true");
        SetJsonBool(path, "sessionGuard", !(Get(msg, "sessionGuard") == "false"));
        SetJsonInt(path, "guardWindowSec", Get(msg, "guardWindowSec"));
        RequestFile("reload.request");
    }

    private static void SetJsonBool(string path, string key, bool value)
    {
        string text = File.ReadAllText(path);
        string literal = value ? "true" : "false";
        string pattern = "\"" + key + "\"\\s*:\\s*(true|false)";
        if (Regex.IsMatch(text, pattern)) text = Regex.Replace(text, pattern, "\"" + key + "\": " + literal);
        else text = InsertKey(text, key, literal);
        File.WriteAllText(path, text, new UTF8Encoding(false));
    }

    private static void SetJsonInt(string path, string key, string value)
    {
        if (string.IsNullOrEmpty(value)) return;
        string digits = Regex.Replace(value, "[^0-9]", "");
        if (digits.Length == 0) return;
        string text = File.ReadAllText(path);
        string pattern = "\"" + key + "\"\\s*:\\s*(-?[0-9]+)";
        if (Regex.IsMatch(text, pattern)) text = Regex.Replace(text, pattern, "\"" + key + "\": " + digits);
        else text = InsertKey(text, key, digits);
        File.WriteAllText(path, text, new UTF8Encoding(false));
    }

    private static string InsertKey(string json, string key, string literal)
    {
        int idx = json.LastIndexOf('}');
        if (idx < 0) return json;
        string head = json.Substring(0, idx).TrimEnd();
        string sep = head.EndsWith("{") ? "" : ",";
        return head + sep + "\r\n    \"" + key + "\": " + literal + "\r\n" + json.Substring(idx);
    }

    private static void Trace(string message)
    {
        try
        {
            File.AppendAllText(Path.Combine(appDir, "ui-trace.log"),
                DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + "  " + message + "\r\n",
                new UTF8Encoding(false));
        }
        catch { }
    }
    private static void Log(string line)
    {
        try
        {
            File.AppendAllText(Path.Combine(dataRoot, "ui.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + line + "\r\n",
                new UTF8Encoding(true));
        }
        catch { }
    }
}