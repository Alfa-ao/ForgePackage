# =============================================
# Functions/PackageActions.ps1 (Fragment)
# =============================================

function Install-PackageDependencies {
    param(
        [ForgeContext]$Ctx
    )
    
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    if (-not $forgeMgr.Data -or -not $forgeMgr.Data.require) {
        Write-Host "  -> В forge.json отсутствует секция require." -ForegroundColor Yellow
        return
    }
    
    $requireNode = $forgeMgr.Data.require
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath)
    
    # Инициализация структуры packages.json, если он отсутствует или поврежден
    if (-not $downloader.PackagesData) {
        $downloader.PackagesData = [PSCustomObject]@{
            version  = "v1"
            packages = [array]@()
        }
    }
    
    $installedCount = 0
    $skippedCount = 0
    
    # Перебор всех свойств в секции require
    foreach ($prop in $requireNode.PSObject.Properties) {
        $tagName = $prop.Name
        $reqVersion = $prop.Value
        
        # Пропуск служебных полей, не являющихся пакетами
        if ($tagName -in @('api', 'useCommonScripts')) { continue }
        
        # Проверка формата тега (Ожидается: Owner/Repo)
        if ($tagName -notmatch "^[^/]+/[^/]+$") {
            Write-Host "  -> Некорректный формат тега (ожидается Owner/Repo): $tagName" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        Write-Host "  -> Check: $tagName [$reqVersion]" -ForegroundColor DarkGray
        
        $downloader.ResolveTrueCasing($tagName)
        $resolvedTag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
        
        # Проверка: если пакет уже установлен с нужной версией, пропускаем
        $existingPkg = $downloader.FindPackage($resolvedTag)
        if ($existingPkg -and $existingPkg.version.ToString().Trim() -eq $reqVersion.ToString().Trim()) {
            Write-Host "     -> Уже установлен (версия совпадает)." -ForegroundColor DarkGray
            $skippedCount++
            continue
        }
        
        # Если версия отличается или пакета нет, удаляем старую папку (если есть)
        if ($existingPkg) {
            $oldPkgName = if (-not [string]::IsNullOrWhiteSpace($existingPkg.name)) { $existingPkg.name } else { $downloader.ResolvedRepo }
            $oldPkgPath = "Packages/$($downloader.ResolvedOwner)/$oldPkgName"
            $localOldPkgDir = Join-Path $Ctx.SelectedAddon.FullName $oldPkgPath
            if (Test-Path $localOldPkgDir) {
                Remove-Item -Path $localOldPkgDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "     -> Удалена старая версия." -ForegroundColor DarkGray
            }
        }
        
        # Скачивание forge.json конкретной версии из репозитория
        $remoteForge = $downloader.DownloadRemoteForge($resolvedTag, $reqVersion)
        if (-not $remoteForge) { 
            Write-Host "     -> Не удалось получить forge.json." -ForegroundColor Red
            $skippedCount++
            continue 
        }
        
        # Скачивание файлов пакета
        $packageRelativePath = $downloader.DownloadFiles($resolvedTag, $remoteForge, $reqVersion)
        if (-not $packageRelativePath) {
            Write-Host "     -> Не удалось скачать файлы." -ForegroundColor Red
            $skippedCount++
            continue
        }
        
        # Добавление/Обновление записи в packages.json
        $downloader.UpdatePackagesJson($remoteForge, $reqVersion)
        
        # Регистрация путей в локальном forge.json
        $forgeMgr.UpdateFromRemote($remoteForge, $reqVersion, $resolvedTag, $packageRelativePath)
        
        $installedCount++
        Write-Host "     -> Успешно установлено." -ForegroundColor Green
    }
    
    # [FIX] Критическое исправление: создание директории перед сохранением
    $packagesDir = Split-Path $Ctx.PackagesJsonPath -Parent
    if (-not (Test-Path $packagesDir)) {
        New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
        Write-Host "  -> Создана отсутствующая папка: $packagesDir" -ForegroundColor DarkGray
    }
    
    # Сохранение packages.json (если были изменения, пропуски или файла не было)
    if ($installedCount -gt 0 -or $skippedCount -gt 0 -or -not (Test-Path $Ctx.PackagesJsonPath)) {
        $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
        $pkgMgr.Data = $downloader.PackagesData
        $pkgMgr.Save()
        Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    }
    
    # Сохранение forge.json
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    
    # Применение изменений в AddonDesc.(UIAddon).xdb
    $xdbMgr = [XdbManager]::new($Ctx.XdbPath)
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    
    Write-Host "Установка завершена. Установлено: $installedCount, Пропущено: $skippedCount" -ForegroundColor Green
}

