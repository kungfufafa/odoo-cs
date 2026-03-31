BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..' '..' 'setup_odoo.ps1'
}

Describe 'Integration (setup_odoo.ps1)' {
    Context 'CLI Parsing' {
        It 'shows usage with help command' {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$($script:scriptPath)' help" 2>&1
            $outputText = $output -join "`n"
            $outputText | Should -Match 'Usage:'
            $outputText | Should -Match 'Commands:'
            $outputText | Should -Match 'fetch-start'
            $outputText | Should -Match 'ODOO_EXPOSE_HTTP'
        }

        It 'shows version with --version flag' {
            $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$($script:scriptPath)' --version" 2>&1
            $outputText = $output -join "`n"
            $outputText | Should -Match 'setup_odoo\.ps1 v'
        }
    }
}
