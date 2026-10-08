# =============================================
# ForgePackage.ps1
# =============================================
# Подключение модулей
. "$PSScriptRoot\Functions\UIHelpers.ps1"
. "$PSScriptRoot\Functions\BackupHelpers.ps1"
. "$PSScriptRoot\Classes\ForgeContext.ps1"
. "$PSScriptRoot\Classes\ForgeJsonManager.ps1"
. "$PSScriptRoot\Classes\PackageDownloader.ps1"
. "$PSScriptRoot\Classes\XdbManager.ps1"
. "$PSScriptRoot\Functions\PackageActions.ps1"

[Console]::BackgroundColor = [System.ConsoleColor]::Black
[Console]::ForegroundColor = [System.ConsoleColor]::White
Clear-Host

$packages_version = "v1"
$ForgeVersion     = "1.0.0"
$scriptName       = "ForgePackage"
$scriptDir        = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$scriptFileName = $MyInvocation.MyCommand.Name
if (-not $scriptFileName) { $scriptFileName = "$scriptName.ps1" }
$scriptPath = Join-Path -Path $scriptDir -ChildPath $scriptFileName
$scriptExt = [System.IO.Path]::GetExtension($scriptPath)
if ([string]::IsNullOrEmpty($scriptExt)) { $scriptExt = ".ps1" }

Write-Host "$scriptName v$ForgeVersion" -ForegroundColor Green
Write-Host ""

# --- Самообновление (HELP) ---
$repoOwner = "Alfa-ao"
$repoName  = "ForgePackage"
$apiUrl    = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"

