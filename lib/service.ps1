function Load-RuntimeEnv {
    if (Test-Path $RuntimeEnvFile) { . $RuntimeEnvFile }
}

function Start-OdooForeground {
    if (-not (Test-Path $OdooBin)) { throw "Odoo binary not found: $OdooBin" }
    & $OdooBin -c $ConfigFile -d $DbName --http-port $OdooHttpPort
}

function Get-PidFromFile {
    param([string]$Path)
    if (Test-Path $Path) { return Get-Content $Path -ErrorAction SilentlyContinue }
    return $null
}

function Test-PidRunning {
    param([string]$PidValue)
    if (-not $PidValue) { return $false }
    try { Get-Process -Id $PidValue -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

function Start-OdooDetached {
    $existingPid = Get-PidFromFile -Path $OdooPidFile
    if (Test-PidRunning -PidValue $existingPid) {
        Write-Log "odoo already running with pid $existingPid"
        return
    }

    if (-not (Test-Path $OdooBin)) { throw "Odoo binary not found: $OdooBin" }
    if (Test-Path $StdoutLog) { Clear-Content -Path $StdoutLog }

    $proc = Start-Process -FilePath $OdooBin -ArgumentList '-c', $ConfigFile, '-d', $DbName, '--http-port', $OdooHttpPort -RedirectStandardOutput $StdoutLog -RedirectStandardError $StdoutLog -PassThru -WindowStyle Hidden
    Set-Content -Path $OdooPidFile -Value $proc.Id
    Write-Log "started Odoo pid=$($proc.Id)"
}

function Get-HealthcheckHost {
    $host = if ($OdooHttpInterface) { $OdooHttpInterface.Trim() } else { '127.0.0.1' }
    if ($host.StartsWith('[') -and $host.EndsWith(']')) {
        $host = $host.Substring(1, $host.Length - 2)
    }

    switch ($host) {
        '' { return '127.0.0.1' }
        '0.0.0.0' { return '127.0.0.1' }
        '::' { return '::1' }
        default { return $host }
    }
}

function Get-HealthcheckUrl {
    $host = Get-HealthcheckHost
    if ($host.Contains(':')) {
        $host = "[$host]"
    }
    return "http://${host}:$OdooHttpPort/web/login"
}

function Wait-OdooHealthy {
    $deadline = (Get-Date).AddSeconds($HealthcheckTimeout)
    $url = Get-HealthcheckUrl
    Write-Log "waiting for healthcheck at $url (timeout: ${HealthcheckTimeout}s)"
    do {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Write-Log "healthcheck passed: $url"
                return
            }
        } catch { }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "healthcheck failed after ${HealthcheckTimeout}s: $url"
}

function Start-Background {
    Ensure-Dirs
    $existingPid = Get-PidFromFile -Path $BootstrapPidFile
    if (Test-PidRunning -PidValue $existingPid) {
        Write-Log "bootstrap already running with pid $existingPid"
        return
    }
    # Note: caller script must be the main setup script
    $mainScript = $MyInvocation.PSCommandPath
    if (-not $mainScript) {
        $mainScript = Join-Path $Root 'setup_odoo.ps1'
    }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mainScript, 'bootstrap' -PassThru -WindowStyle Hidden
    Set-Content -Path $BootstrapPidFile -Value $proc.Id
    Write-Log "bootstrap started pid=$($proc.Id)"
}

function Show-Status {
    $bootstrapPid = Get-PidFromFile -Path $BootstrapPidFile
    $odooPid = Get-PidFromFile -Path $OdooPidFile

    if (Test-PidRunning -PidValue $bootstrapPid) { Write-Log "bootstrap running with pid $bootstrapPid" }
    else { Write-Log 'bootstrap not running' }

    if (Test-PidRunning -PidValue $odooPid) { Write-Log "odoo running with pid $odooPid" }
    else { Write-Log 'odoo not running' }

    try {
        $listener = Get-NetTCPConnection -LocalPort $OdooHttpPort -State Listen -ErrorAction Stop
        if ($listener) { Write-Log "odoo is listening on port $OdooHttpPort" }
    } catch { Write-Log "odoo is not listening on port $OdooHttpPort" }
}

function Stop-ByPidFile {
    param([string]$Path, [string]$Label)
    $pidValue = Get-PidFromFile -Path $Path
    if (Test-PidRunning -PidValue $pidValue) {
        try {
            Write-Log "stopping $Label (pid $pidValue)..."
            Stop-Process -Id $pidValue -Force
            Write-Log "stopped $Label pid $pidValue"
        } catch { }
    }
    if (Test-Path $Path) { Remove-Item -Force $Path -ErrorAction SilentlyContinue }
}

function Stop-Background {
    Stop-ByPidFile -Path $OdooPidFile -Label 'odoo'
    Stop-ByPidFile -Path $BootstrapPidFile -Label 'bootstrap'
}

function Show-Logs {
    Ensure-Dirs
    if (-not (Test-Path $BootstrapLog)) {
        New-Item -ItemType File -Force -Path $BootstrapLog | Out-Null
    }
    Get-Content -Path $BootstrapLog -Wait
}
