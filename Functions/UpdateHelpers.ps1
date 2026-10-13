# =============================================
# Functions/UpdateHelpers.ps1
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

        if ([version]$latestVersion -gt [version]$Config.AppVersion) {
            Write-Host "Доступно обновление: $latestTag. Загрузка..." -ForegroundColor Yellow

            # Поиск zip архива в ассетах релиза
            $zipAsset = $response.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1

            if (-not $zipAsset) {
                Write-Host "Архив с обновлением не найден в релизе." -ForegroundColor Red
                return
            }

            $tempZipPath = Join-Path -Path $env:TEMP -ChildPath "ForgePackage_$latestTag.zip"
            $tempExtractPath = Join-Path -Path $env:TEMP -ChildPath "ForgePackage_$latestTag"

            # Очистка временных путей перед загрузкой
            if (Test-Path $tempZipPath) { Remove-Item $tempZipPath -Force }
            if (Test-Path $tempExtractPath) { Remove-Item $tempExtractPath -Recurse -Force }

            # Скачивание архива
            $Api.DownloadUrl($zipAsset.browser_download_url, $tempZipPath)

            # Распаковка архива
            Expand-Archive -Path $tempZipPath -DestinationPath $tempExtractPath -Force

            # Определение корневой директории внутри архива
            $sourceItems = Get-ChildItem -Path $tempExtractPath

            # Если внутри архива одна корневая папка, используется её содержимое
            if ($sourceItems.Count -eq 1 -and $sourceItems[0].PSIsContainer) {
                $sourceItems = Get-ChildItem -Path $sourceItems[0].FullName
            }

            # Копирование файлов в директорию скрипта
            foreach ($item in $sourceItems) {
                $destPath = Join-Path -Path $Config.ScriptDir -ChildPath $item.Name

                if ($item.PSIsContainer) {
                    Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                } else {
                    Copy-Item -Path $item.FullName -Destination $destPath -Force
                }
            }

            # Удаление временных файлов
            Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue

            Write-Host "Обновление установлено. Перезапуск..." -ForegroundColor Green

            # Перезапуск скрипта через bat-файл
            Start-Process -FilePath $Config.BatFilePath
            
            Stop-Process -Id $PID -Force
        } else {
            Write-Host "Version latest." -ForegroundColor DarkGreen
        }
    } catch {
        Write-Host "Не удалось проверить или установить обновления." -ForegroundColor DarkGray
    }
}