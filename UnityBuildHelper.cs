// Copied temporarily into the selected project's Assets/<owned-id>/Editor.
// No project-specific version, edition, define symbols or backend is changed.
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class SteamUploaderBuild
{
    [Serializable]
    private sealed class Request
    {
        public string output;
        public string report;
        public bool development;
    }

    [Serializable]
    private sealed class Result
    {
        public bool succeeded;
        public string executable;
        public string unityVersion;
        public string bundleVersion;
        public string addressables;
        public string message;
        public int errors;
        public int warnings;
        public long bytes;
    }

    public static void Run()
    {
        Request request = null;
        var result = new Result { unityVersion = Application.unityVersion, bundleVersion = PlayerSettings.bundleVersion };
        object addressableSettings = null;
        PropertyInfo buildWithPlayer = null;
        object oldBuildWithPlayer = null;
        bool success = false;
        try
        {
            Debug.Log("[SteamUploader] Stage: Prepare");
            var args = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(args, "-steamUploaderRequest");
            if (index < 0 || index + 1 >= args.Length)
                throw new ArgumentException("Missing -steamUploaderRequest");
            request = JsonUtility.FromJson<Request>(File.ReadAllText(args[index + 1]));
            if (request == null || !Path.IsPathRooted(request.output) || !Path.IsPathRooted(request.report))
                throw new ArgumentException("Output/report must be absolute paths");
            string[] scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
            if (scenes.Length == 0) throw new InvalidOperationException("Build Settings has no enabled scenes");
            foreach (string scene in scenes)
                if (!File.Exists(scene)) throw new FileNotFoundException("Enabled scene does not exist", scene);

            // Reflection keeps projects without Addressables free of package dependencies.
            Type defaults = AppDomain.CurrentDomain.GetAssemblies()
                .Select(a => a.GetType("UnityEditor.AddressableAssets.AddressableAssetSettingsDefaultObject"))
                .FirstOrDefault(t => t != null);
            result.addressables = "not configured";
            if (defaults != null)
            {
                PropertyInfo settingsProperty = defaults.GetProperty("Settings", BindingFlags.Public | BindingFlags.Static);
                addressableSettings = settingsProperty == null ? null : settingsProperty.GetValue(null, null);
            }
            if (addressableSettings != null)
            {
                Type settingsType = addressableSettings.GetType();
                buildWithPlayer = settingsType.GetProperty("BuildAddressablesWithPlayerBuild");
                if (buildWithPlayer == null || !buildWithPlayer.CanWrite)
                    throw new NotSupportedException("Addressables version cannot disable duplicate player builds");
                oldBuildWithPlayer = buildWithPlayer.GetValue(addressableSettings, null);
                object disabled = Enum.Parse(buildWithPlayer.PropertyType, "DoNotBuildWithPlayer");
                buildWithPlayer.SetValue(addressableSettings, disabled, null);
                MethodInfo buildContent = settingsType.GetMethods(BindingFlags.Public | BindingFlags.Static)
                    .FirstOrDefault(m => m.Name == "BuildPlayerContent" && m.GetParameters().Length == 1
                        && m.GetParameters()[0].ParameterType.IsByRef);
                if (buildContent == null) throw new MissingMethodException("Addressables BuildPlayerContent(out result)");
                object[] values = { null };
                Debug.Log("[SteamUploader] Stage: Addressables");
                buildContent.Invoke(null, values);
                if (values[0] == null) throw new InvalidOperationException("Addressables returned no build result");
                PropertyInfo errorProperty = values[0].GetType().GetProperty("Error");
                string error = errorProperty == null ? null : errorProperty.GetValue(values[0], null) as string;
                if (!string.IsNullOrEmpty(error)) throw new InvalidOperationException("Addressables: " + error);
                result.addressables = "built successfully";
            }
            Directory.CreateDirectory(request.output);
            string product = PlayerSettings.productName;
            foreach (char invalid in Path.GetInvalidFileNameChars()) product = product.Replace(invalid, '_');
            product = product.Trim().TrimEnd('.');
            if (string.IsNullOrEmpty(product)) product = "Game";
            result.executable = product + ".exe";
            var options = new BuildPlayerOptions
            {
                scenes = scenes,
                target = BuildTarget.StandaloneWindows64,
                targetGroup = BuildTargetGroup.Standalone,
                locationPathName = Path.Combine(request.output, result.executable),
                options = request.development ? BuildOptions.Development : BuildOptions.None
            };
#if UNITY_2021_2_OR_NEWER
            options.subtarget = (int)StandaloneBuildSubtarget.Player;
#endif
            Debug.Log("[SteamUploader] Stage: Player");
            BuildReport report = BuildPipeline.BuildPlayer(options);
            if (report == null) throw new InvalidOperationException("BuildPipeline returned no BuildReport");
            result.errors = (int)report.summary.totalErrors;
            result.warnings = (int)report.summary.totalWarnings;
            result.bytes = (long)report.summary.totalSize;
            result.message = report.summary.result.ToString();
            success = report.summary.result == BuildResult.Succeeded && result.errors == 0;
            if (!success) throw new InvalidOperationException("Player build result: " + result.message);
        }
        catch (Exception error)
        {
            result.message = error.ToString();
            result.errors = Math.Max(1, result.errors);
            Debug.LogException(error);
        }
        finally
        {
            Debug.Log("[SteamUploader] Stage: Finalize");
            try
            {
                if (addressableSettings != null && buildWithPlayer != null && oldBuildWithPlayer != null)
                {
                    buildWithPlayer.SetValue(addressableSettings, oldBuildWithPlayer, null);
                    EditorUtility.SetDirty((UnityEngine.Object)addressableSettings);
#if UNITY_2021_2_OR_NEWER
                    AssetDatabase.SaveAssetIfDirty((UnityEngine.Object)addressableSettings);
#endif
                }
            }
            catch (Exception error)
            {
                success = false;
                result.errors++;
                result.message += "\nCould not restore Addressables setting: " + error;
                Debug.LogException(error);
            }
            result.succeeded = success;
            if (request != null && !string.IsNullOrEmpty(request.report))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(request.report));
                File.WriteAllText(request.report, JsonUtility.ToJson(result, true), new System.Text.UTF8Encoding(false));
            }
        }
        EditorApplication.Exit(success ? 0 : 1);
    }
}
