
[Console]::BackgroundColor = [System.ConsoleColor]::Black
[Console]::ForegroundColor = [System.ConsoleColor]::White
Clear-Host

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
} catch {
    
}






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









$ForgeVersion = "1.0.0"
$scriptName = "ForgePackage"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$scriptFileName = $MyInvocation.MyCommand.Name
if (-not $scriptFileName) {
    $scriptFileName = "$scriptName.ps1"
}

$scriptPath = Join-Path -Path $scriptDir -ChildPath $scriptFileName
$scriptExt = [System.IO.Path]::GetExtension($scriptPath)
if ([string]::IsNullOrEmpty($scriptExt)) {
    $scriptExt = ".ps1"
}

Write-Host "$scriptName v$ForgeVersion" -ForegroundColor Cyan
Write-Host ""
Write-Host "Расположение: $scriptPath" -ForegroundColor DarkGray

$repoOwner = "Alfa-ao"
$repoName = "ForgePackage"
$apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"

try {
    $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
    $latestTag = $response.tag_name
    $latestVersion = $latestTag.TrimStart('v')
    
    $currentVersionObj = [version]$ForgeVersion
    $latestVersionObj = [version]$latestVersion

    if ($latestVersionObj -gt $currentVersionObj) {
        Write-Host "Доступно обновление: $latestTag. Загрузка..." -ForegroundColor Yellow
        
        $newFileName = "${scriptName}_${latestTag}${scriptExt}"
        $newFilePath = Join-Path -Path $scriptDir -ChildPath $newFileName

        if ($response.assets.Count -gt 0) {
            $downloadUrl = $response.assets[0].browser_download_url
        } else {
            $downloadUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/main/${scriptName}${scriptExt}"
        }
		
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($downloadUrl, $newFilePath)

        Write-Host "Обновление загружено в: $newFilePath" -ForegroundColor Green
		
        try {
            Remove-Item -Path $scriptPath -Force -ErrorAction Stop
        } catch {
            Write-Host "Не удалось удалить старый файл. Переименовываем его." -ForegroundColor Yellow
            Rename-Item -Path $scriptPath -NewName "${scriptName}_old${scriptExt}" -Force
        }

        Write-Host "Перезапуск с новой версией..." -ForegroundColor Green
        
        $processArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$newFilePath`""
        )
        
        Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs
        exit
    } else {
        Write-Host "Версия актуальна." -ForegroundColor Green
    }
} catch {
    Write-Host "Не удалось проверить обновления. ${apiUrl}" -ForegroundColor DarkGray
}

Write-Host ""

$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\gcgame_0.359"
$registryValue = "InstallLocation"

try {
    $installInfo = Get-ItemProperty -Path $registryPath -Name $registryValue -ErrorAction Stop
    if ($installInfo.$registryValue) {
        $installLocation = $installInfo.$registryValue
        Write-Host "Directory Allods Online: $installLocation" -ForegroundColor Yellow
    } else {
        throw "Значение InstallLocation пустое."
    }
} catch {
    Write-Host "Ошибка: Директория игры не найдена в реестре." -ForegroundColor Red
    Write-Host "Проверьте путь: $registryPath" -ForegroundColor DarkGray
    Read-Host "Нажмите Enter для выхода"
    exit
}

Write-Host "test (парсинг vendor.json)." -ForegroundColor Yellow
Read-Host "Нажмите Enter для выхода"