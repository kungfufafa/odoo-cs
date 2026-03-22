BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'platform.ps1')
    . (Join-Path $libDir 'install.ps1')
}

Describe 'Install Module' {
    Context 'Show-ArtifactSummary' {
        It 'displays selected artifacts' {
            $script:OdooExePackage = 'odoo.exe'
            $script:OdooBin = 'odoo-bin.exe'
            $script:CustomAddonsDir = 'C:\addons'
            $script:BackupInput = 'dump.sql'
            $script:RestoreMode = 'auto'
            $script:RestoreStrategy = 'refresh'

            # Mock Write-Log for this test
            function Write-Log { param($Message, $Level='INFO') Write-Host $Message }
            { Show-ArtifactSummary } | Should -Not -Throw
        }
    }
}
