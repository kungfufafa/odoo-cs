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
