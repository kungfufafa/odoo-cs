function Escape-PsLiteral {
    param([string]$Value)
    return $Value -replace "'", "''"
}

function Escape-SqlLiteral {
    param([string]$Value)
    return $Value -replace "'", "''"
}

function Quote-SqlIdent {
    param([string]$Value)
    return '"' + ($Value -replace '"', '""') + '"'
}

function Ensure-Dirs {
    foreach ($dir in @($ArtifactsDir, $RestoreWorkDir, $LogsDir, $RunDir, $DataDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
}

function Acquire-Lock {
    if (Test-Path $LockDir) {
        $existingPidFile = Join-Path $LockDir 'pid'
        if (Test-Path $existingPidFile) {
            $existingPid = Get-Content $existingPidFile -ErrorAction SilentlyContinue
            if ($existingPid) {
                try {
                    Get-Process -Id $existingPid -ErrorAction Stop | Out-Null
                    throw "another bootstrap is already running with pid $existingPid"
                } catch [System.ArgumentException] {
                } catch {
                    if ($_.Exception.Message -like 'another bootstrap*') { throw }
                }
            }
        }
        Write-Log -Level WARN "removing stale lock directory"
        Remove-Item -Recurse -Force $LockDir -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
    Set-Content -Path (Join-Path $LockDir 'pid') -Value $PID
}

function Release-Lock {
    if (Test-Path $LockDir) {
        Remove-Item -Recurse -Force $LockDir -ErrorAction SilentlyContinue
    }
}

function Check-FreeSpace {
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).Substring(0, 1))
    if ($drive) {
        $freeGB = [math]::Floor($drive.Free / 1GB)
        Write-Log "free disk space: ${freeGB}G"
        if ($freeGB -lt $MinFreeGB) {
            throw "free disk space ${freeGB}G is below MIN_FREE_GB=$MinFreeGB G"
        }
    }
}

function Get-MemoryGB {
    try {
        $memoryBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        return [math]::Floor($memoryBytes / 1GB)
    } catch { return 0 }
}

function Get-CpuCount { return [Environment]::ProcessorCount }

function Show-MemoryHint {
    $memoryGb = Get-MemoryGB
    if ($memoryGb -gt 0) {
        Write-Log "detected RAM: ${memoryGb}G"
        if ($memoryGb -lt 4) {
            Write-Log -Level WARN 'less than 4G RAM detected; multi-worker Odoo may be unstable'
        }
    }
}

function Get-FirstFile {
    param([string]$Pattern)
    $file = Get-ChildItem -Path $Root -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Test-IsInternalWorkspacePath {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($internalDir in @(
        $RestoreWorkDir,
        $ArtifactsDir,
        (Join-Path $Root '.logs'),
        (Join-Path $Root '.run'),
        (Join-Path $Root '.rollback'),
        (Join-Path $Root '.local'),
        (Join-Path $Root '.venv'),
        (Join-Path $Root '.git')
    )) {
        if (-not $internalDir) { continue }
        $fullInternalDir = [IO.Path]::GetFullPath($internalDir)
        $prefix = $fullInternalDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($fullPath -eq $fullInternalDir -or $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-WorkspaceFilesRecursive {
    param(
        [string]$Path,
        [string]$Filter = '*',
        [int]$MaxDepth = [int]::MaxValue,
        [int]$Depth = 0
    )

    if ($Depth -gt $MaxDepth -or (Test-IsInternalWorkspacePath $Path)) {
        return
    }

    Get-ChildItem -Path $Path -File -Filter $Filter -ErrorAction SilentlyContinue

    if ($Depth -ge $MaxDepth) {
        return
    }

    foreach ($directory in Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue | Sort-Object FullName) {
        if (-not (Test-IsInternalWorkspacePath $directory.FullName)) {
            Get-WorkspaceFilesRecursive -Path $directory.FullName -Filter $Filter -MaxDepth $MaxDepth -Depth ($Depth + 1)
        }
    }
}
