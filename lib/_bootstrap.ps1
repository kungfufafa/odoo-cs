# ============================================================================
# Bootstrap Orchestration
# ============================================================================

function Prepare-Environment {
    Ensure-Dirs
    Acquire-Lock
    Test-AllInputs
    Ensure-Secrets
    Show-MemoryHint
    Check-FreeSpace

    if (-not (Test-DbConnection)) {
        throw 'cannot connect to PostgreSQL — check DB_HOST, DB_PORT, DB_ADMIN_USER'
    }

    $script:CustomAddonsDir = Resolve-CustomAddonsDir
    Install-OdooExe
    Show-ArtifactSummary
    Ensure-DbRole
    Write-OdooConfig
    Write-RuntimeEnv
    Restore-Database
    Clear-Rollback
}

function Invoke-BootstrapDetached {
    if (-not (Test-Path $BootstrapLog)) { New-Item -ItemType File -Path $BootstrapLog -Force | Out-Null }
    Start-Transcript -Path $BootstrapLog -Append | Out-Null
    try {
        Prepare-Environment
        if ($StartAfterRestore -eq 1) {
            Start-OdooDetached
            Wait-OdooHealthy
        } else {
            Write-Log "bootstrap complete; start manually with: $Root\setup_odoo.ps1 run"
        }
    } catch {
        Invoke-Rollback
        throw
    } finally {
        if (Test-Path $BootstrapPidFile) { Remove-Item -Force $BootstrapPidFile -ErrorAction SilentlyContinue }
        Release-Lock
        Stop-Transcript | Out-Null
    }
}

function Invoke-Foreground {
    if (-not (Test-Path $BootstrapLog)) { New-Item -ItemType File -Path $BootstrapLog -Force | Out-Null }
    Start-Transcript -Path $BootstrapLog -Append | Out-Null
    try {
        Prepare-Environment
        if ($StartAfterRestore -eq 1) { Start-OdooForeground }
        else { Write-Log "bootstrap complete; run later with: $Root\setup_odoo.ps1 run" }
    } catch {
        Invoke-Rollback
        throw
    } finally {
        if (Test-Path $BootstrapPidFile) { Remove-Item -Force $BootstrapPidFile -ErrorAction SilentlyContinue }
        Release-Lock
        Stop-Transcript | Out-Null
    }
}

function Invoke-Run {
    Load-RuntimeEnv
    if (-not $OdooBin) { throw 'Odoo runtime file is missing OdooBin' }
    Start-OdooForeground
}
