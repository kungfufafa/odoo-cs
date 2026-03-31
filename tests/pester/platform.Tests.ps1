BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'platform.ps1')
}

Describe 'Platform Module' {
    It 'Escape-PsLiteral escapes single quotes' {
        Escape-PsLiteral "test'string" | Should -Be "test''string"
        Escape-PsLiteral "'test'" | Should -Be "''test''"
    }

    It 'Escape-SqlLiteral escapes single quotes' {
        Escape-SqlLiteral "test'string" | Should -Be "test''string"
    }

    It 'Quote-SqlIdent wraps in double quotes and escapes' {
        Quote-SqlIdent 'test' | Should -Be '"test"'
        Quote-SqlIdent 'test"string' | Should -Be '"test""string"'
    }

    Context 'Get-MemoryGB' {
        It 'returns a non-negative integer' {
            $mem = Get-MemoryGB
            $mem | Should -Not -BeNullOrEmpty
            [int]$mem | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Get-CpuCount' {
        It 'returns a positive integer' {
            $cpu = Get-CpuCount
            $cpu | Should -Not -BeNullOrEmpty
            [int]$cpu | Should -BeGreaterThan 0
        }
    }

    Context 'Test-IsInternalWorkspacePath' {
        BeforeAll {
            $script:Root = 'C:\Odoo'
            $script:RestoreWorkDir = 'C:\Odoo\.restore'
            $script:ArtifactsDir = 'C:\Odoo\.artifacts'
        }
        It 'returns true for internal paths' {
            Test-IsInternalWorkspacePath 'C:\Odoo\.restore\something' | Should -Be $true
            Test-IsInternalWorkspacePath 'C:\Odoo\.logs' | Should -Be $true
        }
        It 'returns false for external paths' {
            Test-IsInternalWorkspacePath 'C:\Odoo\lib' | Should -Be $false
            Test-IsInternalWorkspacePath 'C:\Odoo\setup_odoo.ps1' | Should -Be $false
        }
    }

    Context 'Get-FirstFile' {
        BeforeEach {
            $script:Root = Join-Path $TestDrive 'workspace'
            $script:RestoreWorkDir = Join-Path $script:Root '.restore'
            $script:ArtifactsDir = Join-Path $script:Root '.artifacts'
            New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Root 'drive-bundle\releases') | Out-Null
        }

        It 'finds matching file in nested user directory' {
            $filePath = Join-Path $script:Root 'drive-bundle\releases\odoo-enterprise.exe'
            New-Item -ItemType File -Force -Path $filePath | Out-Null

            Get-FirstFile 'odoo*.exe' | Should -Be $filePath
        }
    }
}
