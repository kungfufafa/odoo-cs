function Get-OdooExePackage {
    if ($OdooExePackage) { return $OdooExePackage }
    $script:OdooExePackage = Get-FirstFile 'odoo*.exe'
    if (-not $script:OdooExePackage) { throw "odoo .exe installer not found in $Root" }
    return $script:OdooExePackage
}

function Get-CustomAddonsZip {
    $patterns = $CustomAddonsZipPatterns -split '\|'
    foreach ($pattern in $patterns) {
        $zip = Get-ChildItem -Path $Root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } |
            Sort-Object FullName |
            Select-Object -First 1
        if ($zip) { return $zip.FullName }
    }
    return $null
}

function Resolve-CustomAddonsDir {
    if ($CustomAddonsDir) {
        if (-not (Test-Path $CustomAddonsDir)) { throw "CUSTOM_ADDONS_DIR does not exist: $CustomAddonsDir" }
        return $CustomAddonsDir
    }

    $existing = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('.local', '.artifacts', '.restore', '.logs', '.run', '.rollback') } |
        ForEach-Object {
            $count = (Get-ChildItem -Path $_.FullName -Recurse -Filter '__manifest__.py' -ErrorAction SilentlyContinue | Measure-Object).Count
            [PSCustomObject]@{ Path = $_.FullName; Count = $count }
        } |
        Sort-Object Count -Descending |
        Select-Object -First 1

    if ($existing -and $existing.Count -gt 0) { return $existing.Path }

    $zip = Get-CustomAddonsZip
    if (-not $zip) { throw 'custom addons zip not found' }

    $extractDir = Join-Path $ArtifactsDir ([IO.Path]::GetFileNameWithoutExtension($zip))
    $marker = Join-Path $extractDir '.extracted.ok'
    if (-not (Test-Path $marker)) {
        if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Write-Log "extracting custom addons zip to $extractDir"
        Expand-Archive -Path $zip -DestinationPath $extractDir -Force
        New-Item -ItemType File -Force -Path $marker | Out-Null
    }

    $best = Get-ChildItem -Path $extractDir -Directory -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $count = (Get-ChildItem -Path $_.FullName -Recurse -Filter '__manifest__.py' -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($count -gt 0) { [PSCustomObject]@{ Path = $_.FullName; Count = $count } }
        } |
        Sort-Object Count -Descending |
        Select-Object -First 1

    if (-not $best) { throw "unable to resolve extracted custom addons directory from $zip" }
    return $best.Path
}

function Get-InstalledOdooBin {
    $candidates = @(
        'C:\Program Files\Odoo 16.0e\server\odoo-bin.exe',
        'C:\Program Files (x86)\Odoo 16.0e\server\odoo-bin.exe',
        'C:\Odoo 16.0e\server\odoo-bin.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Install-OdooExe {
    if ($OdooBin -and (Test-Path $OdooBin)) { return }

    $installed = Get-InstalledOdooBin
    if ($installed) {
        $script:OdooBin = $installed
        $script:OdooServerDir = Split-Path -Parent $installed
        Write-Log "reusing installed Odoo executable: $installed"
        return
    }

    $exe = Get-OdooExePackage
    Write-Log "installing Odoo .exe silently: $exe"
    Start-Process -FilePath $exe -ArgumentList '/S' -Verb RunAs -Wait

    $installed = Get-InstalledOdooBin
    if (-not $installed) { throw 'installed Odoo executable not found after .exe install' }

    $script:OdooBin = $installed
    $script:OdooServerDir = Split-Path -Parent $installed
}

function Show-ArtifactSummary {
    if ($OdooExePackage) { Write-Log "odoo exe: $OdooExePackage" }
    if ($OdooBin) { Write-Log "odoo bin: $OdooBin" }
    if ($CustomAddonsDir) { Write-Log "custom addons dir: $CustomAddonsDir" }
    if ($BackupInput) { Write-Log "backup input: $BackupInput" }
    Write-Log "db restore mode: $RestoreMode / strategy: $RestoreStrategy"
}
