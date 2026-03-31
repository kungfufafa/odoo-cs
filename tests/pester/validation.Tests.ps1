BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'validation.ps1')
}

Describe 'Validation Module' {
    Context 'Test-ValidPort' {
        It 'accepts valid port 8069' {
            Test-ValidPort 'TEST_PORT' '8069' | Should -Be $true
        }
        It 'accepts port 1' {
            Test-ValidPort 'TEST_PORT' '1' | Should -Be $true
        }
        It 'accepts port 65535' {
            Test-ValidPort 'TEST_PORT' '65535' | Should -Be $true
        }
        It 'rejects port 0' {
            Test-ValidPort 'TEST_PORT' '0' | Should -Be $false
        }
        It 'rejects port 65536' {
            Test-ValidPort 'TEST_PORT' '65536' | Should -Be $false
        }
        It 'rejects non-numeric' {
            Test-ValidPort 'TEST_PORT' 'abc' | Should -Be $false
        }
    }

    Context 'Test-ValidBoolean' {
        It 'accepts 1' {
            Test-ValidBoolean 'TEST_BOOL' 1 | Should -Be $true
        }
        It 'accepts 0' {
            Test-ValidBoolean 'TEST_BOOL' 0 | Should -Be $true
        }
        It 'rejects 2' {
            Test-ValidBoolean 'TEST_BOOL' 2 | Should -Be $false
        }
        It 'rejects -1' {
            Test-ValidBoolean 'TEST_BOOL' -1 | Should -Be $false
        }
    }

    Context 'Test-ValidEnum' {
        It 'accepts valid enum' {
            $allowed = @('apple', 'banana', 'orange')
            Test-ValidEnum 'FRUIT' 'apple' $allowed | Should -Be $true
        }
        It 'rejects invalid enum' {
            $allowed = @('apple', 'banana', 'orange')
            Test-ValidEnum 'FRUIT' 'grape' $allowed | Should -Be $false
        }
    }

    Context 'Test-AllInputs' {
        BeforeEach {
            $script:OdooHttpPort = '8069'
            $script:OdooGeventPort = '8072'
            $script:DbPort = '5432'
            $script:DbRoleCanCreatedb = 1
            $script:DbRoleSuperuser = 0
            $script:OdooExposeHttp = 0
            $script:OdooProxyMode = 1
            $script:OdooListDb = 0
            $script:RestoreMode = 'required'
            $script:RestoreStrategy = 'refresh'
            $script:FilestoreStrategy = 'mirror'
        }

        It 'passes with valid defaults' {
            { Test-AllInputs } | Should -Not -Throw
        }

        It 'throws error on invalid port' {
            $script:OdooHttpPort = '99999'
            { Test-AllInputs } | Should -Throw
        }

        It 'throws error on invalid boolean' {
            $script:DbRoleCanCreatedb = 5
            { Test-AllInputs } | Should -Throw
        }

        It 'throws error on invalid ODOO_EXPOSE_HTTP' {
            $script:OdooExposeHttp = 2
            { Test-AllInputs } | Should -Throw
        }

        It 'throws error on invalid enum' {
            $script:RestoreMode = 'invalid_mode'
            { Test-AllInputs } | Should -Throw
        }
    }
}
