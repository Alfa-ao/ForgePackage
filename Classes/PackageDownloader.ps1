# =============================================
# Classes/PackageDownloader.ps1
# =============================================
class PackageDownloader {
    [hashtable]$Headers
    [string]$PackagesJsonPath
    [PSCustomObject]$PackagesData
    [string]$ResolvedOwner
    [string]$ResolvedRepo

    PackageDownloader([string]$packagesJsonPath) {
        $this.PackagesJsonPath = $packagesJsonPath
        $this.Headers = @{ "User-Agent" = "PowerShell-ForgeScript" }
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
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        try {
            $url = "https://raw.githubusercontent.com/$owner/$repo/$tag/forge.json"
            $content = Invoke-RestMethod -Uri $url -Headers $this.Headers
            
            $content | Add-Member -NotePropertyName "_owner" -NotePropertyValue $owner -Force
            $content | Add-Member -NotePropertyName "_repo"  -NotePropertyValue $repo  -Force
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
        if ([string]::IsNullOrWhiteSpace($tag)) {
            Write-Host "(HELP) Тег не передан, используется ветка 'main'." -ForegroundColor Yellow
        }

        $filesToDownload = [System.Collections.ArrayList]::new()
        if ($remoteForge.execute -and $remoteForge.execute.unpack) {
            $unpack = $remoteForge.execute.unpack
            if ($unpack -isnot [array]) { $unpack = [array]$unpack }
            [void]$filesToDownload.AddRange([object[]]$unpack)
        } else {
            foreach ($section in @('first', 'others', 'last')) {
                $val = $remoteForge.files.$section
                if ($null -ne $val) {
                    if ($val -isnot [array]) { $val = [array]$val }
                    foreach ($f in $val) { [void]$filesToDownload.Add($f) }
                }
            }
        }

        $remoteName = $remoteForge.name
        $dirName = if (-not [string]::IsNullOrWhiteSpace($remoteName)) { $remoteName } else { $repo }
        
        if ([string]::IsNullOrWhiteSpace($this.PackagesJsonPath)) {
            Write-Host "PackagesJsonPath не инициализирован в PackageDownloader" -ForegroundColor Red
            return $null
        }

        $packagesDir = Split-Path $this.PackagesJsonPath -Parent
        $targetDir   = Join-Path $packagesDir "$owner\$dirName"

        if ([string]::IsNullOrWhiteSpace($targetDir)) {
            Write-Host "Не удалось сформировать путь targetDir" -ForegroundColor Red
            Write-Host "  packagesDir: '$packagesDir'" -ForegroundColor Red
            Write-Host "  owner: '$owner', dirName: '$dirName'" -ForegroundColor Red
            return $null
        }

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
                Write-Host "     Детали: $_" -ForegroundColor DarkGray
            }
        }

        $relativePath = "Packages/$owner/$dirName"
        return $relativePath.Replace('\', '/')
    }

    
    [void]UpdatePackagesJson([PSCustomObject]$remoteForge, [string]$newVersion) {
        $tagValue = "$($remoteForge._owner)/$($remoteForge._repo)"

        # Удаляет служебные поля, которые были добавлены при скачивании (DownloadRemoteForge)
        if ($remoteForge.PSObject.Properties['_owner']) { $remoteForge.PSObject.Properties.Remove('_owner') }
        if ($remoteForge.PSObject.Properties['_repo'])  { $remoteForge.PSObject.Properties.Remove('_repo') }

        # Внедряет обязательные метаданные для packages.json
        # tag
        if ($remoteForge.PSObject.Properties['tag']) {
            $remoteForge.tag = $tagValue
        } else {
            $remoteForge | Add-Member -NotePropertyName "tag" -NotePropertyValue $tagValue -Force
        }

        # version
        if ($remoteForge.PSObject.Properties['version']) {
            $remoteForge.version = $newVersion
        } else {
            $remoteForge | Add-Member -NotePropertyName "version" -NotePropertyValue $newVersion -Force
        }

        # type
        if ($remoteForge.PSObject.Properties['type']) {
            $remoteForge.type = "Library"
        } else {
            $remoteForge | Add-Member -NotePropertyName "type" -NotePropertyValue "Library" -Force
        }

        # Инициализация корневой структуры packages.json
        if (-not $this.PackagesData) {
            $this.PackagesData = [PSCustomObject]@{
                version  = "v1"
                packages = [array]@()
            }
        }
        if (-not ($this.PackagesData.PSObject.Properties.Name -contains 'packages')) {
            $this.PackagesData | Add-Member -NotePropertyName "packages" -NotePropertyValue ([array]@()) -Force
        }

        # Преобразует массив пакетов в ArrayList
        $list = [System.Collections.ArrayList]::new()
        $current = $this.PackagesData.packages
        if ($null -ne $current) {
            if ($current -is [array]) {
                [void]$list.AddRange([object[]]$current)
            } else {
                [void]$list.Add($current)
            }
        }

        # Поиск существующего пакета по tag (регистронезависимо)
        $foundIndex = -1
        for ($i = 0; $i -lt $list.Count; $i++) {
            $currentTag = $list[$i].tag
            if ($null -ne $currentTag -and $currentTag.ToString().Trim().ToLower() -eq $tagValue.ToLower()) {
                $foundIndex = $i
                break
            }
        }
        
        # Если пакет не найден, добавляет его как новый
        if ($foundIndex -ge 0) {
            $list[$foundIndex] = $remoteForge
        } else {
            [void]$list.Add($remoteForge)
        }
        
        $this.PackagesData.packages = [array]$list.ToArray()
    }
    
    
    
    
    
    
    
    
    [void]RemoveFromPackagesJson([string]$tag) {
        if (-not $this.PackagesData -or -not $this.PackagesData.packages) { return }
        
        $list = [System.Collections.ArrayList]::new()
        $current = $this.PackagesData.packages
        
        if ($current -is [array]) {
            [void]$list.AddRange([object[]]$current)
        } elseif ($null -ne $current) {
            [void]$list.Add($current)
        }
        
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