// MG Helper hidden host - by Bayra & Kavel1n
// GUI-subsystem (winexe) micro-host: creates NO console window at all, so the
// scheduled task can spawn the watcher without a 50-300 ms conhost flash that
// would steal focus and minimise a fullscreen game.
// Bonus: it checks the watcher mutex first - a watchdog tick while the watcher
// is alive spawns NOTHING and exits silently. The task stays "Running" for the
// watcher's lifetime (WaitForExit), so IgnoreNew silences duplicates and the
// next 10-min tick restarts a dead watcher automatically.
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

static class Program {
    static int Main(string[] args) {
        string dir    = AppDomain.CurrentDomain.BaseDirectory;
        string script = args.Length > 0 ? args[0] : Path.Combine(dir, "gta-settings-watcher.ps1");
        if (!File.Exists(script)) return 2;

        // watchdog tick: watcher already owns the mutex -> spawn NOTHING, exit silently
        Mutex m;
        if (Mutex.TryOpenExisting(@"Local\MG_Helper_Watcher", out m)) { m.Dispose(); return 0; }

        var psi = new ProcessStartInfo();
        psi.FileName  = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                     @"WindowsPowerShell\v1.0\powershell.exe");
        psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        psi.WorkingDirectory   = Path.GetDirectoryName(script);
        psi.UseShellExecute    = false;
        psi.CreateNoWindow     = true;   // no console is created at all
        psi.WindowStyle        = ProcessWindowStyle.Hidden;

        var p = Process.Start(psi);
        p.WaitForExit();                 // task lifetime == watcher lifetime
        return p.ExitCode;
    }
}
