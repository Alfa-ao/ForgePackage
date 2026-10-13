# =============================================
# Functions/Update.ps1
# =============================================
function Invoke-ScriptUpdate {
    param(
        [ForgeConfig]$Config,
        [GithubApi]$Api
    )

    Write-Host "Проверка обновлений..." -ForegroundColor DarkGray
    try {
        $response = $Api.GetLatestRelease($Config.RepoOwner, $Config.RepoName)
        $latestTag = $response.tag_name
        $latestVersion = $latestTag.TrimStart('v')
        $releaseUrl = $response.html_url

        if ([version]$latestVersion -gt [version]$Config.AppVersion) {
            Write-Host "Доступна новая версия: $latestTag" -ForegroundColor Yellow
            Write-Host "Ссылка на релиз: $releaseUrl" -ForegroundColor Cyan
        } else {
            Write-Host "Установлена актуальная версия." -ForegroundColor DarkGreen
        }
    } catch {
        Write-Host "Ошибка проверки обновлений: $($_.Exception.Message)" -ForegroundColor Red
    }
}