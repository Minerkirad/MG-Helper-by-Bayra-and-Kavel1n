// MG Helper tray - by Bayra & Kavel1n
// net48 WinForms NotifyIcon (ROADMAP 5.1): status tooltip from the watcher's
// OWN files (watcher.ready / state.json / events.jsonl - single-writer, no
// IPC races), balloon notifications on key events (ROADMAP 3.2 health model:
// a hung watcher is RED right in the tray), and an action menu that launches
// the existing helper scripts. Compiled at install from this readable source.
using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using System.Diagnostics;

static class Program
{
    static string helperDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MG_Helper");
    static NotifyIcon tray;
    static string lastSeenEventLine = null;
    static string cursorFile = Path.Combine(helperDir, "tray_cursor.txt");

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try { if (File.Exists(cursorFile)) lastSeenEventLine = File.ReadAllText(cursorFile); } catch { }

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
        menu.Items.Add("Выход (иконка)", null, (s, e) => { tray.Visible = false; Application.Exit(); });

        tray = new NotifyIcon
        {
            Icon = MakeIcon(Color.Gray),
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
        bool ready = File.Exists(Path.Combine(helperDir, "watcher.ready"));
        string phase = "Idle";
        try
        {
            var st = File.ReadAllText(Path.Combine(helperDir, "state.json"));
            if (st.Contains("\"UnknownSession\"")) phase = "UnknownSession";
            else if (st.Contains("\"InGame\"")) phase = "InGame";
        }
        catch { }

        Color color;
        string tip;
        if (!ready && !WatchProcessAlive())
        {
            color = Color.Red;
            tip = "MG Helper - WATCHER НЕ РАБОТАЕТ (меню [9] Repair)";
        }
        else if (phase == "InGame")
        {
            color = Color.Green;
            tip = "MG Helper - Защищено (игра запущена)";
        }
        else
        {
            color = Color.Green;
            tip = "MG Helper - Защищено (ожидание)";
        }

        try
        {
            tray.Icon = MakeIcon(color);
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        }
        catch { }

        CheckEvents();
    }

    static bool WatchProcessAlive()
    {
        try
        {
            foreach (var p in Process.GetProcessesByName("powershell"))
                if ((p.MainWindowTitle ?? "") != "" || IsWatcherCmdline(p.Id)) return true;
            foreach (var p in Process.GetProcessesByName("pwsh"))
                if (IsWatcherCmdline(p.Id)) return true;
        }
        catch { }
        return false;
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

    static void CheckEvents()
    {
        string ef = Path.Combine(helperDir, "events.jsonl");
        if (!File.Exists(ef)) return;
        string[] lines;
        try { lines = File.ReadAllLines(ef); } catch { return; }
        if (lines.Length == 0) return;
        string last = lines[lines.Length - 1];
        if (last == lastSeenEventLine) return;
        bool firstRun = (lastSeenEventLine == null);
        lastSeenEventLine = last;
        try { File.WriteAllText(cursorFile, last); } catch { }
        if (firstRun) return;   // do not spam on tray start

        string msg = null; ToolTipIcon ico = ToolTipIcon.Info;
        if (last.Contains("golden.applied")) msg = "Настройки графики применены";
        else if (last.Contains("adopt.accepted")) { msg = "Изменения в игре сохранены как новый эталон"; ico = ToolTipIcon.Info; }
        else if (last.Contains("guard.rollback")) { msg = "Чужая перезапись настроек откачена"; ico = ToolTipIcon.Warning; }
        else if (last.Contains("insurance.restored")) msg = "Бэкапы .bin возвращены лаунчеру";
        else if (last.Contains("insurance.risk")) { msg = "Риск ошибки 1002 при следующем запуске Majestic!"; ico = ToolTipIcon.Error; }
        else if (last.Contains("golden.mismatch")) { msg = "Сменилась игра/GPU - создай новый эталон (меню [11])"; ico = ToolTipIcon.Warning; }
        else if (last.Contains("\"error\"")) { msg = "Ошибка в watcher - см. диагностику"; ico = ToolTipIcon.Error; }
        if (msg != null)
        {
            try { tray.BalloonTipTitle = "MG Helper"; tray.BalloonTipText = msg; tray.BalloonTipIcon = ico; tray.ShowBalloonTip(5000); } catch { }
        }
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
