# =============================================
# Classes/ForgeContext.ps1
# =============================================

class ForgeContext {
    [string]$GameInstallPath
    [string]$AddonsPath
    [System.IO.DirectoryInfo]$SelectedAddon
    [string]$ForgeJsonPath
    [string]$PackagesDir
    [string]$PackagesJsonPath
    [string]$XdbPath

    ForgeContext([string]$gamePath, [System.IO.DirectoryInfo]$addon) {
        $this.GameInstallPath = $gamePath
        $this.AddonsPath = Join-Path $gamePath "data\Mods\Addons"
        $this.SelectedAddon = $addon
        $this.ForgeJsonPath = Join-Path $addon.FullName "forge.json"
        $this.PackagesDir = Join-Path $addon.FullName "Packages"
        $this.PackagesJsonPath = Join-Path $this.PackagesDir "packages.json"
        $this.XdbPath = Join-Path $addon.FullName "AddonDesc.(UIAddon).xdb"
    }
}