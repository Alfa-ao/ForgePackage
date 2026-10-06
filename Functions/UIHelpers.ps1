# =============================================
# Functions/UIHelpers.ps1
# =============================================

$Win32Code = @"
using System;
using System.Runtime.InteropServices;
public class ConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_LAYERED = 0x80000;
    public const byte LWA_ALPHA = 0x2;
    public static void SetOpacity(int percent) {
        IntPtr handle = GetConsoleWindow();
        if (handle == IntPtr.Zero) return;
        int exStyle = GetWindowLong(handle, GWL_EXSTYLE);
        if ((exStyle & WS_EX_LAYERED) == 0) {
            SetWindowLong(handle, GWL_EXSTYLE, exStyle | WS_EX_LAYERED);
        }
        byte alpha = (byte)(255 * percent / 100);
        SetLayeredWindowAttributes(handle, 0, alpha, LWA_ALPHA);
    }
}
"@

try {
    Add-Type -TypeDefinition $Win32Code -Language CSharp -ErrorAction Stop
    [ConsoleWindow]::SetOpacity(90)
} catch {}




$fontCode = @"
using System;
using System.Runtime.InteropServices;
public class ConsoleFont {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public int cbSize;
        public int nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD {
        public short X;
        public short Y;
    }
    public const int STD_OUTPUT_HANDLE = -11;
    public const int TMPF_TRUETYPE = 4;
    public static void SetFont(string fontName, short fontSize) {
        IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_FONT_INFOEX fontInfo = new CONSOLE_FONT_INFOEX();
        fontInfo.cbSize = Marshal.SizeOf(fontInfo);
        fontInfo.nFont = 0;
        fontInfo.dwFontSize.X = 0;
        fontInfo.dwFontSize.Y = fontSize;
        fontInfo.FontFamily = TMPF_TRUETYPE;
        fontInfo.FontWeight = 400;
        fontInfo.FaceName = fontName;
        SetCurrentConsoleFontEx(handle, false, ref fontInfo);
    }
}
"@

try {
    Add-Type -TypeDefinition $fontCode -Language CSharp -ErrorAction Stop
    [ConsoleFont]::SetFont("Consolas", 14)
} catch {
    Write-Host "Не удалось установить шрифт: $($_.Exception.Message)" -ForegroundColor Yellow
}



$csharpCode = @"
using System;
using System.Runtime.InteropServices;

public class ModernFolderDialog {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogClass { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog {
        void Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IntPtr psi);
        void SetFolder(IntPtr psi);
        void GetFolder(out IntPtr ppsi);
        void GetCurrentSelection(out IntPtr ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi); // [FIX] Было out IntPtr, стало out IShellItem
        void AddPlace(IntPtr psi, uint fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IntPtr ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IntPtr psi, uint hint, out int piOrder);
    }

    public static string ShowDialog(string title) {
        var dialog = (IFileDialog)new FileOpenDialogClass();
        dialog.SetOptions(0x00000020); // FOS_PICKFOLDERS (режим выбора папок)
        dialog.SetTitle(title);
        
        try {
            dialog.Show(IntPtr.Zero);
            IShellItem result;
            dialog.GetResult(out result);
            string path;
            result.GetDisplayName(0x80028000, out path); // SIGDN_FILESYSPATH
            return path;
        } catch {
            return null;
        }
    }
}
"@

function Get-SelectedFolder {
    $selectedPath = $null
    
    if (-not ("ModernFolderDialog" -as [type])) {
        try {
            Add-Type -TypeDefinition $csharpCode -Language CSharp -ErrorAction Stop
        } catch {
            Write-Host "Ошибка компиляции: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }

    if ("ModernFolderDialog" -as [type]) {
        $selectedPath = [ModernFolderDialog]::ShowDialog("Выберите папку для библиотеки")
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Выберите папку для библиотеки"
        $folderBrowser.ShowNewFolderButton = $false
        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selectedPath = $folderBrowser.SelectedPath
        }
    }
    
    return $selectedPath
}



function Write-WarningBlock {
    param([string]$Text)
    Write-Host ""
    Write-Host ("-" * 64) -ForegroundColor DarkYellow
    Write-Host " [!] " -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Yellow
    Write-Host ("-" * 64) -ForegroundColor DarkYellow
    Write-Host ""
}


function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Message,

        [ConsoleColor]$ActionColor = "Cyan",

        [ConsoleColor]$MessageColor = "White"
    )

    Write-Host "[$Action] " -ForegroundColor $ActionColor -NoNewline
    Write-Host $Message -ForegroundColor $MessageColor
}