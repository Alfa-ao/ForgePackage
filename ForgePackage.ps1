# =============================================
# ForgePackage.ps1
# =============================================
# Подключение модулей
. "$PSScriptRoot\Functions\UIHelpers.ps1"
. "$PSScriptRoot\Functions\BackupHelpers.ps1"
. "$PSScriptRoot\Classes\ForgeContext.ps1"
. "$PSScriptRoot\Classes\XdbManager.ps1"
. "$PSScriptRoot\Classes\ForgeJsonManager.ps1"
. "$PSScriptRoot\Classes\PackageDownloader.ps1"

[Console]::BackgroundColor = [System.ConsoleColor]::Black
[Console]::ForegroundColor = [System.ConsoleColor]::White
Clear-Host

$packages_version = "v1"
$ForgeVersion = "1.0.0"
$scriptName = "ForgePackage"
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$scriptFileName = $MyInvocation.MyCommand.Name
if (-not $scriptFileName) { $scriptFileName = "$scriptName.ps1" }
$scriptPath = Join-Path -Path $scriptDir -ChildPath $scriptFileName
$scriptExt = [System.IO.Path]::GetExtension($scriptPath)
if ([string]::IsNullOrEmpty($scriptExt)) { $scriptExt = ".ps1" }

Write-Host "$scriptName v$ForgeVersion" -ForegroundColor Green
Write-Host ""

