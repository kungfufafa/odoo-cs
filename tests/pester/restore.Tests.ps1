$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\restore.ps1'
$platformLibPath = Join-Path (Split-Path -Parent $here) '..\lib\platform.ps1'

BeforeAll {
    . $platformLibPath
    . $libPath
}

Describe 'Restore Module' {
    Context 'Resolve-BackupDir' {
        BeforeEach {
            $tempDir = Join-Path $here 'tmp_restore'
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
            $script:RestoreWorkDir = Join-Path $tempDir '.restore'
        }

        AfterEach {
            $tempDir = Join-Path $here 'tmp_restore'
            if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
        }

        It 'returns input path if it is already a directory' {
            $dir = Join-Path $script:RestoreWorkDir 'existing_folder'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Resolve-BackupDir -InputPath $dir | Should -Be $dir
        }

        It 'creates sql_only for .sql file' {
            $file = Join-Path $script:RestoreWorkDir 'test.sql'
            New-Item -ItemType File -Force -Path $file | Out-Null
            $result = Resolve-BackupDir -InputPath $file
            $result | Should -Be (Join-Path $script:RestoreWorkDir 'sql_only')
            Test-Path (Join-Path $result 'dump.sql') | Should -Be $true
        }

        It 'creates custom_dump for .dump file' {
            $file = Join-Path $script:RestoreWorkDir 'test.dump'
            New-Item -ItemType File -Force -Path $file | Out-Null
            $result = Resolve-BackupDir -InputPath $file
            $result | Should -Be (Join-Path $script:RestoreWorkDir 'custom_dump')
            Test-Path (Join-Path $result 'test.dump') | Should -Be $true
        }

        It 'throws error on unsupported extension' {
            $file = Join-Path $script:RestoreWorkDir 'test.txt'
            New-Item -ItemType File -Force -Path $file | Out-Null
            { Resolve-BackupDir -InputPath $file } | Should -Throw
        }
    }
}
