# =============================================
# Functions/BackupHelpers.ps1
# =============================================



# =============================================
# Функция резервного копирования и очистки Packages
# =============================================
function Backup-AndCleanPackages {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackagesPath
    )

    if (-not (Test-Path -Path $PackagesPath)) {
        Write-Host "[Info] Папка Packages не существует, пропуск резервного копирования." -ForegroundColor DarkGray
        return
    }

    # Определяем папку для бэкапов (на уровень выше Packages)
    $addonRoot = Split-Path -Path $PackagesPath -Parent
    $backupRoot = Join-Path -Path $addonRoot -ChildPath "Backups"
    
    if (-not (Test-Path -Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path -Path $backupRoot -ChildPath "Packages_$timestamp.zip"

    try {
        Write-Host "  -> Создание резервной копии папки Packages..." -ForegroundColor DarkGray
        
        # Архивируем содержимое папки (используем \*, чтобы не архивировать саму папку, а только её содержимое)
        Compress-Archive -Path "$PackagesPath\*" -DestinationPath $backupFile -Force
        
        Write-Host "  -> Удаление оригинальной папки Packages..." -ForegroundColor DarkGray
        Remove-Item -Path $PackagesPath -Recurse -Force
        
        Write-Host "  -> Резервная копия успешно создана: $backupFile" -ForegroundColor DarkGray
    } catch {
        Write-Host "[Error] Не удалось создать резервную копию или удалить папку: $_" -ForegroundColor DarkGray
    }
}

function Backup-XdbFile {
    param([string]$AddonRoot)
    $xdbPath = Join-Path $AddonRoot "AddonDesc.(UIAddon).xdb"
    if (Test-Path $xdbPath) {
        $backupRoot = Join-Path -Path $addonRoot -ChildPath "Backups"
        
        if (-not (Test-Path -Path $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
        
        $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $dumpName = "AddonDesc.(UIAddon).xdb_$dateStr.dump"
        $dumpPath = Join-Path $backupRoot $dumpName
        try {
            Copy-Item -Path $xdbPath -Destination $dumpPath -Force -ErrorAction Stop
            Write-Host "  -> $dumpName" -ForegroundColor DarkGray
        } catch {
            Write-Host "  -> Ошибка создания дампа XDB: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  -> Файл AddonDesc.(UIAddon).xdb не найден, дамп не создан." -ForegroundColor DarkGray
    }
}