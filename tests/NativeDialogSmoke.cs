// Optional visual smoke test. Operates only dialogs on this test's UI thread.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class NativeDialogSmoke
{
    private delegate bool EnumWindow(IntPtr hwnd, IntPtr state);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindow callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindow callback, IntPtr state);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }

    public static string Run(string output)
    {
        Directory.CreateDirectory(output);
        string folder = Path.Combine(output, "导出测试 & spaces");
        Directory.CreateDirectory(folder);
        string[] children = { "历史构建", "Windows 包体", "备用目录" };
        foreach (string child in children) Directory.CreateDirectory(Path.Combine(folder, child));
        var classes = new HashSet<string>();
        for (int pass = 0; pass < 2; pass++)
        {
            bool accept = pass == 0;
            bool handled = false;
            string title = accept ? "导出文件夹（每次在其下新建独立包体目录）" : "Unity 项目根目录 - 取消测试";
            Exception timerError = null;
            uint thread = GetCurrentThreadId();
            using (var timer = new Timer { Interval = 1400 })
            using (var owner = new Form { ShowInTaskbar = false, Opacity = 0, TopMost = true })
            using (var dialog = new SteamUploader.NativeFolderDialog { Title = title, SelectedPath = folder })
            {
                owner.Show();
                timer.Tick += delegate {
                    IntPtr window = IntPtr.Zero;
                    EnumThreadWindows(thread, delegate(IntPtr hwnd, IntPtr unused) {
                        var caption = new StringBuilder(1024);
                        GetWindowText(hwnd, caption, caption.Capacity);
                        if (caption.ToString() == title) window = hwnd;
                        return true;
                    }, IntPtr.Zero);
                    if (window == IntPtr.Zero) return;
                    timer.Stop();
                    handled = true;
                    try
                    {
                        if (accept)
                        {
                            EnumChildWindows(window, delegate(IntPtr hwnd, IntPtr unused) {
                                var name = new StringBuilder(256);
                                GetClassName(hwnd, name, name.Capacity);
                                classes.Add(name.ToString());
                                return true;
                            }, IntPtr.Zero);
                            Rect rect;
                            GetWindowRect(window, out rect);
                            using (var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top))
                            using (var graphics = Graphics.FromImage(bitmap))
                            {
                                IntPtr hdc = graphics.GetHdc();
                                try
                                {
                                    if (!PrintWindow(window, hdc, 2)) throw new Exception("Could not capture the owned dialog");
                                }
                                finally { graphics.ReleaseHdc(hdc); }
                                bitmap.Save(Path.Combine(output, "folder-dialog.png"));
                            }
                        }
                    }
                    catch (Exception ex) { timerError = ex; }
                    finally
                    {
                        // IDOK selects the current folder; WM_CLOSE cancels only our dialog.
                        PostMessage(window, accept ? 0x0111u : 0x0010u, accept ? new IntPtr(1) : IntPtr.Zero, IntPtr.Zero);
                    }
                };
                timer.Start();
                DialogResult result = dialog.ShowDialog(owner);
                timer.Stop();
                if (timerError != null) throw timerError;
                if (!handled || result != (accept ? DialogResult.OK : DialogResult.Cancel)) throw new Exception("Dialog acceptance/cancel failed");
                if (dialog.SelectedPath != folder) throw new Exception("Dialog returned the wrong folder");
            }
        }
        File.WriteAllLines(Path.Combine(output, "window-classes.txt"), classes);
        if (!classes.Contains("DirectUIHWND") || !classes.Contains("Breadcrumb Parent"))
            throw new Exception("Expected Explorer folder view and address bar controls");
        return "PASS modern folder selection, initial directory, cancellation, address bar and screenshot";
    }
}
