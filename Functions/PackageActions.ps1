# =============================================
# Functions/PackageActions.ps1
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
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath, $forgeMgr)
    if (-not $downloader.PackagesData) {
        $downloader.PackagesData = [PSCustomObject]@{
            version  = "v1"
            packages = [array]@()
        }
    }
    $installedCount = 0
    $skippedCount = 0
    foreach ($prop in $requireNode.PSObject.Properties) {
        $tagName = $prop.Name
        $reqVersion = $prop.Value
        if ($tagName -in @('api', 'useCommonScripts')) { continue }
        if ($tagName -notmatch "^[^/]+/[^/]+$") {
            Write-Host "  -> Некорректный формат тега (ожидается Owner/Repo): $tagName" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        Write-Host "  -> Check: $tagName [$reqVersion]" -ForegroundColor DarkGray
        $downloader.ResolveTrueCasing($tagName)
        $resolvedTag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
        $existingPkg = $downloader.FindPackage($resolvedTag)
        if ($existingPkg -and $existingPkg.version.ToString().Trim() -eq $reqVersion.ToString().Trim()) {
            Write-Host "     -> Уже установлен (версия совпадает)." -ForegroundColor DarkGray
            $skippedCount++
            continue
        }
        if ($existingPkg) {
            $oldPkgName = if (-not [string]::IsNullOrWhiteSpace($existingPkg.name)) { $existingPkg.name } else { $downloader.ResolvedRepo }
            $oldPkgPath = "Packages/$($downloader.ResolvedOwner)/$oldPkgName"
            $localOldPkgDir = Join-Path $Ctx.SelectedAddon.FullName $oldPkgPath
            if (Test-Path $localOldPkgDir) {
                $filesToRemove = [System.Collections.ArrayList]::new()
                if ($existingPkg.files) {
                    foreach ($prop in $existingPkg.files.PSObject.Properties) {
                        [void]$filesToRemove.Add($prop.Name)
                    }
                }
                foreach ($file in $filesToRemove) {
                    $filePath = Join-Path $localOldPkgDir $file
                    if (Test-Path $filePath) {
                        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                    }
                }
                Get-ChildItem -Path $localOldPkgDir -Directory -Recurse -Force |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    $items = Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    if ($null -eq $items -or $items.Count -eq 0) {
                        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
                $repoItems = Get-ChildItem -Path $localOldPkgDir -Force -ErrorAction SilentlyContinue
                if ($null -eq $repoItems -or $repoItems.Count -eq 0) {
                    Remove-Item -Path $localOldPkgDir -Force -ErrorAction SilentlyContinue
                    $ownerDir = Split-Path -Path $localOldPkgDir -Parent
                    if (Test-Path $ownerDir) {
                        $ownerItems = Get-ChildItem -Path $ownerDir -Force -ErrorAction SilentlyContinue
                        if ($null -eq $ownerItems -or $ownerItems.Count -eq 0) {
                            Remove-Item -Path $ownerDir -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                Write-Host "     -> Удалена старая версия." -ForegroundColor DarkGray
            }
        }
        $remoteForge = $downloader.DownloadRemoteForge($resolvedTag, $reqVersion)
        if (-not $remoteForge) {
            Write-Host "     -> Не удалось получить forge.json." -ForegroundColor Red
            $skippedCount++
            continue
        }
        if (-not $downloader.DownloadFiles($resolvedTag, $remoteForge, $reqVersion)) {
            Write-Host "     -> Не удалось скачать файлы." -ForegroundColor Red
            $skippedCount++
            continue
        }
        $downloader.UpdatePackagesJson($remoteForge, $reqVersion)
        $forgeMgr.UpdateRequire($resolvedTag, $reqVersion)
        $installedCount++
        Write-Host "     -> Успешно установлено $tagName [$reqVersion]" -ForegroundColor Yellow
    }
    $packagesDir = Split-Path $Ctx.PackagesJsonPath -Parent
    if (-not (Test-Path $packagesDir)) {
        New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
    }
    if ($installedCount -gt 0 -or $skippedCount -gt 0 -or -not (Test-Path $Ctx.PackagesJsonPath)) {
        $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
        $pkgMgr.Data = $downloader.PackagesData
        $pkgMgr.Save()
        Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    }
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    $xdbMgr = [XdbManager]::new($Ctx.XdbPath)
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data, $downloader.PackagesData)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    Write-Host "Установка завершена. Установлено: $installedCount, Пропущено: $skippedCount" -ForegroundColor DarkGray
}

function Require-Package {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath, $forgeMgr)
    $downloader.ResolveTrueCasing($TargetTag)
    $tag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
    $existingPkg = $downloader.FindPackage($tag)
    if ($null -ne $existingPkg) {
        Write-Host "  Пакет $tag уже подключен (версия $($existingPkg.version))." -ForegroundColor Yellow
        Write-Host "    Для обновления используйте команду: update $tag" -ForegroundColor Gray
        return
    }
    Write-Host "Connection: $tag" -ForegroundColor DarkGray
    $xdbMgr   = [XdbManager]::new($Ctx.XdbPath)
    $latestTag = $downloader.GetLatestTag($tag)
    if (-not $latestTag) { return }
    $remoteForge = $downloader.DownloadRemoteForge($tag, $latestTag)
    if (-not $remoteForge) { return }
    if (-not $downloader.DownloadFiles($tag, $remoteForge, $latestTag)) {
        Write-Host "  -> Не удалось скачать файлы." -ForegroundColor Red
        return
    }
    $downloader.UpdatePackagesJson($remoteForge, $latestTag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    $forgeMgr.UpdateRequire($tag, $latestTag)
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data, $downloader.PackagesData)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    Write-Log "Success" "$tag [$latestTag] required." "Green" "Gray"
}

function Remove-Package {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath, $forgeMgr)
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
    if (Test-Path $localPkgDir) {
        $filesToRemove = [System.Collections.ArrayList]::new()
        if ($foundPkg.files) {
            foreach ($prop in $foundPkg.files.PSObject.Properties) {
                [void]$filesToRemove.Add($prop.Name)
            }
        }
        foreach ($file in $filesToRemove) {
            $filePath = Join-Path $localPkgDir $file
            if (Test-Path $filePath) {
                Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                Write-Host "  -> Removed file: $file" -ForegroundColor DarkGray
            }
        }
        Get-ChildItem -Path $localPkgDir -Directory -Recurse -Force |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            $items = Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue
            if ($null -eq $items -or $items.Count -eq 0) {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        $repoItems = Get-ChildItem -Path $localPkgDir -Force -ErrorAction SilentlyContinue
        if ($null -eq $repoItems -or $repoItems.Count -eq 0) {
            Remove-Item -Path $localPkgDir -Force -ErrorAction Stop
            Write-Host "  -> Removed folder: $pkgPath" -ForegroundColor DarkGray
            $ownerDir = Split-Path -Path $localPkgDir -Parent
            if (Test-Path $ownerDir) {
                $ownerItems = Get-ChildItem -Path $ownerDir -Force -ErrorAction SilentlyContinue
                if ($null -eq $ownerItems -or $ownerItems.Count -eq 0) {
                    Remove-Item -Path $ownerDir -Force -ErrorAction Stop
                    Write-Host "  -> Removed folder: $(Split-Path $ownerDir -Leaf)" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "  -> Folder $pkgPath not deleted." -ForegroundColor DarkGray
        }
    }
    $xdbMgr   = [XdbManager]::new($Ctx.XdbPath)
    $downloader.RemoveFromPackagesJson($tag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json clear." -ForegroundColor DarkGray
    $forgeMgr.RemoveRequire($tag)
    $forgeMgr.Save()
    Write-Host "  -> forge.json clear." -ForegroundColor DarkGray
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data, $downloader.PackagesData)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    Write-Log "Success" "$tag removed." "Green" "Gray"
}

function Update-SinglePackage {
    param(
        [string]$TargetTag,
        [ForgeContext]$Ctx
    )
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $downloader = [PackageDownloader]::new($Ctx.PackagesJsonPath, $forgeMgr)
    $downloader.ResolveTrueCasing($TargetTag)
    $tag = "$($downloader.ResolvedOwner)/$($downloader.ResolvedRepo)"
    Write-Log "Update" $tag "Green" "Gray"
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
    $oldPkgName = if (-not [string]::IsNullOrWhiteSpace($foundPkg.name)) { $foundPkg.name } else { $downloader.ResolvedRepo }
    $oldPkgPath = "Packages/$($downloader.ResolvedOwner)/$oldPkgName"
    $localOldPkgDir = Join-Path $Ctx.SelectedAddon.FullName $oldPkgPath
    if (Test-Path $localOldPkgDir) {
        $filesToRemove = [System.Collections.ArrayList]::new()
        if ($foundPkg.files) {
            foreach ($prop in $foundPkg.files.PSObject.Properties) {
                [void]$filesToRemove.Add($prop.Name)
            }
        }
        foreach ($file in $filesToRemove) {
            $filePath = Join-Path $localOldPkgDir $file
            if (Test-Path $filePath) {
                Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
                Write-Host "  -> Removed file: $file" -ForegroundColor DarkGray
            }
        }
        Get-ChildItem -Path $localOldPkgDir -Directory -Recurse -Force |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            $items = Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue
            if ($null -eq $items -or $items.Count -eq 0) {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        $repoItems = Get-ChildItem -Path $localOldPkgDir -Force -ErrorAction SilentlyContinue
        if ($null -eq $repoItems -or $repoItems.Count -eq 0) {
            Remove-Item -Path $localOldPkgDir -Force -ErrorAction Stop
            Write-Host "  -> Removed folder: $oldPkgPath" -ForegroundColor DarkGray
            $ownerDir = Split-Path -Path $localOldPkgDir -Parent
            if (Test-Path $ownerDir) {
                $ownerItems = Get-ChildItem -Path $ownerDir -Force -ErrorAction SilentlyContinue
                if ($null -eq $ownerItems -or $ownerItems.Count -eq 0) {
                    Remove-Item -Path $ownerDir -Force -ErrorAction Stop
                    Write-Host "  -> Removed folder: $(Split-Path $ownerDir -Leaf)" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "  -> Папка $oldPkgPath содержит файлы других пакетов, не удалена." -ForegroundColor Yellow
        }
    }
    $downloader.DownloadFiles($tag, $remoteForge, $latestTag)
    $downloader.UpdatePackagesJson($remoteForge, $latestTag)
    $pkgMgr = [ForgeJsonManager]::new($Ctx.PackagesJsonPath)
    $pkgMgr.Data = $downloader.PackagesData
    $pkgMgr.Save()
    Write-Host "  -> packages.json updated." -ForegroundColor DarkGray
    $forgeMgr.UpdateRequire($tag, $latestTag)
    $forgeMgr.Save()
    Write-Host "  -> forge.json updated." -ForegroundColor DarkGray
    $xdbMgr.ApplyForgeChanges($forgeMgr.Data, $downloader.PackagesData)
    $xdbMgr.Save()
    Write-Host "  -> AddonDesc.(UIAddon).xdb updated." -ForegroundColor DarkGray
    Write-Log "Success" "$tag updated to ${latestTag}." "Green" "Gray"
}

function Update-AllPackages {
    param(
        [ForgeContext]$Ctx
    )
    Write-Host "Обновление всех пакетов..." -ForegroundColor Yellow
    $forgeMgr = [ForgeJsonManager]::new($Ctx.ForgeJsonPath)
    $tempDownloader = [PackageDownloader]::new($Ctx.PackagesJsonPath, $forgeMgr)
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
        Update-SinglePackage -TargetTag $currentTag -Ctx $Ctx
        $updatedCount++
    }
    Write-Host "Обновление завершено. Обработано пакетов: $updatedCount" -ForegroundColor DarkGray
}