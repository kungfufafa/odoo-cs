$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\logging.ps1'

BeforeAll {
    . $libPath
}

Describe 'Logging Module' {
    It 'Write-Log correctly formats a message' {
        $scriptBlock = { Write-Log -Message 'Test message' -Level 'INFO' }
        $output = & $scriptBlock *>&1

        $output | Should -Match '\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(''-|''\+|\w+).*?\] \[INFO\] \[setup-odoo\.ps1\] Test message'
    }

    It 'Write-Log correctly defaults to INFO level' {
        $scriptBlock = { Write-Log -Message 'Default level' }
        $output = & $scriptBlock *>&1

        $output | Should -Match '\[INFO\]'
        $output | Should -Match 'Default level'
    }

    It 'Write-Log accepts ERROR level' {
        $scriptBlock = { Write-Log -Message 'Error occurred' -Level 'ERROR' }
        $output = & $scriptBlock *>&1

        $output | Should -Match '\[ERROR\]'
    }

    It 'Write-Log throws on invalid level' {
        { Write-Log -Message 'Testing' -Level 'INVALID' } | Should -Throw
    }
}
