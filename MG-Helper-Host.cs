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
        // first non-flag argument is the script (args[0] may be the -Smoke flag)
        string script = Path.Combine(dir, "gta-settings-watcher.ps1");
        foreach (var a in args) { if (!a.StartsWith("-")) { script = a; break; } }
        if (!File.Exists(script)) return 2;

        // installer smoke mode: -Smoke bypasses the mutex check so the launchability
        // test is real even while the watcher already holds the mutex
        bool smoke = false;
        foreach (var a in args) if (a == "-Smoke") smoke = true;

        // watchdog tick: watcher already owns the mutex -> spawn NOTHING, exit silently.
        // try/catch: a hostile/broken mutex DACL must not produce a WER dialog
        // over a fullscreen game - treat as "watcher alive" and exit quietly.
        if (!smoke) {
            try {
                Mutex m;
                if (Mutex.TryOpenExisting(@"Local\MG_Helper_Watcher", out m)) { m.Dispose(); return 0; }
            } catch { return 0; }
        }

        var psi = new ProcessStartInfo();
        psi.FileName  = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                     @"WindowsPowerShell\v1.0\powershell.exe");
        psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        psi.WorkingDirectory   = Path.GetDirectoryName(script);
        psi.UseShellExecute    = false;
        psi.CreateNoWindow     = true;   // no console is created at all
        psi.WindowStyle        = ProcessWindowStyle.Hidden;

        try {
            var p = Process.Start(psi);
            p.WaitForExit();                 // task lifetime == watcher lifetime
            return p.ExitCode;
        } catch {
            return 3;   // powershell.exe missing/blocked - no WER dialog, task retries later
        }
    }
}
