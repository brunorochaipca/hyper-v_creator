using System.Runtime.InteropServices;
using System.Text;

namespace CriarVmWindows;

/// <summary>
/// Diálogos de ficheiros do Windows. Os seletores do WinUI (FileOpenPicker) falham em aplicações
/// que correm como administrador, por isso usa-se a API clássica, que funciona sempre.
/// </summary>
internal static class NativeDialogs
{
    private const int OfnOverwritePrompt = 0x2;
    private const int OfnNoChangeDir = 0x8;
    private const int OfnPathMustExist = 0x800;
    private const int OfnFileMustExist = 0x1000;
    private const int OfnExplorer = 0x80000;

    private const int BufferChars = 2048;

    public static string? OpenFile(IntPtr owner, string title, string filter)
        => ShowFileDialog(owner, title, filter, null, save: false);

    public static string? SaveFile(IntPtr owner, string title, string filter, string defaultName)
        => ShowFileDialog(owner, title, filter, defaultName, save: true);

    public static string? PickFolder(IntPtr owner, string title)
    {
        var display = Marshal.AllocHGlobal(260 * 2);
        try
        {
            var info = new BrowseInfo
            {
                hwndOwner = owner,
                pszDisplayName = display,
                lpszTitle = title,
                ulFlags = 0x1 | 0x40 // só pastas do sistema de ficheiros | diálogo novo (com "Criar pasta")
            };
            var pidl = SHBrowseForFolder(ref info);
            if (pidl == IntPtr.Zero)
                return null;
            try
            {
                var path = new StringBuilder(520);
                return SHGetPathFromIDList(pidl, path) ? path.ToString() : null;
            }
            finally
            {
                CoTaskMemFree(pidl);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(display);
        }
    }

    private static string? ShowFileDialog(IntPtr owner, string title, string filter, string? defaultName, bool save)
    {
        var buffer = Marshal.AllocHGlobal(BufferChars * 2);
        try
        {
            var initial = defaultName ?? "";
            var chars = new char[BufferChars];
            initial.CopyTo(0, chars, 0, Math.Min(initial.Length, BufferChars - 1));
            Marshal.Copy(chars, 0, buffer, BufferChars);

            var dialog = new OpenFileName
            {
                lStructSize = Marshal.SizeOf<OpenFileName>(),
                hwndOwner = owner,
                lpstrFilter = filter,
                nFilterIndex = 1,
                lpstrFile = buffer,
                nMaxFile = BufferChars,
                lpstrTitle = title,
                Flags = OfnExplorer | OfnNoChangeDir | OfnPathMustExist | (save ? OfnOverwritePrompt : OfnFileMustExist)
            };

            var ok = save ? GetSaveFileName(ref dialog) : GetOpenFileName(ref dialog);
            return ok ? Marshal.PtrToStringUni(buffer) : null;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OpenFileName
    {
        public int lStructSize;
        public IntPtr hwndOwner;
        public IntPtr hInstance;
        public string? lpstrFilter;
        public string? lpstrCustomFilter;
        public int nMaxCustFilter;
        public int nFilterIndex;
        public IntPtr lpstrFile;
        public int nMaxFile;
        public string? lpstrFileTitle;
        public int nMaxFileTitle;
        public string? lpstrInitialDir;
        public string? lpstrTitle;
        public int Flags;
        public short nFileOffset;
        public short nFileExtension;
        public string? lpstrDefExt;
        public IntPtr lCustData;
        public IntPtr lpfnHook;
        public string? lpTemplateName;
        public IntPtr pvReserved;
        public int dwReserved;
        public int FlagsEx;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct BrowseInfo
    {
        public IntPtr hwndOwner;
        public IntPtr pidlRoot;
        public IntPtr pszDisplayName;
        public string? lpszTitle;
        public uint ulFlags;
        public IntPtr lpfn;
        public IntPtr lParam;
        public int iImage;
    }

    [DllImport("comdlg32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetOpenFileNameW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetOpenFileName(ref OpenFileName dialog);

    [DllImport("comdlg32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetSaveFileNameW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSaveFileName(ref OpenFileName dialog);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHBrowseForFolderW")]
    private static extern IntPtr SHBrowseForFolder(ref BrowseInfo info);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHGetPathFromIDListW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SHGetPathFromIDList(IntPtr pidl, StringBuilder path);

    [DllImport("ole32.dll")]
    private static extern void CoTaskMemFree(IntPtr pointer);
}
