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
    private static string shotDir;

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
        using (Mutex mutex = new Mutex(true, "Local\\MG_Helper_UI", out isFirst))
        {
            if (!isFirst) return 0;
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

    private static void BuildWindow()
    {
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

    private static void PushState()
    {
        if (web == null || web.CoreWebView2 == null) return;
        try
        {
            string healthJson = ReadText(Path.Combine(dataRoot, "watcher.health.json"), 0);
            string stateJson = ReadText(Path.Combine(dataRoot, "state.json"), 0);
            string configText = ReadConfigText();
            Dictionary<string, object> health = ParseFlatJson(healthJson);
            Dictionary<string, object> st = ParseFlatJson(stateJson);
            Dictionary<string, object> cfg = ParseFlatJson(configText);
            double age = HealthAgeSec(health);
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
                ",\"lastHeartbeatUtc\":\"" + Json(Get(health, "lastHeartbeatUtc")) + "\"}").Append(",");
            sb.Append("\"state\":{\"phase\":\"").Append(Json(Get(st, "phase"))).Append("\",\"applied\":").Append(Get(st, "applied") == "true" ? "true" : "false");
            sb.Append(",\"guardRollbacks\":").Append(Digits(Get(st, "guardRollbacks")));
            sb.Append(",\"gamePid\":").Append(Digits(Get(st, "gamePid")));
            sb.Append(",\"lastApplyUtc\":\"").Append(Json(Get(st, "lastApplyUtc"))).Append("\"},");
            sb.Append("\"events\":").Append(BuildEventsJson()).Append(",");
            sb.Append("\"ui\":{\"config\":{\"allowAdopt\":").Append(Get(cfg, "allowAdopt") == "true" ? "true" : "false");
            sb.Append(",\"sessionGuard\":").Append(Get(cfg, "sessionGuard") == "false" ? "false" : "true");
            sb.Append(",\"guardWindowSec\":").Append(Digits(Get(cfg, "guardWindowSec")));
            sb.Append("},\"autoSend\":").Append(Get(cfg, "autoSendReports") == "true" ? "true" : "false");
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