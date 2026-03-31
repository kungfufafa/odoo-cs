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
DO `$'$`
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$(Escape-SqlLiteral $DbUser)') THEN
    CREATE ROLE $userIdent LOGIN NOCREATEROLE NOBYPASSRLS $createdbFlag $superuserFlag PASSWORD '$passwordLit';
  ELSE
    ALTER ROLE $userIdent WITH LOGIN NOCREATEROLE NOBYPASSRLS $createdbFlag $superuserFlag PASSWORD '$passwordLit';
  END IF;
END
`$'$`;
"@
    Invoke-AdminSql -Sql $sql | Out-Null
}
