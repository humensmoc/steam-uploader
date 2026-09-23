// Offline process fixture. Never invokes Steam, Unity or the network.
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
public static class FakeTools
{
    private static string Field(string text, string key)
    {
        return Regex.Match(text, "\"" + key + "\"\\s+\"([^\"]*)\"", RegexOptions.IgnoreCase).Groups[1].Value;
    }
    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        string mode = Environment.GetEnvironmentVariable("SP_FAKE_MODE") ?? "success";
        if (args.Length > 0 && args[0] == "--progress-log")
        {
            // A quiet child that reports only through a shared log, like Unity.
            File.WriteAllText(args[1], "[SteamUploader] Stage: Addressables\n");
            System.Threading.Thread.Sleep(1100);
            File.AppendAllText(args[1], "[SteamUploader] Stage: Player\n");
            System.Threading.Thread.Sleep(1100);
            return 5;
        }
        if (args.Length > 0 && args[0] == "--progress-output")
        {
            Console.Write("Uploading content (30.");
            Console.Out.Flush();
            System.Threading.Thread.Sleep(100);
            Console.Write("5%)\r");
            Console.Out.Flush();
            System.Threading.Thread.Sleep(1100);
            Console.Error.Write("Committing build...\n");
            return 0;
        }
        if (args.Length > 0 && args[0] == "--echo")
        {
            for (int i = 1; i < args.Length; i++)
                Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
            return 0;
        }
        int requestIndex = Array.IndexOf(args, "-steamUploaderRequest");
        if (requestIndex >= 0)
        {
            var serializer = new JavaScriptSerializer();
            var request = serializer.Deserialize<System.Collections.Generic.Dictionary<string, object>>(File.ReadAllText(args[requestIndex + 1]));
            string content = (string)request["output"];
            Directory.CreateDirectory(content);
            byte[] pe = new byte[128];
            pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64;
            pe[64] = 0x50; pe[65] = 0x45; pe[68] = 0x64; pe[69] = 0x86;
            File.WriteAllBytes(Path.Combine(content, "Game.exe"), pe);
            File.WriteAllText((string)request["report"], serializer.Serialize(new {
                succeeded = mode != "buildfail", errors = mode == "buildfail" ? 1 : 0,
                warnings = 0, executable = "Game.exe", message = mode
            }));
            int logIndex = Array.IndexOf(args, "-logFile");
            if (logIndex >= 0) File.WriteAllText(args[logIndex + 1], "OFFLINE MOCK BUILD " + mode);
            Console.WriteLine("OFFLINE MOCK BUILD");
            return mode == "buildfail" ? 5 : 0;
        }
        if (mode == "loginfail") { Console.WriteLine("Login Failure: Invalid Password"); return 5; }
        if (mode == "network") { Console.WriteLine("FAILED: no connection"); return 1; }
        if (mode == "cancel") { Console.WriteLine("Login cancelled"); return 0; }
        if (mode == "guard") Console.Write("Steam Guard code (simulated native prompt): ");
        if (mode == "guardread")
        {
            Console.Write("Steam Guard code (offline stdin test): ");
            if (Console.ReadLine() != "123456") return 9;
            Console.WriteLine("Guard input received");
        }
        Console.WriteLine("Waiting for user info...OK");
        int vdfIndex = Array.IndexOf(args, "+run_app_build");
        if (vdfIndex < 0) return 0;
        string config = File.ReadAllText(args[vdfIndex + 1]);
        string output = Field(config, "BuildOutput");
        string app = Field(config, "AppID");
        string depot = Regex.Match(config, "\"Depots\"\\s*\\{\\s*\"([0-9]+)\"").Groups[1].Value;
        Directory.CreateDirectory(output);
        if (mode == "stale") return 0;
        bool preview = Field(config, "Preview") == "1" || mode == "previewonly";
        string log = preview
            ? "Successfully finished AppID " + app + " build preview."
            : "Successfully finished AppID " + app + " build (BuildID 12345678).";
        File.WriteAllText(Path.Combine(output, "app_build_" + app + ".log"), log);
        File.WriteAllText(Path.Combine(output, "depot_build_" + depot + ".log"), "OFFLINE MOCK DEPOT");
        if (!preview)
            File.WriteAllText(Path.Combine(output, "depot_build_" + depot + ".vdf"),
                "\"depotbuild\" { \"appid\" \"" + (mode == "wrongmanifest" ? "1" : app) +
                "\" \"depotid\" \"" + depot + "\" \"manifest\" \"9876543210987654321\" }");
        return mode == "badexit" ? 7 : 0;
    }
}
