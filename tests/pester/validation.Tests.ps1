$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\validation.ps1'
$logLibPath = Join-Path (Split-Path -Parent $here) '..\lib\logging.ps1'

BeforeAll {
    . $logLibPath
    . $libPath
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
        $allowed = @('apple', 'banana', 'orange')
        It 'accepts valid enum' {
            Test-ValidEnum 'FRUIT' 'apple' $allowed | Should -Be $true
        }
        It 'rejects invalid enum' {
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

        It 'throws error on invalid enum' {
            $script:RestoreMode = 'invalid_mode'
            { Test-AllInputs } | Should -Throw
        }
    }
}
