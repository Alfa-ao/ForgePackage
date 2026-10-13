# =============================================
# ForgePackage.ps1
# =============================================
# Подключение модулей
. "$PSScriptRoot\Classes\ForgeConfig.ps1"
. "$PSScriptRoot\Functions\UIHelpers.ps1"
. "$PSScriptRoot\Functions\BackupHelpers.ps1"
. "$PSScriptRoot\Functions\Update.ps1"
. "$PSScriptRoot\Functions\CreateForge.ps1"
. "$PSScriptRoot\Classes\GithubApi.ps1"
. "$PSScriptRoot\Classes\ForgeContext.ps1"
. "$PSScriptRoot\Classes\ForgeJsonManager.ps1"
. "$PSScriptRoot\Classes\PackageDownloader.ps1"
. "$PSScriptRoot\Classes\XdbManager.ps1"
. "$PSScriptRoot\Functions\PackageActions.ps1"

[Console]::BackgroundColor = [System.ConsoleColor]::Black
[Console]::ForegroundColor = [System.ConsoleColor]::White
Clear-Host

# Инициализация глобальной конфигурации
$config = [ForgeConfig]::new($PSScriptRoot, $MyInvocation.MyCommand.Name)
Write-Host "$($config.ScriptName) v$($config.AppVersion)" -ForegroundColor Green
Write-Host ""

# Проверка обновлений
$ghApi = [GithubApi]::new()
Invoke-ScriptUpdate -Config $config -Api $ghApi

Write-Host ""
Write-Host "Directory: $($config.ScriptPath)" -ForegroundColor DarkGray

# Поиск папки игры
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\gcgame_0.359"
try {
    $installInfo = Get-ItemProperty -Path $registryPath -Name "InstallLocation" -ErrorAction Stop
    $installLocation = $installInfo.InstallLocation
    Write-Host "Directory Allods Online: $installLocation" -ForegroundColor DarkGray
} catch {
    Write-Host "Ошибка: Директория игры не найдена." -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода";
    Stop-Process -Id $PID -Force
}

# Выбор режима работы
while ($true) {
    Write-Host ""
    Write-Host "Выберите режим работы:" -ForegroundColor Yellow
    Write-Host "  1. Addon    - Сканирование папки с аддонами" -ForegroundColor Gray
    Write-Host "  2. Library  - Создание forge для библиотеки" -ForegroundColor Gray
    $workMode = Read-Host "Введите номер (1 или 2)"
    
    if ($workMode -in @('1', '2')) {
        break
    }
    Write-Host "Неверный выбор." -ForegroundColor Red
}

if ($workMode -eq '2') {
    Write-Host "Выберите папку..." -ForegroundColor Yellow
    $selectedPath = Get-SelectedFolder
    
    if (-not [string]::IsNullOrEmpty($selectedPath)) {
        $selectedAddon = [System.IO.DirectoryInfo]::new($selectedPath)
        Write-Host "Выбрана папка: $($selectedAddon.FullName)" -ForegroundColor Green
        Write-Host ""
        
        $forgeJsonPath = Join-Path $selectedPath "forge.json"
        if (Test-Path $forgeJsonPath) {
            Write-Log "Info" "Файл forge.json уже существует в выбранной папке." "DarkYellow" "Yellow"
            Read-Host "Нажмите Enter для выхода"
            Stop-Process -Id $PID -Force
        }
        
        Write-Host "Сканирование *.lua файлов..." -ForegroundColor DarkYellow
        $luaFiles = @()
        $foundFiles = Get-ChildItem -Path $selectedPath -Filter "*.lua" -Recurse -File -ErrorAction SilentlyContinue
        
        if ($foundFiles) {
            $luaFiles = $foundFiles | ForEach-Object {
                $relativePath = $_.FullName.Substring($selectedPath.Length).TrimStart('\', '/')
                $relativePath -replace '\\', '/'
            }
        }
        
        $luaFiles = [array]$luaFiles
        $filesDict = [ordered]@{}
        foreach ($file in $luaFiles) {
            $filesDict[$file] = 20
        }
        
        $forgeData = [ordered]@{
            name    = $selectedAddon.Name
            type    = "Library"
            execute = [ordered]@{
                unpack = $luaFiles
            }
            files   = $filesDict
        }
        
        Write-Host "Сохранение forge.json..." -ForegroundColor Gray
        $mgr = [ForgeJsonManager]::new($forgeJsonPath)
        $mgr.Data = [PSCustomObject]$forgeData
        $mgr.Save()
        Write-Host "Файл forge.json успешно создан для библиотеки '$($selectedAddon.Name)'." -ForegroundColor Green
    } else {
        Write-Host "Выбор папки отменен." -ForegroundColor Red
    }
    
    Read-Host "Нажмите Enter для выхода"
    Stop-Process -Id $PID -Force
}

$addonsPath = Join-Path $installLocation "data\Mods\Addons"
Write-Host "Сканирование..." -ForegroundColor DarkYellow
Write-WarningBlock -Text "Warning: Сканированию подлежат только распакованные аддоны."

$addons = @()
if (Test-Path $addonsPath) {
    $addons = [array](Get-ChildItem -Path $addonsPath -Directory | Where-Object { $_.Name -notmatch '^!' } | Sort-Object Name)
    $header = "{0,-4} | {1,-25} | {2}" -f "#", "AddonName", "forge"
    Write-Host ""; Write-Host $header; Write-Host ("-" * $header.Length)
    
    $index = 1
    foreach ($addon in $addons) {
        $hasForge = Test-Path (Join-Path $addon.FullName "forge.json")
        $line = "{0,-4} | {1,-25} | " -f $index, $addon.Name
        Write-Host $line -NoNewline
        Write-Host $(if ($hasForge) { "Found" } else { "Not found" }) -ForegroundColor $(if ($hasForge) { "Green" } else { "Red" })
        $index++
    }
}

if ($addons.Count -eq 0) { 
    Write-Host "Аддоны не найдены." -ForegroundColor Red; 
    Read-Host "Enter"; 
    exit 
}

Write-Host ""
while ($true) {
    $selection = Read-Host "Введите номер аддона (1-$($addons.Count))"
    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $addons.Count) { break }
    Write-Host "Неверный выбор." -ForegroundColor Red
}

