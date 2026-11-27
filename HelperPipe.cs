// ============================================================
//  HelperPipe.cs - Named Pipe command surface for MG Helper 3.0 (stage 5a)
//  by Bayra & Kavel1n
//
//  The pipe is a thin, stateless command surface over the DataRoot files:
//    {"cmd":"status"}        -> {"ok":true,"status":<watcher.health.json>,...}
//    {"cmd":"stop"}          -> creates stop.request   (the watcher stops on its next tick)
//    {"cmd":"reload-config"} -> creates reload.request (re-read config.json)
//    {"cmd":"apply-golden"}  -> creates apply.request  (apply the golden now)
//  Command channels are the same files the file fallback uses, so a watcher that
//  does not speak the pipe keeps working (ADR-003 keeps the file path for one
//  release). Only the current user can open the pipe: the ACL grants that SID and
//  nothing else, and maxNumberOfServerInstances is 1 (one queue, no fan-out).
//
//  Built with Add-Type -TypeDefinition (PS 5.1 / net48, C# 5, no new dependencies).
// ============================================================
using System;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class MgPipe
{
    public const string DefaultName = "MG_Helper";

    private static Thread worker;
    private static volatile bool running;
    private static string pipeName;
    private static string helperDir;/***/
    private static string lastError;

    public static string LastError { get { return lastError; } }
    public static bool IsRunning { get { return running; } }

    public static bool Start(string name, string dataDir)
    {
        if (running) return true;
        if (string.IsNullOrEmpty(name)) name = DefaultName;
        if (string.IsNullOrEmpty(dataDir) || !Directory.Exists(dataDir)) return false;
        pipeName = name;
        helperDir = dataDir;
        running = true;
        worker = new Thread(Loop);
        worker.IsBackground = true;
        worker.Name = "MgPipe";
        worker.Start();
        return true;
    }

    public static void Stop()
    {
        running = false;
        // wake a blocking WaitForConnection: connect to ourselves and disconnect
        try
        {
            using (NamedPipeClientStream probe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
            {
                probe.Connect(200);
            }
        }
        catch { }
        try { if (worker != null) worker.Join(500); } catch { }
    }

    private static NamedPipeServerStream CreateServer()
    {
        PipeSecurity security = new PipeSecurity();
        WindowsIdentity identity = WindowsIdentity.GetCurrent();
        if (identity != null && identity.User != null)
        {
            security.AddAccessRule(new PipeAccessRule(identity.User, PipeAccessRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        }
        return new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.None, 4096, 4096, security);
    }

    private static void Loop()
    {
        while (running)
        {
            try
            {
                using (NamedPipeServerStream server = CreateServer())
                {
                    server.WaitForConnection();
                    string request = ReadLine(server);
                    string response = Handle(request);
                    WriteLine(server, response);
                    server.WaitForPipeDrain();
                }
            }
            catch (Exception ex)
            {
                lastError = ex.Message;
                if (!running) break;
                Thread.Sleep(200);
            }
        }
    }

    private static string ReadLine(Stream stream)
    {
        StringBuilder sb = new StringBuilder();
        byte[] buffer = new byte[1024];
        while (true)
        {
            int read = stream.Read(buffer, 0, buffer.Length);
            if (read <= 0) break;
            for (int i = 0; i < read; i++)
            {
                if (buffer[i] == (byte)'\n') return sb.ToString();
                sb.Append((char)buffer[i]);
            }
            if (sb.Length > 8192) break;
        }
        return sb.ToString();
    }

    private static void WriteLine(Stream stream, string text)
    {
        byte[] bytes = new UTF8Encoding(false).GetBytes(text + "\n");
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    private static string Handle(string request)
    {
        string cmd = ExtractCommand(request);
        try
        {
            switch (cmd)
            {
                case "status":
                    {
                        string health = ReadHealth();
                        if (health == null) return "{\"ok\":false,\"error\":\"no health file\"}";
                        return "{\"ok\":true,\"status\":" + health + "}";
                    }
                case "stop":
                    return Touch("stop.request", "stop requested");
                case "reload-config":
                    return Touch("reload.request", "reload requested");
                case "apply-golden":
                    return Touch("apply.request", "apply requested");
                default:
                    return "{\"ok\":false,\"error\":\"unknown cmd\"}";
            }
        }
        catch (Exception ex)
        {
            return "{\"ok\":false,\"error\":\"" + Escape(ex.Message) + "\"}";
        }
    }

    private static string ExtractCommand(string json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        Match match = Regex.Match(json, "\"cmd\"\\s*:\\s*\"([A-Za-z-]+)\"");
        if (!match.Success) return null;
        return match.Groups[1].Value.ToLowerInvariant();
    }

    private static string ReadHealth()
    {
        string path = Path.Combine(helperDir, "watcher.health.json");
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false)))
                {
                    return reader.ReadToEnd().Trim();
                }
            }
            catch (IOException) { Thread.Sleep(60); }
            catch (UnauthorizedAccessException) { Thread.Sleep(60); }
        }
        return null;
    }

    private static string Touch(string fileName, string message)
    {
        string path = Path.Combine(helperDir, fileName);
        File.WriteAllText(path, DateTime.UtcNow.ToString("o"), new UTF8Encoding(false));
        return "{\"ok\":true,\"message\":\"" + Escape(message) + "\"}";
    }

    private static string Escape(string text)
    {
        if (text == null) return "";
        return text.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
    }
}