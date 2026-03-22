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
