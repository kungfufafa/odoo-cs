function Get-BackupInput {
    if ($BackupInput) { return $BackupInput }

    $sqlDir = Get-WorkspaceFilesRecursive -Path $Root -Filter 'dump.sql' -MaxDepth 3 |
        Sort-Object FullName |
        Select-Object -First 1
    if ($sqlDir) { return $sqlDir.Directory.FullName }

    foreach ($zip in Get-WorkspaceFilesRecursive -Path $Root -Filter '*.zip' -MaxDepth 2 |
        Sort-Object FullName) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
            $entry = $archive.Entries | Where-Object { $_.FullName -like '*dump.sql' -or $_.FullName -like '*.dump' -or $_.FullName -like '*.backup' } | Select-Object -First 1
            $archive.Dispose()
            if ($entry) { return $zip.FullName }
        } catch { }
    }

    $candidate = Get-WorkspaceFilesRecursive -Path $Root -Filter '*' -MaxDepth 2 |
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

    $backupInput = Get-BackupInput
    if (-not $backupInput) {
        if ($RestoreMode -eq 'auto') { Write-Log 'no backup detected; skipping restore'; return }
        throw 'unable to auto-detect backup input'
    }

    $script:BackupInput = $backupInput
    $backupDir = Resolve-BackupDir -InputPath $backupInput
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
