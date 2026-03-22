BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'platform.ps1')
    . (Join-Path $libDir 'secrets.ps1')
}

Describe 'Secrets Module' {
    BeforeEach {
        $tempDir = Join-Path $PSScriptRoot 'tmp_secrets'
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        $script:SecretsFile = Join-Path $tempDir '.odoo.secrets.ps1'
        $script:DbPassword = ''
        $script:OdooAdminPasswd = ''
    }

    AfterEach {
        $tempDir = Join-Path $PSScriptRoot 'tmp_secrets'
        if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
    }

    It 'New-RandomSecret generates 32 character string' {
        $secret = New-RandomSecret
        $secret.Length | Should -Be 32
        $secret | Should -Match '^[a-zA-Z0-9]+$'
    }

    It 'Ensure-Secrets generates passwords if empty' {
        Ensure-Secrets
        $script:DbPassword | Should -Not -BeNullOrEmpty
        $script:OdooAdminPasswd | Should -Not -BeNullOrEmpty
        Test-Path $script:SecretsFile | Should -Be $true
    }

    It 'Import-Secrets loads from file' {
        # Create a file directly
        $content = @"
`$script:DbPassword = 'db_pass_123'
`$script:OdooAdminPasswd = 'admin_pass_456'
"@
        Set-Content -Path $script:SecretsFile -Value $content

        Import-Secrets

        $script:DbPassword | Should -Be 'db_pass_123'
        $script:OdooAdminPasswd | Should -Be 'admin_pass_456'
    }

    It 'Import-Secrets respects env overrides' {
        $script:OriginalDbPassword = 'env_db_pass'
        $script:OriginalOdooAdminPasswd = 'env_admin_pass'

        # Create a file directly
        $content = @"
`$script:DbPassword = 'db_pass_123'
`$script:OdooAdminPasswd = 'admin_pass_456'
"@
        Set-Content -Path $script:SecretsFile -Value $content

        Import-Secrets

        $script:DbPassword | Should -Be 'env_db_pass'
        $script:OdooAdminPasswd | Should -Be 'env_admin_pass'
    }
}
