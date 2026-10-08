# =============================================
# Classes/PackageDownloader.ps1
# =============================================
class PackageDownloader {
    [hashtable]$Headers
    [string]$PackagesJsonPath
    [PSCustomObject]$PackagesData
    [string]$ResolvedOwner
    [string]$ResolvedRepo
    [hashtable]$ForgeCache
    [ForgeJsonManager]$MainForgeManager

    PackageDownloader([string]$packagesJsonPath, [ForgeJsonManager]$mainForgeManager) {
        $this.PackagesJsonPath = $packagesJsonPath
        $this.MainForgeManager = $mainForgeManager
        $this.Headers = @{ "User-Agent" = "PowerShell-ForgeScript" }
        $this.ForgeCache = @{}
        if (Test-Path $packagesJsonPath) {
            $raw = Get-Content $packagesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $raw.packages -and $raw.packages -isnot [array]) {
                $raw.packages = [array]$raw.packages
            }
            $this.PackagesData = $raw
        }
    }

    [void]ResolveTrueCasing([string]$packageName) {
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        try {
            $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo" -Headers $this.Headers
            $this.ResolvedOwner = $repoInfo.owner.login
            $this.ResolvedRepo  = $repoInfo.name
        } catch {
            $this.ResolvedOwner = $owner
            $this.ResolvedRepo  = $repo
        }
    }

    [PSCustomObject]FindPackage([string]$tag) {
        if (-not $this.PackagesData -or -not $this.PackagesData.packages) { return $null }
        $list = $this.PackagesData.packages
        if ($list -isnot [array]) { $list = [array]$list }
        $targetTag = $tag.Trim().ToLower()
        for ($i = 0; $i -lt $list.Count; $i++) {
            $currentTag = $list[$i].tag
            if ($null -eq $currentTag) { continue }
            if ($currentTag.ToString().Trim().ToLower() -eq $targetTag) {
                return $list[$i]
            }
        }
        return $null
    }

    [string]GetLatestTag([string]$packageName) {
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        try {
            $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/tags" -Headers $this.Headers
            if ($tags.Count -eq 0) { return $null }
            if ($tags -isnot [array]) { return $tags.name }
            return $tags[0].name
        } catch {
            if ($_.Exception.Message -match "404") {
                Write-Host "Репозиторий '$packageName' не найден (404)." -ForegroundColor Red
            } else {
                Write-Host "Не удалось получить теги для '$packageName'." -ForegroundColor Red
            }
            return $null
        }
    }

    [PSCustomObject]DownloadRemoteForge([string]$packageName, [string]$tag) {
        $cacheKey = "$packageName@$tag".ToLower()
        if ($this.ForgeCache.ContainsKey($cacheKey)) {
            return $this.ForgeCache[$cacheKey]
        }
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        try {
            $url = "https://raw.githubusercontent.com/$owner/$repo/$tag/forge.json"
            $content = Invoke-RestMethod -Uri $url -Headers $this.Headers
            $content | Add-Member -NotePropertyName "_owner" -NotePropertyValue $owner -Force
            $content | Add-Member -NotePropertyName "_repo"  -NotePropertyValue $repo  -Force
            $this.ForgeCache[$cacheKey] = $content
            return $content
        } catch {
            Write-Host "Файл forge.json отсутствует в репозитории по тегу $tag." -ForegroundColor Red
            return $null
        }
    }

    [string]DownloadFiles([string]$packageName, [PSCustomObject]$remoteForge, [string]$tag) {
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        $branchOrTag = if ([string]::IsNullOrWhiteSpace($tag)) { "main" } else { $tag }
        $filesToDownload = [System.Collections.ArrayList]::new()
        if ($remoteForge.execute -and $remoteForge.execute.unpack) {
            $unpack = $remoteForge.execute.unpack
            if ($unpack -isnot [array]) { $unpack = [array]$unpack }
            [void]$filesToDownload.AddRange([object[]]$unpack)
        } else {
            if ($remoteForge.files) {
                foreach ($prop in $remoteForge.files.PSObject.Properties) {
                    [void]$filesToDownload.Add($prop.Name)
                }
            }
        }
        $remoteName = $remoteForge.name
        $dirName = if (-not [string]::IsNullOrWhiteSpace($remoteName)) { $remoteName } else { $repo }
        $packagesDir = Split-Path $this.PackagesJsonPath -Parent
        $targetDir   = Join-Path $packagesDir "$owner\$dirName"
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        foreach ($file in $filesToDownload) {
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            $fileUrl   = "https://raw.githubusercontent.com/$owner/$repo/$branchOrTag/$file"
            $localPath = Join-Path $targetDir $file
            $localDir  = Split-Path $localPath -Parent
            if (-not (Test-Path $localDir)) {
                New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            }
            try {
                Invoke-WebRequest -Uri $fileUrl -OutFile $localPath -Headers $this.Headers -ErrorAction Stop
                Write-Host "  -> Download: $file" -ForegroundColor DarkGray
            } catch {
                Write-Host "  -> Не удалось скачать: $file" -ForegroundColor Red
            }
        }

        # Обработка вложенных зависимостей из require
        if ($remoteForge.require) {
            foreach ($reqProp in $remoteForge.require.PSObject.Properties) {
                $reqTag = $reqProp.Name
                $reqVersion = $reqProp.Value
                
                # Пропуск системных ключей
                if ($reqTag -in @('api', 'useCommonScripts')) { continue }
                
                # Проверка формата тега
                if ($reqTag -notmatch "^[^/]+/[^/]+$") { continue }
                
                Write-Host "  -> Found nested dependency: $reqTag [$reqVersion]" -ForegroundColor DarkYellow
                
                # Проверка наличия уже установленной версии
                $existingNestedPkg = $this.FindPackage($reqTag)
                if ($existingNestedPkg -and $existingNestedPkg.version.ToString().Trim() -eq $reqVersion.ToString().Trim()) {
                    Write-Host "     -> Dependency already installed." -ForegroundColor DarkGray
                    continue
                }
                
                # Скачивание forge.json вложенной зависимости
                $nestedForge = $this.DownloadRemoteForge($reqTag, $reqVersion)
                if (-not $nestedForge) {
                    Write-Host "     -> Failed to fetch nested dependency forge.json." -ForegroundColor Red
                    continue
                }
                
                # Рекурсивный вызов скачивания файлов
                $this.DownloadFiles($reqTag, $nestedForge, $reqVersion)
                
                # Регистрация вложенной зависимости в packages.json
                $this.UpdatePackagesJson($nestedForge, $reqVersion)

                # Добавление вложенной зависимости в основной forge.json
                if ($this.MainForgeManager) {
                    $this.MainForgeManager.UpdateRequire($reqTag, $reqVersion)
                }
            }
        }
        return "Packages/$owner/$dirName".Replace('\', '/')
    }

    [void]UpdatePackagesJson([PSCustomObject]$remoteForge, [string]$newVersion) {
        $tagValue = "$($remoteForge._owner)/$($remoteForge._repo)"
        if ($remoteForge.PSObject.Properties['_owner']) { $remoteForge.PSObject.Properties.Remove('_owner') }
        if ($remoteForge.PSObject.Properties['_repo'])  { $remoteForge.PSObject.Properties.Remove('_repo') }
        if ($remoteForge.PSObject.Properties['tag']) { $remoteForge.tag = $tagValue }
        else { $remoteForge | Add-Member -NotePropertyName "tag" -NotePropertyValue $tagValue -Force }
        if ($remoteForge.PSObject.Properties['version']) { $remoteForge.version = $newVersion }
        else { $remoteForge | Add-Member -NotePropertyName "version" -NotePropertyValue $newVersion -Force }
        if ($remoteForge.PSObject.Properties['type']) { $remoteForge.type = "Library" }
        else { $remoteForge | Add-Member -NotePropertyName "type" -NotePropertyValue "Library" -Force }
        if (-not $this.PackagesData) {
            $this.PackagesData = [PSCustomObject]@{ version = "v1"; packages = [array]@() }
        }
        if (-not ($this.PackagesData.PSObject.Properties.Name -contains 'packages')) {
            $this.PackagesData | Add-Member -NotePropertyName "packages" -NotePropertyValue ([array]@()) -Force
        }
        $list = [System.Collections.ArrayList]::new()
        $current = $this.PackagesData.packages
        if ($null -ne $current) {
            if ($current -is [array]) { [void]$list.AddRange([object[]]$current) }
            else { [void]$list.Add($current) }
        }
        $foundIndex = -1
        for ($i = 0; $i -lt $list.Count; $i++) {
            $currentTag = $list[$i].tag
            if ($null -ne $currentTag -and $currentTag.ToString().Trim().ToLower() -eq $tagValue.ToLower()) {
                $foundIndex = $i
                break
            }
        }
        if ($foundIndex -ge 0) { $list[$foundIndex] = $remoteForge }
        else { [void]$list.Add($remoteForge) }
        $this.PackagesData.packages = [array]$list.ToArray()
    }

    [void]RemoveFromPackagesJson([string]$tag) {
        if (-not $this.PackagesData -or -not $this.PackagesData.packages) { return }
        $list = [System.Collections.ArrayList]::new()
        $current = $this.PackagesData.packages
        if ($current -is [array]) { [void]$list.AddRange([object[]]$current) }
        elseif ($null -ne $current) { [void]$list.Add($current) }
        $targetTag = $tag.Trim().ToLower()
        for ($i = $list.Count - 1; $i -ge 0; $i--) {
            $currentTag = $list[$i].tag
            if ($null -ne $currentTag -and $currentTag.ToString().Trim().ToLower() -eq $targetTag) {
                $list.RemoveAt($i)
            }
        }
        $this.PackagesData.packages = [array]$list.ToArray()
    }
}