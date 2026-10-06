# =============================================
# Classes/XdbManager.ps1
# =============================================

function Get-PackagePrefix {
    param([PSCustomObject]$pkg)
    if (-not $pkg -or -not $pkg.tag) { return "" }
    $parts = $pkg.tag -split '/'
    if ($parts.Count -lt 2) { return "" }
    $owner = $parts[0]
    $repo = $parts[1]
    $dirName = if (-not [string]::IsNullOrWhiteSpace($pkg.name)) { $pkg.name } else { $repo }
    return "Packages/$owner/$dirName"
}

function Format-PackagePath {
    param([string]$filePath, [string]$prefix)
    if ([string]::IsNullOrWhiteSpace($filePath)) { return $null }
    $normPath = $filePath.Replace('\', '/')
    if ($normPath -match "^/?Mods/SampleCommon") {
        if (-not $normPath.StartsWith("/")) { $normPath = "/$normPath" }
        return $normPath
    }
    $cleanPath = $normPath.TrimStart('/')
    return "$prefix/$cleanPath"
}

class XdbManager {
    [string]$FilePath
    [xml]$XmlDoc

    XdbManager([string]$path) {
        $this.FilePath = $path
    }

    [void]Load() {
        if (Test-Path $this.FilePath) {
            $this.XmlDoc = [xml](Get-Content $this.FilePath -Encoding UTF8)
        } else {
            throw "Файл XDB не найден: $($this.FilePath)"
        }
    }

    [void]Save() {
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = (" " * 4)
        $settings.Encoding = New-Object System.Text.UTF8Encoding $false
        $settings.OmitXmlDeclaration = $false
        $writer = [System.Xml.XmlWriter]::Create($this.FilePath, $settings)
        $this.XmlDoc.Save($writer)
        $writer.Close()
    }

    [void]ApplyForgeChanges([PSCustomObject]$forgeData, [PSCustomObject]$packagesData) {
        $this.Load()

        $addonUseCommon = $forgeData.require.useCommonScripts
        $effectiveUseCommon = $false
        if ($addonUseCommon -eq $true) {
            $effectiveUseCommon = $true
        } else {
            if ($packagesData -and $packagesData.packages) {
                $pkgs = $packagesData.packages
                if ($pkgs -isnot [array]) { $pkgs = [array]$pkgs }
                foreach ($pkg in $pkgs) {
                    if ($pkg.require -and $pkg.require.useCommonScripts -eq $true) {
                        $effectiveUseCommon = $true
                        break
                    }
                }
            }
        }

        if (-not $this.XmlDoc.UIAddon.userAddonInfo) {
            $node = $this.XmlDoc.CreateElement("userAddonInfo")
            $this.XmlDoc.UIAddon.AppendChild($node) | Out-Null
        }
        $userAddonInfoNode = $this.XmlDoc.UIAddon.userAddonInfo

        $useCommonNode = $userAddonInfoNode.SelectSingleNode("useCommonScripts")
        if (-not $useCommonNode) {
            $useCommonNode = $this.XmlDoc.CreateElement("useCommonScripts")
            $userAddonInfoNode.AppendChild($useCommonNode) | Out-Null
        }
        $useCommonNode.InnerText = $effectiveUseCommon.ToString().ToLower()

        $addonVersion = $forgeData.version
        if (-not [string]::IsNullOrWhiteSpace($addonVersion)) {
            $versionNode = $userAddonInfoNode.SelectSingleNode("version")
            if (-not $versionNode) {
                $versionNode = $this.XmlDoc.CreateElement("version")
                $userAddonInfoNode.AppendChild($versionNode) | Out-Null
            }
            $versionNode.InnerText = $addonVersion.ToString().Trim()
        }

        # Сбор файлов с сохранением исходного порядка
        $allFiles = [ordered]@{}

        $addFiles = {
            param($filesObj, $prefix)
            if (-not $filesObj) { return }
            
            # filesObj представляет собой словарь { "путь": приоритет }
            foreach ($prop in $filesObj.PSObject.Properties) {
                $file = $prop.Name
                $priority = $prop.Value
                
                $formatted = if ($prefix) { Format-PackagePath $file $prefix } else { $file }
                if ([string]::IsNullOrWhiteSpace($formatted)) { continue }
                
                # Применение жестких приоритетов для стандартных скриптов
                if ([ForgeContext]::CommonScriptsPriority.ContainsKey($formatted)) {
                    $priority = [ForgeContext]::CommonScriptsPriority[$formatted]
                }
                
                $allFiles[$formatted] = [int]$priority
            }
        }

        & $addFiles $forgeData.files $null

        if ($packagesData -and $packagesData.packages) {
            $pkgs = $packagesData.packages
            if ($pkgs -isnot [array]) { $pkgs = [array]$pkgs }
            foreach ($pkg in $pkgs) {
                if ($pkg.files) {
                    $prefix = Get-PackagePrefix $pkg
                    & $addFiles $pkg.files $prefix
                }
            }
        }

        # Удаление стандартных скриптов при активном useCommonScripts
        if ($effectiveUseCommon) {
            $keysToRemove = @($allFiles.Keys | Where-Object { $_ -match "^/?Mods/SampleCommon" })
            foreach ($key in $keysToRemove) {
                $allFiles.Remove($key)
            }
        }

        # Стабильная сортировка: по приоритету (убывание), затем по индексу (возрастание)
        $index = 0
        $indexedFiles = foreach ($item in $allFiles.GetEnumerator()) {
            [PSCustomObject]@{
                File     = $item.Key
                Priority = [int]$item.Value
                Index    = $index++
            }
        }
        
        $sortedFiles = $indexedFiles | Sort-Object -Property @{Expression={$_.Priority}; Descending=$true}, Index

        # Формирование XML узлов
        $scriptRefsNode = $this.XmlDoc.SelectSingleNode("/UIAddon/ScriptFileRefs")
        if (-not $scriptRefsNode) {
            $scriptRefsNode = $this.XmlDoc.CreateElement("ScriptFileRefs")
            $this.XmlDoc.UIAddon.AppendChild($scriptRefsNode) | Out-Null
        } else {
            $scriptRefsNode.RemoveAll()
        }

        foreach ($item in $sortedFiles) {
            $file = $item.File
            if (-not [string]::IsNullOrWhiteSpace($file)) {
                $itemNode = $this.XmlDoc.CreateElement("Item")
                $itemNode.SetAttribute("href", $file)
                $scriptRefsNode.AppendChild($itemNode) | Out-Null
            }
        }
    }
}