$selectedAddon = $addons[[int]$selection - 1]
Write-Host "Выбран аддон: $($selectedAddon.Name)" -ForegroundColor Green

$context = [ForgeContext]::new($installLocation, $selectedAddon)

# Создание forge.json при отсутствии
if (-not (Test-Path $context.ForgeJsonPath)) {
    New-ForgeJson -Context $context -Config $config -GameInstallPath $installLocation
}

# Цикл управления пакетами
while($true) {
    $packagesDir      = $context.PackagesDir
    $packagesJsonPath = $context.PackagesJsonPath
    $actionToPerform  = $null
    $actionArg        = $null
    
    Write-Host ""
    Write-Host "Packages..." -ForegroundColor DarkGray
    
    if (Test-Path $packagesJsonPath) {
        try {
            $pkgJsonContent = Get-Content $packagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            
            if ($pkgJsonContent.version -ne $config.PackagesVersion) {
                Write-Host "  [!] Версия packages.json несовместима." -ForegroundColor Red
                Backup-AndCleanPackages -PackagesPath $context.PackagesDir
                $actionToPerform = "install"
            } else {
                Write-Host "  -> Found." -ForegroundColor DarkGray
                while ($true) {
                    Write-Host ""
                    Write-Host "Выберите действие:" -ForegroundColor Yellow
                    Write-Host "  require <name> - Подключить библиотеку" -ForegroundColor Gray
                    Write-Host "  remove <name>  - Удаление библиотеки" -ForegroundColor Gray
                    Write-Host "  update <name>  - Обновление (all|name)" -ForegroundColor Gray
                    Write-Host "  exit           - Выход" -ForegroundColor Gray
                    $inputCmd = Read-Host "  Введите команду"
                    
                    if ($inputCmd -match "^exit$") { break }
                    elseif ($inputCmd -match "^(require|remove|update)\s+(.+)$") {
                        $actionToPerform = $matches[1]
                        $actionArg = $matches[2].Trim()
                        break
                    } else { Write-Host "  Неверная команда." -ForegroundColor Red }
                }
            }
        } catch {
            Write-Host "  [!] Ошибка чтения packages.json." -ForegroundColor Red
            Backup-AndCleanPackages -PackagesPath $context.PackagesDir
            $actionToPerform = "install"
        }
    } else {
        if (Test-Path $packagesDir) {
            $hasFiles = Get-ChildItem -Path $packagesDir -Recurse -File -ErrorAction SilentlyContinue
            if ($hasFiles) {
                Backup-AndCleanPackages -PackagesPath $context.PackagesDir
            } else { 
                Remove-Item -Path $packagesDir -Recurse -Force 
            }
        } else {
            Write-Host "  -> Not Found." -ForegroundColor DarkGray
        }
        
        while ($true) {
            Write-Host ""
            Write-Host "Выберите действие:" -ForegroundColor Yellow
            Write-Host "  install        - Установить зависимости" -ForegroundColor Gray
            Write-Host "  require <name> - Подключить библиотеку" -ForegroundColor Gray
            Write-Host "  exit           - Выход" -ForegroundColor Gray
            $inputCmd = Read-Host "  Введите команду"
            
            if ($inputCmd -match "^exit$") { break }
            elseif ($inputCmd -match "^install$") {
                $actionToPerform = "install"
                break
            } elseif ($inputCmd -match "^(require)\s+(.+)$") {
                $actionToPerform = $matches[1]
                $actionArg = $matches[2].Trim()
                break
            } else { Write-Host "  Неверная команда." -ForegroundColor Red }
        }
    }
    
    # Выполнение команд
    if ($actionToPerform) {
        Write-Host ""
        Write-Host "Подготовка..." -ForegroundColor Gray
        Backup-XdbFile -AddonRoot $selectedAddon.FullName
        
        switch ($actionToPerform) {
            "install" {
                Install-PackageDependencies -Ctx $context
            }
            "remove" {
                if ($actionArg -match "^[^/]+/[^/]+$") {
                    Remove-Package -TargetTag $actionArg -Ctx $context
                } else {
                    Write-Host "Неверный формат. Ожидается: Владелец/Репозиторий" -ForegroundColor Red
                }
            }
            "require" {
                if ($actionArg -match "^[^/]+/[^/]+$") {
                    Require-Package -TargetTag $actionArg -Ctx $context
                } else {
                    Write-Host "Неверный формат. Ожидается: Владелец/Репозиторий" -ForegroundColor Red
                }
            }
            "update" {
                if ($actionArg -eq "all") {
                    Update-AllPackages -Ctx $context
                } elseif ($actionArg -match "^[^/]+/[^/]+$") {
                    Update-SinglePackage -TargetTag $actionArg -Ctx $context
                } else {
                    Write-Host "Неверный формат. Ожидается: all или Владелец/Репозиторий" -ForegroundColor Red
                }
            }
        }
    } else {
        Stop-Process -Id $PID -Force
    }
}