function Require-Package {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath)
    $downloader.ResolveTrueCasing($TargetTag)
    $tag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
    
    $existingPkg = $downloader.FindPackage($tag)
    if ($null -ne $existingPkg) {
        Write-Host "  Пакет $tag уже подключен (версия $($existingPkg.version))." -ForegroundColor Yellow
        Write-Host "    Для обновления используйте команду: update $tag" -ForegroundColor Gray
        return
    }
    
    Write-Host "Connection: $tag" -ForegroundColor DarkGray
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $xdbMgr   = [XdbManager]::new($Ctx.XdbPath)
    
    $latestTag = $downloader.GetLatestTag($tag)
    if (-not $latestTag) { return }
    
    $remoteForge = $downloader.DownloadRemoteForge($tag, $latestTag)
    if (-not $remoteForge) { return }
    
    $packageRelativePath = $downloader.DownloadFiles($tag, $remoteForge, $latestTag)
    
    $downloader.UpdatePackagesJson($remoteForge, $latestTag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    
    $forgeMgr.UpdateFromRemote($remoteForge, $latestTag, $tag, $packageRelativePath)
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    
    Write-Log "Success" "$tag [$latestTag] required." "Green" "Gray"
}

function Remove-Package {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath)
    $downloader.ResolveTrueCasing($TargetTag)
    $tag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
    Write-Log "Remove" $tag "DarkYellow" "Gray"
    
    $foundPkg = $downloader.FindPackage($tag)
    if (-not $foundPkg) {
        Write-Host "Пакет $tag не найден в packages.json" -ForegroundColor Red
        return
    }
    
    $pkgName = $foundPkg.name
    $pkgPath = "Packages/$($downloader.ResolvedOwner)/$pkgName"
    $localPkgDir = Join-Path $Ctx.SelectedAddon.FullName $pkgPath
    
    # Удаляет файлы и чистит пустые папки
    if (Test-Path $localPkgDir) {
        try {
            Get-ChildItem -Path $localPkgDir -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction Stop
            $repoItems = Get-ChildItem -Path $localPkgDir -Force -ErrorAction SilentlyContinue
            if ($null -eq $repoItems -or $repoItems.Count -eq 0) {
                Remove-Item -Path $localPkgDir -Force -ErrorAction Stop
                Write-Host "  -> Remove: $pkgPath" -ForegroundColor DarkGray
            } else {
                Write-Host "  -> Папка $pkgPath очищена, но не пуста (остались сторонние файлы)." -ForegroundColor Yellow
            }
            
            $ownerDir = Split-Path -Path $localPkgDir -Parent
            if (Test-Path $ownerDir) {
                $ownerItems = Get-ChildItem -Path $ownerDir -Force -ErrorAction SilentlyContinue
                if ($null -eq $ownerItems -or $ownerItems.Count -eq 0) {
                    Remove-Item -Path $ownerDir -Force -ErrorAction Stop
                    Write-Host "  -> Remove: $(Split-Path $ownerDir -Leaf)" -ForegroundColor DarkGray
                }
            }
        } catch {
            Write-Host "  -> Не удалось очистить/удалить папку: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  -> Папка $pkgPath не найдена." -ForegroundColor Yellow
    }
    
    # Очищает AddonDesc.(UIAddon).xdb
    $xdbMgr = [XdbManager]::new($Ctx.XdbPath)
    $xdbMgr.Load()
    $scriptRefsNode = $xdbMgr.XmlDoc.UIAddon.ScriptFileRefs
    if ($scriptRefsNode) {
        $itemsToRemove = @()
        $xmlItems = $scriptRefsNode.Item
        if ($null -ne $xmlItems) {
            if ($xmlItems -isnot [array]) { $xmlItems = [array]$xmlItems }
            foreach ($item in $xmlItems) {
                if ($item.href -like "$pkgPath/*" -or $item.href -eq $pkgPath) {
                    $itemsToRemove += $item
                }
            }
        }
        foreach ($item in $itemsToRemove) {
            $scriptRefsNode.RemoveChild($item) | Out-Null
        }
    }
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb clear." -ForegroundColor DarkGray
    
    # Очищает forge.json
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $forgeMgr.RemoveFromRemote($tag, $pkgPath)
    $forgeMgr.Save()
    Write-Host "  -> forge.json clear." -ForegroundColor DarkGray
    
    # Очищает packages.json
    $downloader.RemoveFromPackagesJson($tag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json clear." -ForegroundColor DarkGray
    
    Write-Log "Success" "$tag removed." "Green" "Gray"
}

function Update-SinglePackage {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath)
    $downloader.ResolveTrueCasing($TargetTag)
    $tag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
    Write-Log "Update" $tag "Green" "Gray"
    
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $xdbMgr   = [XdbManager]::new($Ctx.XdbPath)
    
    $foundPkg = $downloader.FindPackage($tag)
    if (-not $foundPkg) {
        Write-Host "Пакет не найден. Подключите через require $tag" -ForegroundColor Red
        return
    }
    
    $latestTag = $downloader.GetLatestTag($tag)
    if (-not $latestTag) { return }
    
    if ($latestTag -eq $foundPkg.version.ToString().Trim()) {
        Write-Host "Последняя версия уже установлена." -ForegroundColor Yellow
        return
    }
    
    $remoteForge = $downloader.DownloadRemoteForge($tag, $latestTag)
    if (-not $remoteForge) { return }
    
    # Определяет старый путь и удаляет папку
    $oldPkgName = if (-not [string]::IsNullOrWhiteSpace($foundPkg.name)) { $foundPkg.name } else { $downloader.ResolvedRepo }
    $oldPkgPath = "Packages/$($downloader.ResolvedOwner)/$oldPkgName"
    $localOldPkgDir = Join-Path $Ctx.SelectedAddon.FullName $oldPkgPath
    
    if (Test-Path $localOldPkgDir) {
        try {
            Get-ChildItem -Path $localOldPkgDir -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction Stop
            $repoItems = Get-ChildItem -Path $localOldPkgDir -Force -ErrorAction SilentlyContinue
            if ($null -eq $repoItems -or $repoItems.Count -eq 0) {
                Remove-Item -Path $localOldPkgDir -Force -ErrorAction Stop
                Write-Host "  -> Removed folder: $oldPkgPath" -ForegroundColor DarkGray
            }
            $ownerDir = Split-Path -Path $localOldPkgDir -Parent
            if (Test-Path $ownerDir) {
                $ownerItems = Get-ChildItem -Path $ownerDir -Force -ErrorAction SilentlyContinue
                if ($null -eq $ownerItems -or $ownerItems.Count -eq 0) {
                    Remove-Item -Path $ownerDir -Force -ErrorAction Stop
                    Write-Host "  -> Removed folder: $(Split-Path $ownerDir -Leaf)" -ForegroundColor DarkGray
                }
            }
        } catch {
            Write-Host "  -> Не удалось очистить/удалить старую папку: $_" -ForegroundColor Red
        }
    }
    
    # Скачивает новые файлы
    $packageRelativePath = $downloader.DownloadFiles($tag, $remoteForge, $latestTag)
    
    # Если имя пакета изменилось, то чистит старые пути из forge.json
    if ($oldPkgPath -ne $packageRelativePath) {
        $prefix = "$oldPkgPath/"
        foreach ($section in @('first', 'others', 'last')) {
            if ($forgeMgr.Data.files -and $forgeMgr.Data.files.$section) {
                $current = [ForgeJsonManager]::EnsureArray($forgeMgr.Data.files.$section)
                $filtered = [System.Collections.ArrayList]::new()
                foreach ($f in $current) {
                    if (-not ($f -like "$prefix*" -or $f -eq $oldPkgPath)) {
                        [void]$filtered.Add($f)
                    }
                }
                $forgeMgr.Data.files.$section = [array]$filtered.ToArray()
            }
        }
        Write-Host "  -> Старые пути пакета очищены из forge.json (имя изменилось)." -ForegroundColor DarkGray
    }
    
    # Перезаписывает весь remoteForge в packages.json
    $downloader.UpdatePackagesJson($remoteForge, $latestTag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    
    # Обновляет локальный forge.json и XDB
    $forgeMgr.UpdateFromRemote($remoteForge, $latestTag, $tag, $packageRelativePath)
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    
    Write-Log "Success" "$tag updated to ${latestTag}." "Green" "Gray"
}

function Update-AllPackages {
    param(
        [ForgeContext]$Ctx
    )
    Write-Host "Обновление всех пакетов..." -ForegroundColor Yellow
    
    $tempDownloader = [PackageDownloader]::new($Ctx.PackagesJsonPath)
    if (-not $tempDownloader.PackagesData -or -not $tempDownloader.PackagesData.packages) {
        Write-Host "Пакеты не найдены в packages.json." -ForegroundColor Yellow
        return
    }
    
    $packagesList = $tempDownloader.PackagesData.packages
    if ($packagesList -isnot [array]) { $packagesList = [array]$packagesList }
    
    $updatedCount = 0
    foreach ($pkg in $packagesList) {
        $currentTag = $pkg.tag
        if ([string]::IsNullOrWhiteSpace($currentTag)) { continue }
        
        # Вызов функции для каждого пакета (return внутри не прерывает цикл)
        Update-SinglePackage -TargetTag $currentTag -Ctx $Ctx
        $updatedCount++
    }
    
    Write-Host "Обновление завершено. Обработано пакетов: $updatedCount" -ForegroundColor DarkGray
}