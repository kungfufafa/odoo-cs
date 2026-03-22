BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'service.ps1')
}

Describe 'Service Module' {
    Context 'Get-HealthcheckHost' {
        It 'translates empty to 127.0.0.1' {
            $script:OdooHttpInterface = ''
            Get-HealthcheckHost | Should -Be '127.0.0.1'
        }
        It 'translates 0.0.0.0 to 127.0.0.1' {
            $script:OdooHttpInterface = '0.0.0.0'
            Get-HealthcheckHost | Should -Be '127.0.0.1'
        }
        It 'translates :: to ::1' {
            $script:OdooHttpInterface = '::'
            Get-HealthcheckHost | Should -Be '::1'
        }
        It 'strips brackets from IPv6 for host resolution' {
            $script:OdooHttpInterface = '[::1]'
            Get-HealthcheckHost | Should -Be '::1'
        }
        It 'returns exact string for specific hosts' {
            $script:OdooHttpInterface = '192.168.1.100'
            Get-HealthcheckHost | Should -Be '192.168.1.100'
        }
    }

    Context 'Get-HealthcheckUrl' {
        It 'wraps IPv6 in brackets for URL' {
            $script:OdooHttpInterface = '::1'
            $script:OdooHttpPort = '8069'
            Get-HealthcheckUrl | Should -Be 'http://[::1]:8069/web/login'
        }
        It 'uses IPv4 directly' {
            $script:OdooHttpInterface = '0.0.0.0'
            $script:OdooHttpPort = '8069'
            Get-HealthcheckUrl | Should -Be 'http://127.0.0.1:8069/web/login'
        }
    }
}
