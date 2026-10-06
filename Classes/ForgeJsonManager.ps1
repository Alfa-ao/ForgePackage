# =============================================
# Classes/ForgeJsonManager.ps1
# =============================================
class ForgeJsonManager {
    [string]$FilePath
    [PSCustomObject]$Data

    static [string[]]$ArrayProps = @(
        'first', 'others', 'last', 'unpack',
        'packages', 'authors', 'keywords', 'useCommonScripts'
    )

    ForgeJsonManager([string]$path) {
        $this.FilePath = $path
        if (Test-Path $path) {
            $raw = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $this.Data = [ForgeJsonManager]::Normalize($raw)
        }
    }

    static [PSCustomObject]Normalize([PSCustomObject]$obj) {
        if ($null -eq $obj) { return $obj }
        foreach ($prop in @($obj.PSObject.Properties)) {
            $name = $prop.Name
            $val  = $prop.Value
            if ($val -is [PSCustomObject]) {
                $obj.$name = [ForgeJsonManager]::Normalize($val)
            }
            if ($name -in [ForgeJsonManager]::ArrayProps) {
                if ($null -ne $val -and $val -isnot [array] -and $val -isnot [bool] -and $val -isnot [ValueType]) {
                    $obj.$name = [array]$val
                }
            }
        }
        return $obj
    }

    static [array]EnsureArray($val) {
        if ($null -eq $val) { return [array]@() }
        if ($val -is [array]) { return $val }
        return [array]$val
    }

    [void]Save() {
        if ($null -eq $this.Data) {
            throw "Нет данных для сохранения."
        }
        $json = $this.FormatJsonInternal($this.Data, 0)
        [System.IO.File]::WriteAllText(
            $this.FilePath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    [void]UpdateFromRemote([PSCustomObject]$remoteForge, [string]$newVersion, [string]$tag, [string]$packageRelativePath) {
        if (-not $this.Data) {
            $this.Data = [PSCustomObject]@{}
        }
        if (-not $this.Data.require) {
            $this.Data | Add-Member -NotePropertyName "require" -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $this.Data.require | Add-Member -NotePropertyName $tag -NotePropertyValue $newVersion -Force
        
        if (-not $this.Data.files) {
            $this.Data | Add-Member -NotePropertyName "files" -NotePropertyValue ([PSCustomObject]@{}) -Force
        }

        $prefix = "$packageRelativePath/"

        foreach ($section in @('first', 'others', 'last')) {
            if ($remoteForge.files.$section) {
                $existing = [ForgeJsonManager]::EnsureArray($this.Data.files.$section)
                $incomingRaw = [ForgeJsonManager]::EnsureArray($remoteForge.files.$section)
                
                # Очищаем старые файлы этого пакета и собираем уникальные оставшиеся
                $cleanedExisting = [System.Collections.ArrayList]::new()
                $uniquePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                
                foreach ($f in $existing) {
                    if (-not [string]::IsNullOrWhiteSpace($f)) {
                        # Оставляем только те файлы, которые не относятся к текущему обновляемому пакету
                        if (-not ($f -like "$prefix*" -or $f -eq $packageRelativePath)) {
                            if (-not $uniquePaths.Contains($f)) {
                                [void]$cleanedExisting.Add($f)
                                [void]$uniquePaths.Add($f)
                            }
                        }
                    }
                }

                $newItems = [System.Collections.ArrayList]::new()
                foreach ($f in $incomingRaw) {
                    if (-not [string]::IsNullOrWhiteSpace($f)) {
                        $fullPath = "$packageRelativePath/$f"
                        # Добавляем только если файла еще нет в списке
                        if (-not $uniquePaths.Contains($fullPath)) {
                            [void]$newItems.Add($fullPath)
                            [void]$uniquePaths.Add($fullPath)
                        }
                    }
                }

                # Новые файлы пакета добавляются в начало, далее очищенные существующие
                $this.Data.files.$section = [array]($newItems.ToArray() + $cleanedExisting.ToArray())
            }
        }
    }

    [void]RemoveFromRemote([string]$tag, [string]$packageRelativePath) {
        if ($this.Data.require -and $this.Data.require.PSObject.Properties[$tag]) {
            $this.Data.require.PSObject.Properties.Remove($tag)
        }
        
        $prefix = "$packageRelativePath/"
        foreach ($section in @('first', 'others', 'last')) {
            if ($this.Data.files -and $this.Data.files.$section) {
                $current = [ForgeJsonManager]::EnsureArray($this.Data.files.$section)
                $filtered = [System.Collections.ArrayList]::new()
                foreach ($f in $current) {
                    if (-not ($f -like "$prefix*" -or $f -eq $packageRelativePath)) {
                        [void]$filtered.Add($f)
                    }
                }
                $this.Data.files.$section = [array]$filtered.ToArray()
            }
        }
    }

    [string]FormatJson($Object) {
        return $this.FormatJsonInternal($Object, 0)
    }

    [string]FormatJsonInternal($Object, [int]$IndentLevel) {
        $indent     = "    " * $IndentLevel
        $nextIndent = "    " * ($IndentLevel + 1)
        
        if ($null -eq $Object) { return "null" }
        if ($Object -is [bool]) { return $Object.ToString().ToLower() }
        if ($Object -is [string]) {
            $escaped = $Object.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
            return "`"$escaped`""
        }
        if ($Object -is [int] -or $Object -is [long] -or $Object -is [double] -or $Object -is [decimal]) {
            return $Object.ToString()
        }
        if ($Object -is [System.Collections.IDictionary] -or $Object -is [PSCustomObject]) {
            $items = [System.Collections.ArrayList]::new()
            $props = if ($Object -is [System.Collections.IDictionary]) {
                $Object.Keys
            } else {
                $Object.PSObject.Properties.Name
            }
            foreach ($key in $props) {
                $val = if ($Object -is [System.Collections.IDictionary]) {
                    $Object[$key]
                } else {
                    $Object.$key
                }
                if ($key -in [ForgeJsonManager]::ArrayProps -and
                    $null -ne $val -and
                    $val -isnot [System.Collections.IList]) {
                    $val = , $val
                }
                $formattedVal = $this.FormatJsonInternal($val, $IndentLevel + 1)
                [void]$items.Add("$nextIndent`"$key`": $formattedVal")
            }
            if ($items.Count -eq 0) { return "{}" }
            return "{`n" + ($items -join ",`n") + "`n$indent}"
        }
        if ($Object -is [System.Collections.IEnumerable]) {
            $items = [System.Collections.ArrayList]::new()
            foreach ($item in $Object) {
                $val = $this.FormatJsonInternal($item, $IndentLevel + 1)
                [void]$items.Add("$nextIndent$val")
            }
            if ($items.Count -eq 0) { return "[]" }
            return "[`n" + ($items -join ",`n") + "`n$indent]"
        }
        return "`"$($Object.ToString())`""
    }
}