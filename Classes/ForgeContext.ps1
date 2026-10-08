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

    static [hashtable]$CommonScriptsPriority = @{
        "/Mods/SampleCommon/CoreScripts/ClassesImplementation.lua" = 100
        "/Mods/SampleCommon/CoreScripts/AddonBaseUserMods.lua" = 99.99
        "/Mods/SampleCommon/CoreScripts/AddonBase.lua" = 99.98
        "/Mods/SampleCommon/CoreScripts/WidgetCoreUserMods.lua" = 99.97
        "/Mods/SampleCommon/CoreScripts/AdvancedHandlersUserMods.lua" = 99.96
        "/Mods/SampleCommon/CoreScripts/WidgetBaseClasses.lua" = 99.95
        "/Mods/SampleCommon/SampleAddonBase.lua" = 99.94
        "/Mods/SampleCommon/Scripts/EscapeSequencePlugInUserMods.lua" = 99.93
        "/Mods/SampleCommon/Scripts/WidgetDynamicList.lua" = 99.92
        "/Mods/SampleCommon/Scripts/WidgetFactory.lua" = 99.91
    }

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