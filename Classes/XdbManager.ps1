# =============================================
# Classes/XdbManager.ps1
# =============================================
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
        # Настраиваем XmlWriter для отступов ровно в 4 пробела
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = (" " * 4) # 4 пробела
        $settings.Encoding = New-Object System.Text.UTF8Encoding $false
        $settings.OmitXmlDeclaration = $false
        
        $writer = [System.Xml.XmlWriter]::Create($this.FilePath, $settings)
        $this.XmlDoc.Save($writer)
        $writer.Close()
    }

    [void]ApplyForgeChanges([PSCustomObject]$forgeData) {
        $this.Load()
        $ScriptFileRefs = @()

        # 1. Обработка useCommonScripts
        $useCommonScripts = $forgeData.require.useCommonScripts
        if ($null -ne $useCommonScripts) {
            if (-not $this.XmlDoc.UIAddon.userAddonInfo) {
                $node = $this.XmlDoc.CreateElement("userAddonInfo")
                $this.XmlDoc.UIAddon.AppendChild($node) | Out-Null
            }
            if ($useCommonScripts -eq $true) {
                $this.XmlDoc.UIAddon.userAddonInfo.useCommonScripts = "true"
            } elseif ($useCommonScripts -is [array]) {
                $ScriptFileRefs += $useCommonScripts
            }
        }

        # 2. Сборка скриптов из files (first -> others -> last)
        if ($forgeData.files.first) { $ScriptFileRefs += $forgeData.files.first }
        if ($forgeData.files.others) { $ScriptFileRefs += $forgeData.files.others }
        if ($forgeData.files.last) { $ScriptFileRefs += $forgeData.files.last }

        # 3. Перезапись ScriptFileRefs
        $scriptRefsNode = $this.XmlDoc.UIAddon.ScriptFileRefs
        if (-not $scriptRefsNode) {
            $scriptRefsNode = $this.XmlDoc.CreateElement("ScriptFileRefs")
            $this.XmlDoc.UIAddon.AppendChild($scriptRefsNode) | Out-Null
        } else {
            $scriptRefsNode.RemoveAll()
        }

        foreach ($script in $ScriptFileRefs) {
            $itemNode = $this.XmlDoc.CreateElement("Item")
            $itemNode.SetAttribute("href", $script)
            $scriptRefsNode.AppendChild($itemNode) | Out-Null
        }
    }
}