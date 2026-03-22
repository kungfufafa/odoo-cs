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

# --- Module Loader -----------------------------------------------------------
$LibDir = Join-Path $Root 'lib'
if ((Test-Path $LibDir) -and (Test-Path (Join-Path $LibDir '_bootstrap.ps1'))) {
    # Load configuration
    $OriginalDbPassword = if (Test-Path Env:DB_PASSWORD) { $env:DB_PASSWORD } else { $null }
    $OriginalOdooAdminPasswd = if (Test-Path Env:ODOO_ADMIN_PASSWD) { $env:ODOO_ADMIN_PASSWD } else { $null }

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

    # Source all library modules
    . (Join-Path $LibDir 'logging.ps1')
    . (Join-Path $LibDir 'validation.ps1')
    . (Join-Path $LibDir 'rollback.ps1')
    . (Join-Path $LibDir 'platform.ps1')
    . (Join-Path $LibDir 'secrets.ps1')
    . (Join-Path $LibDir 'database.ps1')
    . (Join-Path $LibDir 'install.ps1')
    . (Join-Path $LibDir 'restore.ps1')
    . (Join-Path $LibDir 'config.ps1')
    . (Join-Path $LibDir 'service.ps1')
    . (Join-Path $LibDir '_bootstrap.ps1')
} else {
    Write-Error "[setup-odoo] ERROR: lib/ directory or _bootstrap.ps1 not found"
    Write-Error "[setup-odoo] Please ensure the lib/ directory is alongside setup_odoo.ps1"
    exit 1
}

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
