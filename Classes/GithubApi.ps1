# =============================================
# Classes/GithubApi.ps1
# =============================================
class GithubApi {
    [hashtable]$Headers
    [string]$ApiBase = "https://api.github.com"
    [string]$RawBase = "https://raw.githubusercontent.com"

    GithubApi() {
        $this.Headers = @{ "User-Agent" = "PowerShell-ForgeScript" }
    }

    # Получение информации о последнем релизе
    [PSCustomObject]GetLatestRelease([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo/releases/latest"
        return Invoke-RestMethod -Uri $url -Headers $this.Headers
    }

    # Получение истинного регистра владельца и репозитория
    [PSCustomObject]GetRepositoryInfo([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo"
        return Invoke-RestMethod -Uri $url -Headers $this.Headers
    }

    # Получение имени последнего тега
    [string]GetLatestTag([string]$owner, [string]$repo) {
        $url = "$($this.ApiBase)/repos/$owner/$repo/tags"
        try {
            $tags = Invoke-RestMethod -Uri $url -Headers $this.Headers
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

    # Чтение JSON файла из raw-контента
    [PSCustomObject]GetRawJson([string]$owner, [string]$repo, [string]$ref, [string]$filePath) {
        $url = "$($this.RawBase)/$owner/$repo/$ref/$filePath"
        try {
            return Invoke-RestMethod -Uri $url -Headers $this.Headers
        } catch {
            Write-Host "Файл $filePath отсутствует в репозитории по тегу $ref." -ForegroundColor Red
            return $null
        }
    }

    # Скачивание файла из raw-контента
    [void]DownloadFile([string]$owner, [string]$repo, [string]$ref, [string]$filePath, [string]$destinationPath) {
        $url = "$($this.RawBase)/$owner/$repo/$ref/$filePath"
        Invoke-WebRequest -Uri $url -OutFile $destinationPath -Headers $this.Headers -ErrorAction Stop
    }

    # Скачивание файла по прямой ссылке (для релизов)
    [void]DownloadUrl([string]$url, [string]$destinationPath) {
        (New-Object System.Net.WebClient).DownloadFile($url, $destinationPath)
    }
}