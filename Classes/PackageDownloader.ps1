# =============================================
# Classes/PackageDownloader.ps1
# =============================================
class PackageDownloader {
    [GithubApi]$Api
    [string]$PackagesJsonPath
    [PSCustomObject]$PackagesData
    [string]$ResolvedOwner
    [string]$ResolvedRepo
    [hashtable]$ForgeCache
    [ForgeJsonManager]$MainForgeManager

    PackageDownloader([string]$packagesJsonPath, [ForgeJsonManager]$mainForgeManager) {
        $this.PackagesJsonPath = $packagesJsonPath
        $this.MainForgeManager = $mainForgeManager
        $this.Api = [GithubApi]::new()
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
            $repoInfo = $this.Api.GetRepositoryInfo($owner, $repo)
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
        return $this.Api.GetLatestTag($owner, $repo)
    }

    [PSCustomObject]DownloadRemoteForge([string]$packageName, [string]$tag) {
        $cacheKey = "$packageName@$tag".ToLower()
        if ($this.ForgeCache.ContainsKey($cacheKey)) {
            return $this.ForgeCache[$cacheKey]
        }
        $parts = $packageName -split '/'
        $owner = $parts[0]
        $repo  = $parts[1]
        
        $content = $this.Api.GetRawJson($owner, $repo, $tag, "forge.json")
        if ($content) {
            $content | Add-Member -NotePropertyName "_owner" -NotePropertyValue $owner -Force
            $content | Add-Member -NotePropertyName "_repo"  -NotePropertyValue $repo  -Force
            $this.ForgeCache[$cacheKey] = $content
        }
        return $content
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
            $localPath = Join-Path $targetDir $file
            $localDir  = Split-Path $localPath -Parent
            
            if (-not (Test-Path $localDir)) {
                New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            }
            
            try {
                $this.Api.DownloadFile($owner, $repo, $branchOrTag, $file, $localPath)
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
                if ($reqTag -in @('api', 'useCommonScripts')) { continue }
                if ($reqTag -notmatch "^[^/]+/[^/]+$") { continue }
                
                Write-Host "  -> Found nested dependency: $reqTag [$reqVersion]" -ForegroundColor DarkYellow
                
                $existingNestedPkg = $this.FindPackage($reqTag)
                $reqParts = $reqTag -split '/'
                $reqSha = $this.Api.GetTagSha($reqParts[0], $reqParts[1], $reqVersion)

                if ($existingNestedPkg -and 
                    $existingNestedPkg.version.ToString().Trim() -eq $reqVersion.ToString().Trim() -and 
                    $existingNestedPkg.sha -eq $reqSha) {
                    Write-Host "     -> Dependency already installed (SHA match)." -ForegroundColor DarkGray
                    continue
                }

                $nestedForge = $this.DownloadRemoteForge($reqTag, $reqVersion)
                if (-not $nestedForge) {
                    Write-Host "     -> Failed to fetch nested dependency forge.json." -ForegroundColor Red
                    continue
                }

                $this.DownloadFiles($reqTag, $nestedForge, $reqVersion)
                $this.UpdatePackagesJson($nestedForge, $reqVersion, $reqSha)
                
                if ($this.MainForgeManager) {
                    $this.MainForgeManager.UpdateRequire($reqTag, $reqVersion)
                }
            }
        }
        return "Packages/$owner/$dirName".Replace('\', '/')
    }

    [void]UpdatePackagesJson([PSCustomObject]$remoteForge, [string]$newVersion, [string]$sha) {
        $tagValue = "$($remoteForge._owner)/$($remoteForge._repo)"
        if ($remoteForge.PSObject.Properties['_owner']) { $remoteForge.PSObject.Properties.Remove('_owner') }
        if ($remoteForge.PSObject.Properties['_repo'])  { $remoteForge.PSObject.Properties.Remove('_repo') }
        
        if ($remoteForge.PSObject.Properties['tag']) { $remoteForge.tag = $tagValue }
        else { $remoteForge | Add-Member -NotePropertyName "tag" -NotePropertyValue $tagValue -Force }
        
        if ($remoteForge.PSObject.Properties['version']) { $remoteForge.version = $newVersion }
        else { $remoteForge | Add-Member -NotePropertyName "version" -NotePropertyValue $newVersion -Force }

        # Обязательное добавление SHA
        if ($remoteForge.PSObject.Properties['sha']) { $remoteForge.sha = $sha }
        else { $remoteForge | Add-Member -NotePropertyName "sha" -NotePropertyValue $sha -Force }
        
        if ($remoteForge.PSObject.Properties['type']) { $remoteForge.type = "Library" }
        else { $remoteForge | Add-Member -NotePropertyName "type" -NotePropertyValue "Library" -Force }

        if (-not $this.PackagesData) {
            $this.PackagesData = [PSCustomObject]@{ version = "v2"; packages = [array]@() }
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