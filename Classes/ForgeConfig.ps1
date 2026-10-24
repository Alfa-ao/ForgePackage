# =============================================
# Classes/ForgeConfig.ps1
# =============================================
class ForgeConfig {
    [string]$registryPath    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\gcgame_0.359"
    [string]$PackagesVersion = "v2" # packages.json
    [string]$AppVersion      = "1.0.2" # GitHub
    [string]$ScriptName      = "ForgePackage"
    [string]$RepoOwner       = "Alfa-ao"
    [string]$RepoName        = "ForgePackage"
    [string]$ScriptDir
    [string]$ScriptFileName
    [string]$ScriptPath
    [string]$ScriptExt
    [string]$BatFileName
    [string]$BatFilePath

    ForgeConfig([string]$scriptRoot, [string]$commandName) {
        $this.ScriptDir = $scriptRoot
        if (-not $this.ScriptDir) { $this.ScriptDir = "." }

        $this.ScriptFileName = $commandName
        if (-not $this.ScriptFileName) { $this.ScriptFileName = "$($this.ScriptName).ps1" }

        $this.ScriptPath = Join-Path -Path $this.ScriptDir -ChildPath $this.ScriptFileName
        $this.ScriptExt  = [System.IO.Path]::GetExtension($this.ScriptPath)
        if ([string]::IsNullOrEmpty($this.ScriptExt)) { $this.ScriptExt = ".ps1" }

        $this.BatFileName = "run.bat"
        $this.BatFilePath = Join-Path -Path $this.ScriptDir -ChildPath $this.BatFileName
    }
}