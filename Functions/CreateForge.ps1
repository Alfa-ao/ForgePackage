# =============================================
# Functions/CreateForge.ps1
# =============================================

# Извлечение логики чтения версии API из game.version
function Get-GameApiVersion {
    param([string]$GameInstallPath)
    $gameVersionFile = Join-Path $GameInstallPath "Profiles\game.version"
    $apiVersion = $null
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
                }
            }
        } catch {
            Write-Host "  -> Ошибка чтения game.version." -ForegroundColor Yellow
        }
    }
    return $apiVersion
}

# Синхронизация версии API в forge.json с актуальной версией игры
function Sync-ForgeApiVersion {
    param(
        [ForgeJsonManager]$ForgeMgr,
        [string]$GameInstallPath
    )
    if (-not $ForgeMgr.Data) { return }
    
    $actualApi = Get-GameApiVersion -GameInstallPath $GameInstallPath
    if ([string]::IsNullOrWhiteSpace($actualApi)) {
        Write-Host "  -> Не удалось получить актуальную версию API." -ForegroundColor Yellow
        return
    }

    if (-not $ForgeMgr.Data.require) {
        $ForgeMgr.Data | Add-Member -NotePropertyName "require" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $currentApi = $ForgeMgr.Data.require.api
    if ($currentApi -ne $actualApi) {
        Write-Host "  -> Update version: '$currentApi' -> '$actualApi'" -ForegroundColor DarkGray
        $ForgeMgr.Data.require | Add-Member -NotePropertyName "api" -NotePropertyValue $actualApi -Force
        $ForgeMgr.Save()
    }
}

function New-ForgeJson {
    param(
        [ForgeContext]$Context,
        [ForgeConfig]$Config,
        [string]$GameInstallPath
    )

    $createForge = Read-Host "Файл forge.json не найден. Создать? (Y/N)"
    if ($createForge -match '^[Yy1]$') {
        Write-WarningBlock -Text "Create: Инициализация создания forge.json..."
        $forgeData = [ordered]@{}
        
        Write-Host "  [1/8] Определение 'name'..." -ForegroundColor Gray
        $forgeData["name"] = $selectedAddon.Name
        Write-Host "    -> Установлено: $($selectedAddon.Name)" -ForegroundColor Green
        
        Write-Host "  [2/8] Определение 'description'..." -ForegroundColor Gray
        $forgeData["description"] = ""
        Write-Host "    -> Установлено: (пусто)" -ForegroundColor Green
        
        Write-Host "  [3/8] Определение 'type'..." -ForegroundColor Gray
        $forgeData["type"] = "Addon"
        Write-Host "    -> Установлено: Addon" -ForegroundColor Green
        
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
        
        Write-Host "  [5/8] Определение 'license'..." -ForegroundColor Gray
        $forgeData["license"] = "MIT"
        Write-Host "    -> Установлено: MIT" -ForegroundColor Green
        
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
        
        Write-Host "  [7/8] Определение 'require'..." -ForegroundColor Gray
        $forgeData["require"] = [ordered]@{}
        
        Write-Host "    Определение 'api'..." -ForegroundColor DarkGray
        
        $apiVersion = Get-GameApiVersion -GameInstallPath $GameInstallPath
        if ([string]::IsNullOrWhiteSpace($apiVersion)) {
            Write-Host "      -> Версия API не найдена." -ForegroundColor Yellow
            $apiVersion = Read-Host "      Введите версию API"
            if ([string]::IsNullOrWhiteSpace($apiVersion)) { $apiVersion = "18.0.0" }
        } else {
            Write-Host "      -> Версия API найдена: $apiVersion" -ForegroundColor DarkGray
        }
        $forgeData["require"]["api"] = $apiVersion
        Write-Host "      -> Установлена версия API: $apiVersion" -ForegroundColor Green
        
        Write-Host "    Определение 'useCommonScripts'..." -ForegroundColor DarkGray
        $useCommonScriptsVal = $false
        if ($xmlContent -and $xmlContent.UIAddon.userAddonInfo.useCommonScripts -eq 'true') {
            $useCommonScriptsVal = $true
            Write-Host "      -> Установлено: true. Пользовательское подключение SampleCommon игнорируется." -ForegroundColor Green
        } else {
            Write-Host "      -> Установлено: false." -ForegroundColor Green
        }
        $forgeData["require"]["useCommonScripts"] = $useCommonScriptsVal
        
        Write-Host "    Обработка локальных Packages..." -ForegroundColor DarkGray
        if (Test-Path $context.PackagesJsonPath) {
            try {
                $packagesJsonContent = Get-Content $context.PackagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $currentPkgVersion = $packagesJsonContent.version
                
                if ($currentPkgVersion -eq $config.PackagesVersion) {
                    $packagesList = $packagesJsonContent.packages
                    if ($null -ne $packagesList -and $packagesList -isnot [array]) {
                        $packagesList = [array]$packagesList
                    }
                    
                    if ($packagesList) {
                        foreach ($pkg in $packagesList) {
                            if (-not [string]::IsNullOrWhiteSpace($pkg.tag) -and -not [string]::IsNullOrWhiteSpace($pkg.version)) {
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
        
        Write-Host "  [8/8] Определение 'files'..." -ForegroundColor Gray
        $scriptRefs = @()
        if ($xmlContent -and $xmlContent.UIAddon.ScriptFileRefs) {
            $items = $xmlContent.UIAddon.ScriptFileRefs.Item
            if ($items) {
                if ($items -isnot [array]) { $items = @($items) }
                $scriptRefs = $items | ForEach-Object { $_.href }
            }
        }
        
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
        
        Write-Host "Сохранение JSON..." -ForegroundColor Gray
        $mgr = [ForgeJsonManager]::new($context.ForgeJsonPath)
        $mgr.Data = [PSCustomObject]$forgeData
        $mgr.Save()
        Write-Host "Файл forge.json успешно создан." -ForegroundColor Yellow
    } else {
        Stop-Process -Id $PID -Force
    }
}