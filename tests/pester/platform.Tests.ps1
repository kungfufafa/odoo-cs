$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\platform.ps1'
$logLibPath = Join-Path (Split-Path -Parent $here) '..\lib\logging.ps1'

BeforeAll {
    . $logLibPath
    . $libPath
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
}
