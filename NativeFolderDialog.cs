// Windows Common Item Dialog (Explorer address bar, navigation pane and search).
// Works on the .NET Framework runtime used by Windows PowerShell 5.1.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SteamUploader
{
    public sealed class NativeFolderDialog : IDisposable
    {
        public string Title { get; set; }
        public string SelectedPath { get; set; }

        public DialogResult ShowDialog(IWin32Window owner)
        {
            IFileDialog dialog = null;
            IShellItem folder = null;
            IShellItem result = null;
            try
            {
                dialog = (IFileDialog)new FileOpenDialog();
                uint options;
                dialog.GetOptions(out options);
                // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST | NOCHANGEDIR | DONTADDTORECENT
                dialog.SetOptions(options | 0x20 | 0x40 | 0x800 | 0x8 | 0x02000000);
                dialog.SetTitle(Title ?? "选择文件夹");
                dialog.SetOkButtonLabel("选择文件夹");
                if (!String.IsNullOrWhiteSpace(SelectedPath))
                {
                    string initial = Path.GetFullPath(SelectedPath);
                    while (!String.IsNullOrEmpty(initial) && !Directory.Exists(initial))
                        initial = Path.GetDirectoryName(initial);
                    if (!String.IsNullOrEmpty(initial))
                    {
                        Guid iid = typeof(IShellItem).GUID;
                        Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(initial, IntPtr.Zero, ref iid, out folder));
                        dialog.SetFolder(folder);
                    }
                }
                int hr = dialog.Show(owner == null ? IntPtr.Zero : owner.Handle);
                if (hr == unchecked((int)0x800704C7)) return DialogResult.Cancel;
                Marshal.ThrowExceptionForHR(hr);
                dialog.GetResult(out result);
                IntPtr path;
                result.GetDisplayName(0x80058000, out path); // SIGDN_FILESYSPATH
                try { SelectedPath = Marshal.PtrToStringUni(path); }
                finally { Marshal.FreeCoTaskMem(path); }
                return DialogResult.OK;
            }
            finally
            {
                if (result != null) Marshal.FinalReleaseComObject(result);
                if (folder != null) Marshal.FinalReleaseComObject(folder);
                if (dialog != null) Marshal.FinalReleaseComObject(dialog);
            }
        }

        public void Dispose() { } // COM resources belong to each ShowDialog call.

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);

        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class FileOpenDialog { }

        // Keep the native vtable order, including methods not used by this wrapper.
        [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr filters);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem folder);
            void SetFolder(IShellItem folder);
            void GetFolder(out IShellItem folder);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item);
            void AddPlace(IShellItem item, uint location);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            void Close(int result);
            void SetClientGuid(ref Guid guid);
            void ClearClientData();
            void SetFilter(IntPtr filter);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint nameType, out IntPtr name);
            void GetAttributes(uint mask, out uint attributes);
            void Compare(IShellItem other, uint hint, out int order);
        }
    }
}
