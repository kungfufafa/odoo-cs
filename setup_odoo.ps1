$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================================
# setup_odoo.ps1 — Production-ready Odoo 16.0e Setup (Windows/PowerShell)
# ============================================================================
# One-command Odoo deployment on Windows: provisions PostgreSQL, restores
# database backups, and manages the Odoo service lifecycle.
#
# Usage:
#   .\setup_odoo.ps1 start | bootstrap | foreground | run | status | logs | stop
#   .\setup_odoo.ps1 --version
#   .\setup_odoo.ps1 help
# ============================================================================

# --- Version -----------------------------------------------------------------
$ScriptVersion = if (Test-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VERSION')) {
    (Get-Content (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VERSION') -Raw).Trim()
} else { 'dev' }

# --- CLI parsing -------------------------------------------------------------
$Root = if ($env:ROOT) { $env:ROOT } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Command = if ($args.Count -gt 0) { $args[0] } else { 'start' }

$OriginalDbPassword = if (Test-Path Env:DB_PASSWORD) { $env:DB_PASSWORD } else { $null }
$OriginalOdooAdminPasswd = if (Test-Path Env:ODOO_ADMIN_PASSWD) { $env:ODOO_ADMIN_PASSWD } else { $null }

# --- Default configuration ---------------------------------------------------
$DbName = if ($env:DB_NAME) { $env:DB_NAME } else { 'mkli_local' }
$DbUser = if ($env:DB_USER) { $env:DB_USER } else { 'odoo' }
$DbPassword = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { '' }
$DbHost = if ($env:DB_HOST) { $env:DB_HOST } else { '127.0.0.1' }
$DbPort = if ($env:DB_PORT) { $env:DB_PORT } else { '5432' }
$DbAdminUser = if ($env:DB_ADMIN_USER) { $env:DB_ADMIN_USER } else { 'postgres' }
$DbAdminPassword = if ($env:DB_ADMIN_PASSWORD) { $env:DB_ADMIN_PASSWORD } else { '' }
$DbRoleCanCreatedb = if ($env:DB_ROLE_CAN_CREATEDB) { [int]$env:DB_ROLE_CAN_CREATEDB } else { 1 }
$DbRoleSuperuser = if ($env:DB_ROLE_SUPERUSER) { [int]$env:DB_ROLE_SUPERUSER } else { 0 }
$OdooAdminPasswd = if ($env:ODOO_ADMIN_PASSWD) { $env:ODOO_ADMIN_PASSWD } else { '' }
$OdooHttpPort = if ($env:ODOO_HTTP_PORT) { $env:ODOO_HTTP_PORT } else { '8069' }
$OdooGeventPort = if ($env:ODOO_GEVENT_PORT) { $env:ODOO_GEVENT_PORT } else { '8072' }
$OdooHttpInterface = if ($env:ODOO_HTTP_INTERFACE) { $env:ODOO_HTTP_INTERFACE } else { '127.0.0.1' }
$OdooProxyMode = if ($env:ODOO_PROXY_MODE) { [int]$env:ODOO_PROXY_MODE } else { 1 }
$OdooListDb = if ($env:ODOO_LIST_DB) { [int]$env:ODOO_LIST_DB } else { 0 }
$OdooWorkers = if ($env:ODOO_WORKERS) { $env:ODOO_WORKERS } else { 'auto' }
$OdooMaxCronThreads = if ($env:ODOO_MAX_CRON_THREADS) { $env:ODOO_MAX_CRON_THREADS } else { '2' }
$OdooDbMaxConn = if ($env:ODOO_DB_MAXCONN) { $env:ODOO_DB_MAXCONN } else { '64' }
$OdooLimitMemorySoft = if ($env:ODOO_LIMIT_MEMORY_SOFT) { $env:ODOO_LIMIT_MEMORY_SOFT } else { 'auto' }
$OdooLimitMemoryHard = if ($env:ODOO_LIMIT_MEMORY_HARD) { $env:ODOO_LIMIT_MEMORY_HARD } else { 'auto' }
$OdooLimitTimeCpu = if ($env:ODOO_LIMIT_TIME_CPU) { $env:ODOO_LIMIT_TIME_CPU } else { '600' }
$OdooLimitTimeReal = if ($env:ODOO_LIMIT_TIME_REAL) { $env:ODOO_LIMIT_TIME_REAL } else { '1200' }
$OdooWithoutDemo = if ($env:ODOO_WITHOUT_DEMO) { $env:ODOO_WITHOUT_DEMO } else { 'all' }
$OdooDbFilter = if ($env:ODOO_DBFILTER) { $env:ODOO_DBFILTER } else { '^' + $DbName + '$' }
$DataDir = if ($env:DATA_DIR) { $env:DATA_DIR } else { Join-Path $Root '.local\share\Odoo' }
$ArtifactsDir = if ($env:ARTIFACTS_DIR) { $env:ARTIFACTS_DIR } else { Join-Path $Root '.artifacts' }
$RestoreWorkDir = if ($env:RESTORE_WORKDIR) { $env:RESTORE_WORKDIR } else { Join-Path $Root '.restore' }
$LogsDir = Join-Path $Root '.logs'
$RunDir = Join-Path $Root '.run'
$LockDir = Join-Path $RunDir 'bootstrap.lock'
$BootstrapLog = Join-Path $LogsDir 'bootstrap.log'
$BootstrapPidFile = Join-Path $RunDir 'bootstrap.pid'
$OdooPidFile = Join-Path $RunDir 'odoo.pid'
$StdoutLog = Join-Path $LogsDir 'odoo.stdout.log'
$RuntimeEnvFile = Join-Path $Root '.odoo_runtime.ps1'
$SecretsFile = Join-Path $Root '.odoo.secrets.ps1'
$ConfigFile = Join-Path $Root 'odoo.conf'
$LogFile = if ($env:LOG_FILE) { $env:LOG_FILE } else { Join-Path $Root 'odoo.log' }
$StartAfterRestore = if ($env:START_AFTER_RESTORE) { [int]$env:START_AFTER_RESTORE } else { 1 }
$RestoreMode = if ($env:RESTORE_MODE) { $env:RESTORE_MODE } else { 'required' }
$RestoreStrategy = if ($env:RESTORE_STRATEGY) { $env:RESTORE_STRATEGY } else { 'refresh' }
$FilestoreStrategy = if ($env:FILESTORE_STRATEGY) { $env:FILESTORE_STRATEGY } else { 'mirror' }
$OdooExePackage = if ($env:ODOO_EXE_PACKAGE) { $env:ODOO_EXE_PACKAGE } else { $null }
$CustomAddonsDir = if ($env:CUSTOM_ADDONS_DIR) { $env:CUSTOM_ADDONS_DIR } else { $null }
$CustomAddonsZipPatterns = if ($env:CUSTOM_ADDONS_ZIP_PATTERNS) { $env:CUSTOM_ADDONS_ZIP_PATTERNS } else { '*addons*.zip|majukendaraanlistrikindonesia-main.zip' }
$BackupInput = if ($env:BACKUP_INPUT) { $env:BACKUP_INPUT } else { $null }
$OdooBin = if ($env:ODOO_BIN) { $env:ODOO_BIN } else { $null }
$OdooServerDir = if ($env:ODOO_SERVER_DIR) { $env:ODOO_SERVER_DIR } else { $null }
$MinFreeGB = if ($env:MIN_FREE_GB) { [int]$env:MIN_FREE_GB } else { 20 }
$HealthcheckTimeout = if ($env:HEALTHCHECK_TIMEOUT) { [int]$env:HEALTHCHECK_TIMEOUT } else { 120 }
$StopTimeout = if ($env:STOP_TIMEOUT) { [int]$env:STOP_TIMEOUT } else { 30 }
$DbConnectRetries = if ($env:DB_CONNECT_RETRIES) { [int]$env:DB_CONNECT_RETRIES } else { 3 }

# Rollback stack for automatic cleanup on failure
$script:RollbackStack = @()

# ============================================================================
# Structured Logging
# ============================================================================

function Write-Log {
    <#
    .SYNOPSIS
    Structured log output with level and timestamp.
    #>
    param(
        [string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','FATAL')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
    Write-Host "[$timestamp] [$Level] [setup-odoo.ps1] $Message"
}

# ============================================================================
# Input Validation
# ============================================================================

function Test-ValidPort {
    param([string]$Label, [string]$Value)
    $port = 0
    if (-not [int]::TryParse($Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Write-Log -Level ERROR "$Label must be a valid port (1-65535), got: '$Value'"
        return $false
    }
    return $true
}

function Test-ValidBoolean {
    param([string]$Label, [int]$Value)
    if ($Value -notin @(0, 1)) {
        Write-Log -Level ERROR "$Label must be 0 or 1, got: '$Value'"
        return $false
    }
    return $true
}

function Test-ValidEnum {
    param([string]$Label, [string]$Value, [string[]]$Allowed)
    if ($Value -notin $Allowed) {
        Write-Log -Level ERROR "$Label must be one of [$($Allowed -join ', ')], got: '$Value'"
        return $false
    }
    return $true
}

function Test-AllInputs {
    $errors = 0
    if (-not (Test-ValidPort 'ODOO_HTTP_PORT' $OdooHttpPort)) { $errors++ }
    if (-not (Test-ValidPort 'ODOO_GEVENT_PORT' $OdooGeventPort)) { $errors++ }
    if (-not (Test-ValidPort 'DB_PORT' $DbPort)) { $errors++ }
    if (-not (Test-ValidBoolean 'DB_ROLE_CAN_CREATEDB' $DbRoleCanCreatedb)) { $errors++ }
    if (-not (Test-ValidBoolean 'DB_ROLE_SUPERUSER' $DbRoleSuperuser)) { $errors++ }
    if (-not (Test-ValidBoolean 'ODOO_PROXY_MODE' $OdooProxyMode)) { $errors++ }
    if (-not (Test-ValidBoolean 'ODOO_LIST_DB' $OdooListDb)) { $errors++ }
    if (-not (Test-ValidEnum 'RESTORE_MODE' $RestoreMode @('required','auto','skip'))) { $errors++ }
    if (-not (Test-ValidEnum 'RESTORE_STRATEGY' $RestoreStrategy @('refresh','reuse','fail'))) { $errors++ }
    if (-not (Test-ValidEnum 'FILESTORE_STRATEGY' $FilestoreStrategy @('mirror','merge','skip'))) { $errors++ }
    if ($errors -gt 0) {
        throw "input validation failed with $errors error(s)"
    }
}

# ============================================================================
# Rollback Mechanism
# ============================================================================

function Register-Rollback {
    param([string]$Description, [scriptblock]$UndoAction)
    $script:RollbackStack += [PSCustomObject]@{ Description = $Description; Action = $UndoAction }
    Write-Log -Level DEBUG "rollback registered: $Description"
}

function Invoke-Rollback {
    if ($script:RollbackStack.Count -eq 0) { return }
    Write-Log -Level WARN "executing rollback: $($script:RollbackStack.Count) action(s)"
    for ($i = $script:RollbackStack.Count - 1; $i -ge 0; $i--) {
        $entry = $script:RollbackStack[$i]
        try {
            Write-Log -Level WARN "  rollback: $($entry.Description)"
            & $entry.Action
        } catch {
            Write-Log -Level ERROR "  rollback failed: $($entry.Description) - $_"
        }
    }
    $script:RollbackStack = @()
}

function Clear-Rollback { $script:RollbackStack = @() }

# ============================================================================
# Usage / Help
# ============================================================================

function Show-Usage {
    @'
Usage:
  .\setup_odoo.ps1 start | bootstrap | foreground | run | status | logs | stop
  .\setup_odoo.ps1 --version
  .\setup_odoo.ps1 help

Commands:
  start       Run bootstrap in background, then start Odoo detached.
  bootstrap   Run bootstrap once in the current shell and start Odoo detached.
  foreground  Run bootstrap once in the current shell and then start Odoo attached.
  run         Start Odoo immediately using the last generated runtime files.
  status      Show bootstrap/Odoo PID and port status.
  logs        Follow bootstrap log.
  stop        Stop Odoo/bootstrap PIDs created by this script.
  --version   Show script version.

Environment overrides:
  DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, DB_PORT
  DB_ADMIN_USER, DB_ADMIN_PASSWORD
  DB_ROLE_CAN_CREATEDB=0|1, DB_ROLE_SUPERUSER=0|1
  DB_CONNECT_RETRIES=3
  BACKUP_INPUT, RESTORE_MODE, RESTORE_STRATEGY, FILESTORE_STRATEGY
  CUSTOM_ADDONS_DIR, CUSTOM_ADDONS_ZIP_PATTERNS
  ODOO_EXE_PACKAGE, ODOO_HTTP_PORT, ODOO_GEVENT_PORT
  ODOO_ADMIN_PASSWD, ODOO_PROXY_MODE, ODOO_LIST_DB, ODOO_WORKERS
  START_AFTER_RESTORE, MIN_FREE_GB, HEALTHCHECK_TIMEOUT, STOP_TIMEOUT
'@ | Write-Host
}

# ============================================================================
# Utility Functions
# ============================================================================

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

# ============================================================================
# Secrets Management
# ============================================================================

function Import-Secrets {
    if (Test-Path $SecretsFile) {
        . $SecretsFile
    }
    if ($null -ne $OriginalDbPassword) { $script:DbPassword = $OriginalDbPassword }
    if ($null -ne $OriginalOdooAdminPasswd) { $script:OdooAdminPasswd = $OriginalOdooAdminPasswd }
}

function New-RandomSecret {
    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $chars = foreach ($byte in $bytes) { $alphabet[$byte % $alphabet.Length] }
    -join $chars
}

function Write-SecretsFile {
    $content = @"
# Auto-generated secrets — do not commit to version control
`$script:DbPassword = '$(Escape-PsLiteral $DbPassword)'
`$script:OdooAdminPasswd = '$(Escape-PsLiteral $OdooAdminPasswd)'
"@
    Set-Content -Path $SecretsFile -Value $content -Encoding UTF8
}

function Ensure-Secrets {
    Import-Secrets
    if (-not $DbPassword) {
        $script:DbPassword = New-RandomSecret
        Write-Log "generated DB_PASSWORD and stored it in $SecretsFile"
    }
    if (-not $OdooAdminPasswd) {
        $script:OdooAdminPasswd = New-RandomSecret
        Write-Log "generated ODOO_ADMIN_PASSWD and stored it in $SecretsFile"
    }
    Write-SecretsFile
}

# ============================================================================
# Lock Management
# ============================================================================

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

# ============================================================================
# Platform & Resource Detection
# ============================================================================

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

# ============================================================================
# PostgreSQL Management
# ============================================================================

function Ensure-Postgres {
    $psql = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($psql) { return $psql.Source }

    $candidates = @(
        'C:\Program Files\PostgreSQL\17\bin\psql.exe',
        'C:\Program Files\PostgreSQL\16\bin\psql.exe',
        'C:\Program Files\PostgreSQL\15\bin\psql.exe',
        'C:\Program Files\PostgreSQL\14\bin\psql.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Log 'installing PostgreSQL with winget'
        Start-Process -FilePath $winget.Source -ArgumentList 'install', '--id', 'PostgreSQL.PostgreSQL', '--accept-source-agreements', '--accept-package-agreements', '--silent' -Wait -Verb RunAs
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) { return $candidate }
        }
    }

    throw 'PostgreSQL not found; install PostgreSQL and ensure psql.exe exists'
}

function Get-PostgresBinDir { Split-Path -Parent (Ensure-Postgres) }

function Invoke-AdminSql {
    param([string]$Sql)
    $psql = Ensure-Postgres
    $env:PGPASSWORD = $DbAdminPassword
    & $psql -h $DbHost -p $DbPort -U $DbAdminUser -d postgres -v ON_ERROR_STOP=1 -Atqc $Sql
}

function Test-DbConnection {
    for ($i = 1; $i -le $DbConnectRetries; $i++) {
        try {
            Invoke-AdminSql -Sql 'SELECT 1;' | Out-Null
            Write-Log -Level DEBUG "database connection successful (attempt $i)"
            return $true
        } catch {
            Write-Log -Level WARN "database connection attempt $i/$DbConnectRetries failed"
            if ($i -lt $DbConnectRetries) { Start-Sleep -Seconds 5 }
        }
    }
    return $false
}

function Test-DatabaseExists {
    $sql = "SELECT 1 FROM pg_database WHERE datname = '$(Escape-SqlLiteral $DbName)';"
    $result = Invoke-AdminSql -Sql $sql
    return $result -eq '1'
}

function Stop-DatabaseConnections {
    $sql = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$(Escape-SqlLiteral $DbName)' AND pid <> pg_backend_pid();"
    try { Invoke-AdminSql -Sql $sql | Out-Null } catch { }
}

function New-DatabaseIfMissing {
    if (Test-DatabaseExists) { return }
    Write-Log "creating database: $DbName"
    $dbIdent = Quote-SqlIdent $DbName
    $userIdent = Quote-SqlIdent $DbUser
    Invoke-AdminSql -Sql "CREATE DATABASE $dbIdent OWNER $userIdent TEMPLATE template0 ENCODING 'UTF8';" | Out-Null
}

function Remove-DatabaseIfExists {
    if (-not (Test-DatabaseExists)) { return }
    Write-Log "dropping database: $DbName"
    Stop-DatabaseConnections
    $dbIdent = Quote-SqlIdent $DbName
    Invoke-AdminSql -Sql "DROP DATABASE IF EXISTS $dbIdent;" | Out-Null
}

function Ensure-DbRole {
    $userIdent = Quote-SqlIdent $DbUser
    $passwordLit = Escape-SqlLiteral $DbPassword
    $createdbFlag = if ($DbRoleCanCreatedb -eq 1) { 'CREATEDB' } else { 'NOCREATEDB' }
    $superuserFlag = if ($DbRoleSuperuser -eq 1) { 'SUPERUSER' } else { 'NOSUPERUSER' }

    Write-Log 'ensuring PostgreSQL role exists'
    $sql = @"
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$(Escape-SqlLiteral $DbUser)') THEN
    CREATE ROLE $userIdent LOGIN NOCREATEROLE NOBYPASSRLS $createdbFlag $superuserFlag PASSWORD '$passwordLit';
  ELSE
    ALTER ROLE $userIdent WITH LOGIN NOCREATEROLE NOBYPASSRLS $createdbFlag $superuserFlag PASSWORD '$passwordLit';
  END IF;
END
\$\$;
"@
    Invoke-AdminSql -Sql $sql | Out-Null
}

# ============================================================================
# Odoo Installation
# ============================================================================

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

# ============================================================================
# Configuration Generation
# ============================================================================

function Get-ResolvedWorkers {
    if ($OdooWorkers -ne 'auto') { return $OdooWorkers }
    $memoryGb = Get-MemoryGB
    if ($memoryGb -lt 4) { return '0' }
    $cpuCount = Get-CpuCount
    $cpuBased = ($cpuCount * 2) + 1
    $memoryBased = $memoryGb - 1
    $workers = [Math]::Min($cpuBased, $memoryBased)
    if ($workers -lt 2) { $workers = 2 }
    return [string]$workers
}

function Get-ResolvedMemorySoft {
    if ($OdooLimitMemorySoft -ne 'auto') { return $OdooLimitMemorySoft }
    $memoryGb = Get-MemoryGB
    if ($memoryGb -le 0) { return '2147483648' }
    $soft = [int64]($memoryGb * 1GB * 0.7)
    if ($soft -lt 2147483648) { $soft = 2147483648 }
    return [string]$soft
}

function Get-ResolvedMemoryHard {
    if ($OdooLimitMemoryHard -ne 'auto') { return $OdooLimitMemoryHard }
    $soft = [int64](Get-ResolvedMemorySoft)
    return [string]([int64]($soft * 1.2))
}

function Convert-ToOdooBool {
    param([int]$Value)
    if ($Value -eq 1) { return 'True' }
    return 'False'
}

function Write-OdooConfig {
    $addonsPath = $CustomAddonsDir
    if ($OdooServerDir) {
        $addonsPath = (Join-Path $OdooServerDir 'addons') + ',' + $CustomAddonsDir
    }
    $workers = Get-ResolvedWorkers
    $memorySoft = Get-ResolvedMemorySoft
    $memoryHard = Get-ResolvedMemoryHard

    $content = @"
[options]
admin_passwd = $OdooAdminPasswd
db_host = $DbHost
db_port = $DbPort
db_user = $DbUser
db_password = $DbPassword
dbfilter = $OdooDbFilter
addons_path = $addonsPath
data_dir = $DataDir
http_interface = $OdooHttpInterface
http_port = $OdooHttpPort
gevent_port = $OdooGeventPort
logfile = $LogFile
proxy_mode = $(Convert-ToOdooBool $OdooProxyMode)
list_db = $(Convert-ToOdooBool $OdooListDb)
workers = $workers
max_cron_threads = $OdooMaxCronThreads
db_maxconn = $OdooDbMaxConn
limit_memory_soft = $memorySoft
limit_memory_hard = $memoryHard
limit_time_cpu = $OdooLimitTimeCpu
limit_time_real = $OdooLimitTimeReal
without_demo = $OdooWithoutDemo
"@
    Set-Content -Path $ConfigFile -Value $content -Encoding UTF8
    Write-Log "wrote Odoo config to $ConfigFile (workers=$workers)"
}

function Write-RuntimeEnv {
    $resolvedOdooBin = if ($OdooBin) { $OdooBin } else { '' }
    $content = @"
`$script:Root = '$(Escape-PsLiteral $Root)'
`$script:ConfigFile = '$(Escape-PsLiteral $ConfigFile)'
`$script:OdooBin = '$(Escape-PsLiteral $resolvedOdooBin)'
`$script:DbName = '$(Escape-PsLiteral $DbName)'
`$script:OdooHttpPort = '$(Escape-PsLiteral $OdooHttpPort)'
`$script:StdoutLog = '$(Escape-PsLiteral $StdoutLog)'
`$script:OdooPidFile = '$(Escape-PsLiteral $OdooPidFile)'
"@
    Set-Content -Path $RuntimeEnvFile -Value $content -Encoding UTF8
}

function Show-ArtifactSummary {
    if ($OdooExePackage) { Write-Log "odoo exe: $OdooExePackage" }
    if ($OdooBin) { Write-Log "odoo bin: $OdooBin" }
    if ($CustomAddonsDir) { Write-Log "custom addons dir: $CustomAddonsDir" }
    if ($BackupInput) { Write-Log "backup input: $BackupInput" }
    Write-Log "db restore mode: $RestoreMode / strategy: $RestoreStrategy"
}

# ============================================================================
# Backup / Restore
# ============================================================================

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

function Get-BackupInput {
    if ($BackupInput) { return $BackupInput }

    $sqlDir = Get-WorkspaceFilesRecursive -Path $Root -Filter 'dump.sql' -MaxDepth 3 |
        Sort-Object FullName |
        Select-Object -First 1
    if ($sqlDir) { return $sqlDir.Directory.FullName }

    foreach ($zip in Get-ChildItem -Path $Root -Filter '*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsInternalWorkspacePath $_.FullName) } |
        Sort-Object FullName) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
            $entry = $archive.Entries | Where-Object { $_.FullName -like '*dump.sql' -or $_.FullName -like '*.dump' -or $_.FullName -like '*.backup' } | Select-Object -First 1
            $archive.Dispose()
            if ($entry) { return $zip.FullName }
        } catch { }
    }

    $candidate = Get-ChildItem -Path $Root -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsInternalWorkspacePath $_.FullName) } |
        Where-Object { $_.Extension -in @('.sql', '.dump', '.backup') } |
        Sort-Object FullName |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Resolve-BackupDir {
    param([string]$InputPath)

    if (Test-Path $InputPath -PathType Container) { return $InputPath }

    if ($InputPath.ToLower().EndsWith('.zip')) {
        $extractDir = Join-Path $RestoreWorkDir ([IO.Path]::GetFileNameWithoutExtension($InputPath))
        $marker = Join-Path $extractDir '.extracted.ok'
        if (-not (Test-Path $marker)) {
            if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
            New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
            Write-Log "extracting backup zip to $extractDir"
            Expand-Archive -Path $InputPath -DestinationPath $extractDir -Force
            New-Item -ItemType File -Force -Path $marker | Out-Null
        }
        return $extractDir
    }

    if ($InputPath.ToLower().EndsWith('.sql')) {
        $extractDir = Join-Path $RestoreWorkDir 'sql_only'
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Copy-Item -Force $InputPath (Join-Path $extractDir 'dump.sql')
        return $extractDir
    }

    if ($InputPath.ToLower().EndsWith('.dump') -or $InputPath.ToLower().EndsWith('.backup')) {
        $extractDir = Join-Path $RestoreWorkDir 'custom_dump'
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Copy-Item -Force $InputPath (Join-Path $extractDir ([IO.Path]::GetFileName($InputPath)))
        return $extractDir
    }

    throw "unsupported backup input: $InputPath"
}

function Get-RestorePayload {
    param([string]$BackupDir)

    $dump = Get-ChildItem -Path $BackupDir -Recurse -Filter 'dump.sql' -File -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1
    if ($dump) { return [PSCustomObject]@{ Format = 'plain'; Path = $dump.FullName } }

    $custom = Get-ChildItem -Path $BackupDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.dump', '.backup') } |
        Sort-Object FullName |
        Select-Object -First 1
    if ($custom) { return [PSCustomObject]@{ Format = 'custom'; Path = $custom.FullName } }
    return $null
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Target, [string[]]$Arguments)
    $allArgs = @($Source, $Target) + $Arguments + @('/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    & robocopy @allArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
}

function Sync-Filestore {
    param([string]$Source, [string]$Target)
    switch ($FilestoreStrategy) {
        'skip' { Write-Log 'skipping filestore sync because FILESTORE_STRATEGY=skip' }
        'merge' {
            New-Item -ItemType Directory -Force -Path $Target | Out-Null
            Invoke-Robocopy -Source $Source -Target $Target -Arguments @('/E')
        }
        'mirror' {
            New-Item -ItemType Directory -Force -Path $Target | Out-Null
            Invoke-Robocopy -Source $Source -Target $Target -Arguments @('/MIR')
        }
        default { throw "unsupported FILESTORE_STRATEGY: $FilestoreStrategy" }
    }
}

function Restore-Database {
    if ($RestoreMode -eq 'skip') { Write-Log 'skipping restore because RESTORE_MODE=skip'; return }

    $input = Get-BackupInput
    if (-not $input) {
        if ($RestoreMode -eq 'auto') { Write-Log 'no backup detected; skipping restore'; return }
        throw 'unable to auto-detect backup input'
    }

    $script:BackupInput = $input
    $backupDir = Resolve-BackupDir -InputPath $input
    $payload = Get-RestorePayload -BackupDir $backupDir
    if (-not $payload) { throw "no supported dump payload found under $backupDir" }

    Register-Rollback "restore_database" { Write-Log -Level WARN "manual cleanup may be needed for database $DbName" }

    switch ($RestoreStrategy) {
        'refresh' { Remove-DatabaseIfExists; New-DatabaseIfMissing }
        'reuse' {
            if (Test-DatabaseExists) { Write-Log 'database exists, RESTORE_STRATEGY=reuse; skipping'; return }
            New-DatabaseIfMissing
        }
        'fail' {
            if (Test-DatabaseExists) { throw "database $DbName already exists and RESTORE_STRATEGY=fail" }
            New-DatabaseIfMissing
        }
    }

    $postgresBin = Get-PostgresBinDir
    $env:PGPASSWORD = $DbPassword

    if ($payload.Format -eq 'plain') {
        Write-Log "restoring plain SQL dump: $($payload.Path)"
        & (Join-Path $postgresBin 'psql.exe') -h $DbHost -p $DbPort -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -f $payload.Path
    } else {
        Write-Log "restoring PostgreSQL custom dump: $($payload.Path)"
        & (Join-Path $postgresBin 'pg_restore.exe') -v --no-owner --role=$DbUser -h $DbHost -p $DbPort -U $DbUser -d $DbName $payload.Path
    }

    $filestoreDir = Join-Path $backupDir 'filestore'
    if (Test-Path $filestoreDir) {
        $hasContent = Get-ChildItem -Path $filestoreDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hasContent) {
            $target = Join-Path (Join-Path $DataDir 'filestore') $DbName
            Write-Log "syncing filestore into $target"
            Sync-Filestore -Source $filestoreDir -Target $target
        } else {
            Write-Log 'backup has no filestore content; restore completed without attachments'
        }
    } else {
        Write-Log 'backup has no filestore content; restore completed without attachments'
    }
}

# ============================================================================
# Service Lifecycle
# ============================================================================

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
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, 'bootstrap' -PassThru -WindowStyle Hidden
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

# ============================================================================
# Command Dispatcher
# ============================================================================

switch ($Command) {
    'start'     { Start-Background }
    'bootstrap' { Invoke-BootstrapDetached }
    'foreground'{ Invoke-Foreground }
    'run'       { Invoke-Run }
    'status'    { Show-Status }
    'logs'      { Show-Logs }
    'stop'      { Stop-Background }
    '--version' { Write-Host "setup_odoo.ps1 v$ScriptVersion" }
    '-V'        { Write-Host "setup_odoo.ps1 v$ScriptVersion" }
    'help'      { Show-Usage }
    '--help'    { Show-Usage }
    '-h'        { Show-Usage }
    default     { Show-Usage; exit 1 }
}
