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

function Sort-ArrayWithPriority {
    param([array]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    $priority = [System.Collections.ArrayList]::new()
    $regular = [System.Collections.ArrayList]::new()
    foreach ($item in $Items) {
        if ($item -match "^/?Mods/SampleCommon") {
            [void]$priority.Add($item)
        } else {
            [void]$regular.Add($item)
        }
    }
    $result = [System.Collections.ArrayList]::new()
    [void]$result.AddRange($priority)
    [void]$result.AddRange($regular)
    return @($result.ToArray())
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
        $ScriptFileRefs = [System.Collections.ArrayList]::new()
        $useCommonScripts = $forgeData.require.useCommonScripts

        if ($null -ne $useCommonScripts) {
            if (-not $this.XmlDoc.UIAddon.userAddonInfo) {
                $node = $this.XmlDoc.CreateElement("userAddonInfo")
                $this.XmlDoc.UIAddon.AppendChild($node) | Out-Null
            }
            if ($useCommonScripts -eq $true) {
                $this.XmlDoc.UIAddon.userAddonInfo.useCommonScripts = "true"
            } elseif ($useCommonScripts -is [array]) {
                foreach ($item in $useCommonScripts) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) {
                        [void]$ScriptFileRefs.Add($item)
                    }
                }
            }
        }

        $mainFirst = [System.Collections.ArrayList]::new()
        $mainOthers = [System.Collections.ArrayList]::new()
        $mainLast = [System.Collections.ArrayList]::new()

        foreach ($f in [ForgeJsonManager]::EnsureArray($forgeData.files.first)) {
            if (-not [string]::IsNullOrWhiteSpace($f)) { [void]$mainFirst.Add($f) }
        }
        foreach ($f in [ForgeJsonManager]::EnsureArray($forgeData.files.others)) {
            if (-not [string]::IsNullOrWhiteSpace($f)) { [void]$mainOthers.Add($f) }
        }
        foreach ($f in [ForgeJsonManager]::EnsureArray($forgeData.files.last)) {
            if (-not [string]::IsNullOrWhiteSpace($f)) { [void]$mainLast.Add($f) }
        }

        $pkgFirst = [System.Collections.ArrayList]::new()
        $pkgOthers = [System.Collections.ArrayList]::new()
        $pkgLast = [System.Collections.ArrayList]::new()

        if ($packagesData -and $packagesData.packages) {
            $pkgs = $packagesData.packages
            if ($pkgs -isnot [array]) { $pkgs = [array]$pkgs }
            foreach ($pkg in $pkgs) {
                if ($pkg.files) {
                    $prefix = Get-PackagePrefix $pkg
                    foreach ($f in [ForgeJsonManager]::EnsureArray($pkg.files.first)) {
                        $formatted = Format-PackagePath $f $prefix
                        if ($formatted) { [void]$pkgFirst.Add($formatted) }
                    }
                    foreach ($f in [ForgeJsonManager]::EnsureArray($pkg.files.others)) {
                        $formatted = Format-PackagePath $f $prefix
                        if ($formatted) { [void]$pkgOthers.Add($formatted) }
                    }
                    foreach ($f in [ForgeJsonManager]::EnsureArray($pkg.files.last)) {
                        $formatted = Format-PackagePath $f $prefix
                        if ($formatted) { [void]$pkgLast.Add($formatted) }
                    }
                }
            }
        }

        $mergeAndSort = {
            param($mainList, $pkgList)
            $sortedMain = @(Sort-ArrayWithPriority $mainList)
            $sortedPkg = @(Sort-ArrayWithPriority $pkgList)
            $merged = [System.Collections.ArrayList]::new()
            if ($sortedPkg.Count -gt 0) { [void]$merged.AddRange($sortedPkg) }
            if ($sortedMain.Count -gt 0) { [void]$merged.AddRange($sortedMain) }
            return @($merged.ToArray())
        }

        $finalFirst = @(& $mergeAndSort $mainFirst $pkgFirst)
        $finalOthers = @(& $mergeAndSort $mainOthers $pkgOthers)
        $finalLast = @(& $mergeAndSort $mainLast $pkgLast)

        if ($finalFirst.Count -gt 0) { [void]$ScriptFileRefs.AddRange($finalFirst) }
        if ($finalOthers.Count -gt 0) { [void]$ScriptFileRefs.AddRange($finalOthers) }
        if ($finalLast.Count -gt 0) { [void]$ScriptFileRefs.AddRange($finalLast) }

        # SelectSingleNode гарантирует возврат XmlNode или $null, а не строку
        $scriptRefsNode = $this.XmlDoc.SelectSingleNode("/UIAddon/ScriptFileRefs")
        if (-not $scriptRefsNode) {
            $scriptRefsNode = $this.XmlDoc.CreateElement("ScriptFileRefs")
            $this.XmlDoc.UIAddon.AppendChild($scriptRefsNode) | Out-Null
        } else {
            $scriptRefsNode.RemoveAll()
        }

        foreach ($script in $ScriptFileRefs) {
            if (-not [string]::IsNullOrWhiteSpace($script)) {
                $itemNode = $this.XmlDoc.CreateElement("Item")
                $itemNode.SetAttribute("href", $script)
                $scriptRefsNode.AppendChild($itemNode) | Out-Null
            }
        }
    }
}