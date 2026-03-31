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