# --- Самообновление ---
$repoOwner = "Alfa-ao"
$repoName = "ForgePackage"
$apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
try {
    $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
    $latestTag = $response.tag_name
    $latestVersion = $latestTag.TrimStart('v')
    if ([version]$latestVersion -gt [version]$ForgeVersion) {
        Write-Host "Доступно обновление: $latestTag. Загрузка..." -ForegroundColor Yellow
        $newFileName = "${scriptName}_${latestTag}${scriptExt}"
        $newFilePath = Join-Path -Path $scriptDir -ChildPath $newFileName
        $downloadUrl = if ($response.assets.Count -gt 0) { $response.assets[0].browser_download_url } else { "https://raw.githubusercontent.com/$repoOwner/$repoName/main/${scriptName}${scriptExt}" }
        (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $newFilePath)
        Write-Host "Обновление загружено. Перезапуск..." -ForegroundColor Green
        try { Remove-Item -Path $scriptPath -Force -ErrorAction Stop } catch { Rename-Item -Path $scriptPath -NewName "${scriptName}_old${scriptExt}" -Force }
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

# --- Поиск игры ---
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\gcgame_0.359"
try {
    $installInfo = Get-ItemProperty -Path $registryPath -Name "InstallLocation" -ErrorAction Stop
    $installLocation = $installInfo.InstallLocation
    Write-Host "Directory Allods Online: $installLocation" -ForegroundColor DarkYellow
} catch {
    Write-Host "Ошибка: Директория игры не найдена." -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода"; exit
}

$addonsPath = Join-Path $installLocation "data\Mods\Addons"
Write-Host "Сканирование..." -ForegroundColor DarkYellow
Write-WarningBlock -Text "Warning: Сканированию подлежат только распакованные аддоны."

$addons = @()
if (Test-Path $addonsPath) {
    $addons = Get-ChildItem -Path $addonsPath -Directory | Where-Object { $_.Name -notmatch '^!' } | Sort-Object Name
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

# Создаем контекст
$context = [ForgeContext]::new($installLocation, $selectedAddon)

# --- Создание forge.json, если его нет (ВОССТАНОВЛЕНА ПОЛНАЯ ЛОГИКА) ---
if (-not (Test-Path $context.ForgeJsonPath)) {
    $createForge = Read-Host "Файл forge.json не найден. Создать? (Y/N)"
    if ($createForge -match '^[Yy1]$') {
        Write-WarningBlock -Text "Create: Инициализация создания forge.json..."
        $forgeData = [ordered]@{}
        
        # 1. Name
        Write-Host "  [1/7] Определение 'name'..." -ForegroundColor Gray
        $forgeData["name"] = $selectedAddon.Name
        Write-Host "    -> Установлено: $($selectedAddon.Name)" -ForegroundColor Green

        # 2. Description
        Write-Host "  [2/7] Определение 'description'..." -ForegroundColor Gray
        $forgeData["description"] = ""
        Write-Host "    -> Установлено: (пусто)" -ForegroundColor Green

        # 3. Type
        Write-Host "  [3/7] Определение 'type'..." -ForegroundColor Gray
        Write-Host "    Выберите тип пакета:" -ForegroundColor Gray
        Write-Host "      1. Addon" -ForegroundColor Gray
        Write-Host "      2. Library" -ForegroundColor Gray
        $typeVal = if ((Read-Host "    Введите номер (1 или 2)") -eq '2') { "Library" } else { "Addon" }
        $forgeData["type"] = $typeVal
        Write-Host "    -> Установлено: $typeVal" -ForegroundColor Green

        # 3.5 Version (только для Addon)
        if ($typeVal -eq "Addon") {
            Write-Host "  [3.5] Определение 'version'..." -ForegroundColor Gray
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
                            if (-not [string]::IsNullOrWhiteSpace($rawVersion) -and $rawVersion -ne "0") { $addonVersion = $rawVersion }
                        }
                        if ($addonVersion) { Write-Host "    -> Версия найдена в UIAddon: $addonVersion" -ForegroundColor DarkGray }
                    }
                } catch { Write-Host "    -> Ошибка чтения UIAddon." -ForegroundColor Yellow }
            }
            if ([string]::IsNullOrWhiteSpace($addonVersion)) {
                Write-Host "    -> Версия не найдена, пуста или <= 0 в UIAddon." -ForegroundColor Yellow
                $addonVersion = Read-Host "    Введите версию аддона (например: 1.0.0)"
                if ([string]::IsNullOrWhiteSpace($addonVersion)) { $addonVersion = "1.0.0" }
            }
            $forgeData["version"] = $addonVersion
            Write-Host "    -> Установлено: $addonVersion" -ForegroundColor Green
        }

        # 4. License
        Write-Host "  [4/7] Определение 'license'..." -ForegroundColor Gray
        $forgeData["license"] = "MIT"
        Write-Host "    -> Установлено: MIT" -ForegroundColor Green

        # 5. Authors
        Write-Host "  [5/7] Определение 'authors'..." -ForegroundColor Gray
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
        $authorsList = [System.Collections.ArrayList]::new()
        [void]$authorsList.Add([PSCustomObject]@{ name = $authorName })
        $forgeData["authors"] = $authorsList
        Write-Host "    -> Добавлен автор: $authorName" -ForegroundColor Green

        # 6. Require
        Write-Host "  [6/7] Определение 'require'..." -ForegroundColor Gray
        $forgeData["require"] = [ordered]@{}

        # 6.1 API Version
        Write-Host "    [6.1] Определение 'api'..." -ForegroundColor DarkGray
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

        # 6.2 useCommonScripts
        Write-Host "    [6.2] Определение 'useCommonScripts'..." -ForegroundColor DarkGray
        $useCommonScriptsVal = $null
        $xmlUseCommon = $false
        if ($xmlContent -and $xmlContent.UIAddon.userAddonInfo.useCommonScripts -eq 'true') { $xmlUseCommon = $true }
        
        $scriptRefs = @()
        if ($xmlContent -and $xmlContent.UIAddon.ScriptFileRefs.Item) {
            $xmlItems = $xmlContent.UIAddon.ScriptFileRefs.Item
            if ($xmlItems -is [System.Array]) { $scriptRefs = $xmlItems | ForEach-Object { $_.href } } 
            else { $scriptRefs = @($xmlItems.href) }
        }

        $orderedCommonScripts = @(
            "/Mods/SampleCommon/CoreScripts/ClassesImplementation.lua",
            "/Mods/SampleCommon/SampleAddonBase.lua",
            "/Mods/SampleCommon/CoreScripts/AddonBaseUserMods.lua",
            "/Mods/SampleCommon/CoreScripts/AddonBase.lua",
            "/Mods/SampleCommon/CoreScripts/WidgetCoreUserMods.lua",
            "/Mods/SampleCommon/CoreScripts/AdvancedHandlersUserMods.lua"
        )
        $foundScripts = @()
        $foundDeprecated = $false
        foreach ($ref in $scriptRefs) {
            $normRef = $ref.Replace("\", "/")
            if ($normRef -match "^/Mods/SampleCommon") {
                if ($normRef -eq "/Mods/SampleCommon/SampleAddonBase.lua") { $foundDeprecated = $true }
                if ($orderedCommonScripts -contains $normRef) { $foundScripts += $normRef }
            }
        }
        $orderedFoundScripts = @()
        foreach ($ordered in $orderedCommonScripts) {
            if ($foundScripts -contains $ordered) { $orderedFoundScripts += $ordered }
        }

        if ($xmlUseCommon) {
            $useCommonScriptsVal = $true
            Write-Host "      -> Найдено в UIAddon (useCommonScripts = true)" -ForegroundColor Green
        } elseif ($orderedFoundScripts.Count -gt 0) {
            $useCommonScriptsVal = $orderedFoundScripts
            foreach ( $item in $orderedFoundScripts ) {
                Write-Host "      -> Add: " -ForegroundColor Green -NoNewline
                Write-Host "- ${item}" -ForegroundColor Yellow
            }
            if ($foundDeprecated) {
                Write-Host "      [!] "  -ForegroundColor Red -NoNewline
                Write-Host "Warning: Обнаружена устаревшая логика (SampleAddonBase.lua)." -ForegroundColor Yellow
                Write-Host "           Рекомендуется использовать:" -ForegroundColor Gray
                Write-Host "             - CoreScripts/AddonBaseUserMods" -ForegroundColor Yellow
                Write-Host "             - CoreScripts/AddonBase" -ForegroundColor Yellow
            }
        } else {
            Write-Host "      -> Пропущено." -ForegroundColor DarkGray
        }
        if ($null -ne $useCommonScriptsVal) { $forgeData["require"]["useCommonScripts"] = $useCommonScriptsVal }

        # 6.3 Packages
        Write-Host "    [6.3] Обработка локальных Packages..." -ForegroundColor DarkGray
        if (Test-Path $context.PackagesJsonPath) {
            try {
                $packagesJsonContent = Get-Content $context.PackagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $currentPkgVersion = $packagesJsonContent.version
                if ($currentPkgVersion -eq $packages_version) {
                    $packagesList = $packagesJsonContent.packages
                    if ($packagesList) {
                        if ($packagesList -isnot [System.Array]) { $packagesList = @($packagesList) }
                        foreach ($pkg in $packagesList) {
                            if (-not [string]::IsNullOrWhiteSpace($pkg.name) -and -not [string]::IsNullOrWhiteSpace($pkg.version)) {
                                $forgeData["require"][$pkg.name] = $pkg.version
                                Write-Host "      -> Add require: " -ForegroundColor Green -NoNewline
                                Write-Host "$($pkg.name) = $($pkg.version)" -ForegroundColor Yellow
                            } else {
                                Write-Host "      [!] " -ForegroundColor Red -NoNewline
                                Write-Host "Warning: У пакета отсутствуют name или version. Пропуск." -ForegroundColor Yellow
                            }
                        }
                    }
                } else {
                    Write-Host "      [!] " -ForegroundColor Red -NoNewline
                    Write-Host "Warning: Текущая версия packages несовместима. Содержимое проигнорировано." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "      [!] " -ForegroundColor Red -NoNewline
                Write-Host "Warning: Ошибка чтения packages.json. Содержимое проигнорировано." -ForegroundColor Yellow
            }
        } else { Write-Host "      -> Файл packages.json не найден." -ForegroundColor DarkGray }

        
        # 7. Files (others)
        Write-Host "  [7/7] Определение 'files.others'..." -ForegroundColor Gray
        
        # Используем ArrayList для защиты от unroll-эффекта при 1 элементе
        $othersList = [System.Collections.ArrayList]::new()
        foreach ($ref in $scriptRefs) {
            $normRef = $ref.Replace("\", "/")
            if ($normRef -notmatch "^(/Mods/SampleCommon|Packages/)") { 
                [void]$othersList.Add($normRef)
            }
        }
        
        $forgeData["files"] = [ordered]@{ others = $othersList }
        
        foreach ($item in $othersList) {
            Write-Host "    -> Add: " -ForegroundColor Green -NoNewline
            Write-Host "- ${item}" -ForegroundColor Yellow
        }
        
        Write-Host ""

        # Сохранение
        Write-Host "Сохранение JSON..." -ForegroundColor Gray
        $mgr = [ForgeJsonManager]::new($context.ForgeJsonPath)
        $mgr.Data = [PSCustomObject]$forgeData
        $mgr.Save()
        Write-Host "Файл forge.json успешно создан." -ForegroundColor Green
    }
}

# --- Работа с Packages ---
$packagesDir = $context.PackagesDir
$packagesJsonPath = $context.PackagesJsonPath
$actionToPerform = $null
$actionArg = $null

Write-Host ""
Write-Host "Packages..." -ForegroundColor Yellow
if (Test-Path $packagesJsonPath) {
    try {
        $pkgJsonContent = Get-Content $packagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pkgJsonContent.version -ne $packages_version) {
            Write-Host "  [!] Версия packages.json несовместима." -ForegroundColor Red
            Backup-PackagesFolder -Path $packagesDir -AddonRoot $selectedAddon.FullName
            $actionToPerform = "install"
        } else {
            Write-Host "  -> Версия packages.json совместима ($($pkgJsonContent.version))." -ForegroundColor Green
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
        Backup-PackagesFolder -Path $packagesDir -AddonRoot $selectedAddon.FullName
        $actionToPerform = "install"
    }
} else {
    if (Test-Path $packagesDir) {
        $hasFiles = Get-ChildItem -Path $packagesDir -Recurse -File -ErrorAction SilentlyContinue
        if ($hasFiles) { Backup-PackagesFolder -Path $packagesDir -AddonRoot $selectedAddon.FullName }
        else { Remove-Item -Path $packagesDir -Recurse -Force }
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
            $actionToPerform = "install";
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
    Write-Host "Подготовка к изменению зависимостей..." -ForegroundColor Yellow
    Backup-XdbFile -AddonRoot $selectedAddon.FullName
    
    switch ($actionToPerform) {
        "install" { Write-Host "[Заглушка] Логика install..." -ForegroundColor DarkGray }
        "remove"  { Write-Host "[Заглушка] Логика remove для $actionArg..." -ForegroundColor DarkGray }
        "require" {
            if ($actionArg -match "^[^/]+/[^/]+$") {
                $downloader = [PackageDownloader]::new($context.PackagesJsonPath)
                $downloader.ResolveTrueCasing($actionArg)
                $actionArg = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
                Write-Host "[Require] Начинаем подключение: $actionArg" -ForegroundColor Cyan
                
                $forgeMgr = [ForgeJsonManager]::new($context.ForgeJsonPath)
                $xdbMgr = [XdbManager]::new($context.XdbPath)

                $latestTag = $downloader.GetLatestTag($actionArg)
                if (-not $latestTag) { break }

                $remoteForge = $downloader.DownloadRemoteForge($actionArg)
                if (-not $remoteForge) { break }

                $downloader.DownloadFiles($actionArg, $remoteForge)
                # 4. Обновление данных packages.json в памяти
                $downloader.UpdatePackagesJson($remoteForge, $latestTag)
                
                # 4.1. Сохранение packages.json на диск
                $pkgMgr = [ForgeJsonManager]::new($context.PackagesJsonPath)
                $pkgMgr.Data = $downloader.PackagesData
                $pkgMgr.Save()
                Write-Host "  -> packages.json обновлен." -ForegroundColor Green

                $forgeMgr.UpdateFromRemote($remoteForge, $latestTag, $actionArg)
                $forgeMgr.Save()
                Write-Host "  -> Локальный forge.json обновлен." -ForegroundColor Green

                $xdbMgr.ApplyForgeChanges($forgeMgr.Data)
                $xdbMgr.Save()
                Write-Host "  -> AddonDesc.(UIAddon).xdb обновлен." -ForegroundColor Green

                Write-Host "[Success] Пакет $actionArg успешно подключен" -ForegroundColor Green
            } else {
                Write-Host "[Ошибка] Неверный формат. Ожидается: Владелец/Репозиторий" -ForegroundColor Red
            }
        }
        "update"  {
            if ($actionArg -eq "all") {
                Write-Host "[TODO] Обновление всех пакетов..." -ForegroundColor Yellow
            } elseif ($actionArg -match "^[^/]+/[^/]+$") {
                $downloader = [PackageDownloader]::new($context.PackagesJsonPath)
                $downloader.ResolveTrueCasing($actionArg)
                $actionArg = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
                Write-Host "[Update] Начинаем обновление: $actionArg" -ForegroundColor Cyan
                
                $forgeMgr = [ForgeJsonManager]::new($context.ForgeJsonPath)
                $xdbMgr = [XdbManager]::new($context.XdbPath)

                $foundPkg = $downloader.FindPackage($actionArg)
                if (-not $foundPkg) {
                    Write-Host "[Ошибка] Пакет не найден. Подключите через require." -ForegroundColor Red
                    break
                }

                $latestTag = $downloader.GetLatestTag($actionArg)
                if (-not $latestTag) { break }
                if ($latestTag -eq $foundPkg.version.ToString().Trim()) {
                    Write-Host "[Info] Последняя версия уже установлена." -ForegroundColor Yellow
                    break
                }

                $remoteForge = $downloader.DownloadRemoteForge($actionArg)
                if (-not $remoteForge) { break }

                $downloader.DownloadFiles($actionArg, $remoteForge)
                # 5. Обновление данных packages.json в памяти
                $downloader.UpdatePackagesJson($remoteForge, $latestTag)
                
                # 5.1. Сохранение packages.json на диск
                $pkgMgr = [ForgeJsonManager]::new($context.PackagesJsonPath)
                $pkgMgr.Data = $downloader.PackagesData
                $pkgMgr.Save()
                Write-Host "  -> packages.json обновлен." -ForegroundColor Green

                $forgeMgr.UpdateFromRemote($remoteForge, $latestTag, $actionArg)
                $forgeMgr.Save()
                Write-Host "  -> Локальный forge.json обновлен." -ForegroundColor Green

                $xdbMgr.ApplyForgeChanges($forgeMgr.Data)
                $xdbMgr.Save()
                Write-Host "  -> AddonDesc.(UIAddon).xdb обновлен." -ForegroundColor Green

                Write-Host "[Успех] Пакет $actionArg обновлен до $latestTag!" -ForegroundColor Green
            } else {
                Write-Host "[Ошибка] Неверный формат. Ожидается: Владелец/Репозиторий" -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host "Действия были отменены." -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Нажмите Enter для выхода"