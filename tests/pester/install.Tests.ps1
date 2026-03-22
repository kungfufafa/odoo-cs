$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\install.ps1'
$platformLibPath = Join-Path (Split-Path -Parent $here) '..\lib\platform.ps1'

BeforeAll {
    . $platformLibPath
    . $libPath
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
