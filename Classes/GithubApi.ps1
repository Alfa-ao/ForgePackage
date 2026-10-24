# =============================================
# Classes/GithubApi.ps1
# =============================================
class GithubApi {
    [hashtable]$Headers
    [string]$ApiBase = "https://api.github.com"
    [string]$RawBase = "https://raw.githubusercontent.com"

    GithubApi() {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $this.Headers = @{
            "User-Agent" = "ForgePackage-PowerShell"
            "Accept"     = "application/vnd.github.v3+json"
        }
    }
    
    [string]GetTagSha([string]$owner, [string]$repo, [string]$tag) {
        $url = "$($this.ApiBase)/repos/$owner/$repo/git/refs/tags/$tag"
        try {
            $ref = Invoke-RestMethod -Uri $url -Headers $this.Headers -UseBasicParsing
            if ($ref -and $ref.object -and $ref.object.sha) {
                return $ref.object.sha
            }
        } catch {
            Write-Host "Не удалось получить SHA для тега '$tag' репозитория '$owner/$repo'." -ForegroundColor Red
        }
        return $null
    }

    [PSCustomObject]GetLatestRelease([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo/releases/latest"
        return Invoke-RestMethod -Uri $url -Headers $this.Headers -UseBasicParsing
    }

    [PSCustomObject]GetRepositoryInfo([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo"
        return Invoke-RestMethod -Uri $url -Headers $this.Headers -UseBasicParsing
    }

    [string]GetLatestTag([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo/tags"
        try {
            $tags = Invoke-RestMethod -Uri $url -Headers $this.Headers -UseBasicParsing
            if ($tags.Count -eq 0) { return $null }
            if ($tags -isnot [array]) { return $tags.name }
            return $tags[0].name
        } catch {
            if ($_.Exception.Message -match "404") {
                Write-Host "Репозиторий '$owner/$repo' не найден (404)." -ForegroundColor Red
            } else {
                Write-Host "Не удалось получить теги для '$owner/$repo'." -ForegroundColor Red
            }
            return $null
        }
    }

    [PSCustomObject]GetRawJson([string]$owner, [string]$repo, [string]$ref, [string]$filePath) {
        $url = "$($this.RawBase)/$owner/$repo/$ref/$filePath"
        try {
            return Invoke-RestMethod -Uri $url -Headers $this.Headers -UseBasicParsing
        } catch {
            Write-Host "Файл $filePath отсутствует в репозитории по тегу $ref." -ForegroundColor Red
            return $null
        }
    }

    [void]DownloadFile([string]$owner, [string]$repo, [string]$ref, [string]$filePath, [string]$destinationPath) {
        $url = "$($this.RawBase)/$owner/$repo/$ref/$filePath"
        
        $localDir = Split-Path $destinationPath -Parent
        if (-not (Test-Path $localDir)) {
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
        }

        Invoke-WebRequest -Uri $url -OutFile $destinationPath -Headers $this.Headers -UseBasicParsing -ErrorAction Stop
    }
}