BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..' '..' 'setup_odoo.ps1'
}

Describe 'Integration (setup_odoo.ps1)' {
    Context 'CLI Parsing' {
        It 'shows usage with help command' {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $script:scriptPath help *>&1
            $output | Should -Match 'Usage:'
            $output | Should -Match 'Commands:'
        }

        It 'shows version with --version flag' {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $script:scriptPath --version *>&1
            $output | Should -Match 'setup_odoo\.ps1 v'
        }
    }
}