try {
    $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
    $latestTag = $response.tag_name
    $latestVersion = $latestTag.TrimStart('v')
    
    if ([version]$latestVersion -gt [version]$ForgeVersion) {
        Write-Host "Доступно обновление: $latestTag. Загрузка..." -ForegroundColor Yellow
        $newFileName = "${scriptName}_${latestTag}${scriptExt}"
        $newFilePath = Join-Path -Path $scriptDir -ChildPath $newFileName
        
        $downloadUrl = if ($response.assets.Count -gt 0) {
            $response.assets[0].browser_download_url
        } else {
            "https://raw.githubusercontent.com/$repoOwner/$repoName/main/${scriptName}${scriptExt}"
        }
        
        (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $newFilePath)
        Write-Host "Обновление загружено. Перезапуск..." -ForegroundColor Green
        
        try { Remove-Item -Path $scriptPath -Force -ErrorAction Stop }
        catch { Rename-Item -Path $scriptPath -NewName "${scriptName}_old${scriptExt}" -Force }
        
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$newFilePath`""
        exit
    } else {
        Write-Host "Version latest." -ForegroundColor DarkGreen
    }
} catch {
    Write-Host "Не удалось проверить обновления." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Directory: $scriptPath" -ForegroundColor DarkGray

# --- Поиск папки Аллодов Онлайн ---
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



# --- Выбор режима работы (Addon / Library) ---
while ($true)
{
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
    # [FIX] [array] — защита от схлопывания при 1 аддоне
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

if ($addons.Count -eq 0) { Write-Host "Аддоны не найдены." -ForegroundColor Red; Read-Host "Enter"; exit }

Write-Host ""
while ($true) {
    $selection = Read-Host "Введите номер аддона (1-$($addons.Count))"
    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $addons.Count) { break }
    Write-Host "Неверный выбор." -ForegroundColor Red
}

$selectedAddon = $addons[[int]$selection - 1]
Write-Host "Выбран аддон: $($selectedAddon.Name)" -ForegroundColor Green

$context = [ForgeContext]::new($installLocation, $selectedAddon)

# --- Создание forge.json, если его нет ---
if (-not (Test-Path $context.ForgeJsonPath)) {
    $createForge = Read-Host "Файл forge.json не найден. Создать? (Y/N)"
    if ($createForge -match '^[Yy1]$') {
        Write-WarningBlock -Text "Create: Инициализация создания forge.json..."
        $forgeData = [ordered]@{}
        
        # Name
        Write-Host "  [1/8] Определение 'name'..." -ForegroundColor Gray
        $forgeData["name"] = $selectedAddon.Name
        Write-Host "    -> Установлено: $($selectedAddon.Name)" -ForegroundColor Green
        
        # Description
        Write-Host "  [2/8] Определение 'description'..." -ForegroundColor Gray
        $forgeData["description"] = ""
        Write-Host "    -> Установлено: (пусто)" -ForegroundColor Green
        
        # Определение type
        Write-Host "  [3/8] Определение 'type'..." -ForegroundColor Gray
        $forgeData["type"] = "Addon"
        Write-Host "    -> Установлено: Addon" -ForegroundColor Green

        # Определение version
        Write-Host "  [4/8] Определение 'version'..." -ForegroundColor Gray
        $addonVersion = $null
        $xmlPath = $context.XdbPath
        if (Test-Path $xmlPath) {
            try {
                [xml]$xmlContent = Get-Content $xmlPath -Encoding UTF8
                if ($xmlContent.UIAddon.userAddonInfo.version) {
                    $rawVersion = $xmlContent.UIAddon.userAddonInfo.version
                    $numVersion = 0.0
                    if ([double]::TryParse($rawVersion, [ref]$numVersion)) {
                        if ($numVersion -gt 0) { $addonVersion = $rawVersion }
                    } else {
                        if (-not [string]::IsNullOrWhiteSpace($rawVersion) -and $rawVersion -ne "0") {
                            $addonVersion = $rawVersion
                        }
                    }
                    if ($addonVersion) { Write-Host "    -> Версия найдена в UIAddon: $addonVersion" -ForegroundColor DarkGray }
                }
            } catch { Write-Host "    -> Ошибка чтения UIAddon." -ForegroundColor Yellow }
        }
        if ([string]::IsNullOrWhiteSpace($addonVersion)) {
            Write-Host "    -> Версия не найдена, пуста или <= 0 в UIAddon." -ForegroundColor Yellow
            $addonVersion = Read-Host "    Введите версию аддона"
            if ([string]::IsNullOrWhiteSpace($addonVersion)) { $addonVersion = "1.0.0" }
        }
        $forgeData["version"] = $addonVersion
        Write-Host "    -> Установлено: $addonVersion" -ForegroundColor Green

        # Определение license
        Write-Host "  [5/8] Определение 'license'..." -ForegroundColor Gray
        $forgeData["license"] = "MIT"
        Write-Host "    -> Установлено: MIT" -ForegroundColor Green

        # Определение authors
        Write-Host "  [6/8] Определение 'authors'..." -ForegroundColor Gray
        $authorName = $null
        $xmlContent = $null
        if (Test-Path $context.XdbPath) {
            try {
                [xml]$xmlContent = Get-Content $context.XdbPath -Encoding UTF8
                if ($xmlContent.UIAddon.userAddonInfo.author) {
                    $authorName = $xmlContent.UIAddon.userAddonInfo.author
                    Write-Host "    -> Автор найден в UIAddon: $authorName" -ForegroundColor DarkGray
                }
            } catch { Write-Host "    -> Ошибка чтения UIAddon." -ForegroundColor Yellow }
        }
        if ([string]::IsNullOrWhiteSpace($authorName)) {
            Write-Host "    -> Автор не найден в UIAddon." -ForegroundColor Yellow
            $authorName = Read-Host "    Введите имя автора"
            if ([string]::IsNullOrWhiteSpace($authorName)) { $authorName = "Unknown" }
        }
        $forgeData.authors = @(@{ name = $authorName })
        Write-Host "    -> Добавлен автор: $authorName" -ForegroundColor Green

        # Определение require
        Write-Host "  [7/8] Определение 'require'..." -ForegroundColor Gray
        $forgeData["require"] = [ordered]@{}

        # Определение api
        Write-Host "    Определение 'api'..." -ForegroundColor DarkGray
        $apiVersion = $null
        $gameVersionFile = Join-Path $installLocation "Profiles\game.version"
        if (Test-Path $gameVersionFile) {
            try {
                $stream = [System.IO.File]::OpenRead($gameVersionFile)
                $stream.Seek(8, [System.IO.SeekOrigin]::Begin) | Out-Null
                $length = $stream.ReadByte()
                $stream.Close()
                if ($length -gt 0) {
                    $stream = [System.IO.File]::OpenRead($gameVersionFile)
                    $stream.Seek(12, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $buffer = New-Object byte[] $length
                    $bytesRead = $stream.Read($buffer, 0, $length)
                    $stream.Close()
                    if ($bytesRead -eq $length) {
                        $apiVersion = [System.Text.Encoding]::ASCII.GetString($buffer)
                        Write-Host "      -> Версия API найдена: $apiVersion" -ForegroundColor DarkGray
                    }
                }
            } catch { Write-Host "      -> Ошибка чтения game.version." -ForegroundColor Yellow }
        }
        if ([string]::IsNullOrWhiteSpace($apiVersion)) {
            Write-Host "      -> Версия API не найдена." -ForegroundColor Yellow
            $apiVersion = Read-Host "      Введите версию API"
            if ([string]::IsNullOrWhiteSpace($apiVersion)) { $apiVersion = "18.0.0" }
        }
        $forgeData["require"]["api"] = $apiVersion
        Write-Host "      -> Установлена версия API: $apiVersion" -ForegroundColor Green

        # Определение useCommonScripts
        Write-Host "    Определение 'useCommonScripts'..." -ForegroundColor DarkGray
        $useCommonScriptsVal = $false
        if ($xmlContent -and $xmlContent.UIAddon.userAddonInfo.useCommonScripts -eq 'true') {
            $useCommonScriptsVal = $true
            Write-Host "      -> Установлено: true. Пользовательское подключение SampleCommon игнорируется." -ForegroundColor Green
        } else {
            Write-Host "      -> Установлено: false." -ForegroundColor Green
        }
        $forgeData["require"]["useCommonScripts"] = $useCommonScriptsVal

        # Обработка локальных Packages
        Write-Host "    Обработка локальных Packages..." -ForegroundColor DarkGray
        if (Test-Path $context.PackagesJsonPath) {
            try {
                $packagesJsonContent = Get-Content $context.PackagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $currentPkgVersion = $packagesJsonContent.version
                if ($currentPkgVersion -eq $packages_version) {
                    $packagesList = $packagesJsonContent.packages
                    if ($null -ne $packagesList -and $packagesList -isnot [array]) {
                        $packagesList = [array]$packagesList
                    }
                    if ($packagesList) {
                        foreach ($pkg in $packagesList) {
                            if (-not [string]::IsNullOrWhiteSpace($pkg.tag) -and
                                -not [string]::IsNullOrWhiteSpace($pkg.version)) {
                                $forgeData["require"][$pkg.tag] = $pkg.version
                                Write-Host "      -> Add require: " -ForegroundColor Green -NoNewline
                                Write-Host "$($pkg.tag) [$($pkg.version)]" -ForegroundColor Yellow
                            } else {
                                Write-Host "      [!] " -ForegroundColor Red -NoNewline
                                Write-Host "Warning: У пакета отсутствуют tag или version." -ForegroundColor Yellow
                            }
                        }
                    }
                } else {
                    Write-Host "      [!] " -ForegroundColor Red -NoNewline
                    Write-Host "Warning: Текущая версия packages несовместима." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "      [!] " -ForegroundColor Red -NoNewline
                Write-Host "Warning: Ошибка чтения packages.json." -ForegroundColor Yellow
            }
        } else {
            Write-Host "      -> Файл packages.json не найден." -ForegroundColor DarkGray
        }
        
        # ---BEGIN[8/8]---
        Write-Host "  [8/8] Определение 'files'..." -ForegroundColor Gray
        $scriptRefs = @()
        if ($xmlContent -and $xmlContent.UIAddon.ScriptFileRefs) {
            $items = $xmlContent.UIAddon.ScriptFileRefs.Item
            if ($items) {
                if ($items -isnot [array]) { $items = @($items) }
                $scriptRefs = $items | ForEach-Object { $_.href }
            }
        }

        # сохранение исходной последовательности
        $filesDict = [ordered]@{}
        foreach ($ref in $scriptRefs) {
            $normRef = $ref.Replace("\", "/")
            if ($normRef -match "^Packages/") { continue }
            
            $priority = 10
            if ([ForgeContext]::CommonScriptsPriority.ContainsKey($normRef)) {
                $priority = [ForgeContext]::CommonScriptsPriority[$normRef]
            }
            $filesDict[$normRef] = $priority
        }

        $forgeData["files"] = $filesDict

        foreach ($item in $filesDict.Keys) {
            Write-Host "    -> Add file: " -ForegroundColor Green -NoNewline
            Write-Host "$item [Priority: $($filesDict[$item])]" -ForegroundColor Yellow
        }
        # ---END[8/8]---
        
        # Сохранение
        Write-Host "Сохранение JSON..." -ForegroundColor Gray
        $mgr = [ForgeJsonManager]::new($context.ForgeJsonPath)
        $mgr.Data = [PSCustomObject]$forgeData
        $mgr.Save()
        Write-Host "Файл forge.json успешно создан." -ForegroundColor Yellow
    }
    else {
        Stop-Process -Id $PID -Force
    }
}


while($true)
{
    # --- Работа с Packages ---
    $packagesDir     = $context.PackagesDir
    $packagesJsonPath = $context.PackagesJsonPath
    $actionToPerform = $null
    $actionArg       = $null

    Write-Host ""
    Write-Host "Packages..." -ForegroundColor DarkGray

    if (Test-Path $packagesJsonPath) {
        try {
            $pkgJsonContent = Get-Content $packagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pkgJsonContent.version -ne $packages_version) {
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
            }
            else { Remove-Item -Path $packagesDir -Recurse -Force }
        }
        else {
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
            }
            elseif ($inputCmd -match "^(require)\s+(.+)$") {
                $actionToPerform = $matches[1]
                $actionArg = $matches[2].Trim()
                break
            }
            else { Write-Host "  Неверная команда." -ForegroundColor Red }
        }
    }

    # --- Выполнение действий ---
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
                    Write-Log "Error" "Неверный формат. Ожидается: Владелец/Репозиторий" "Red" "Red"
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