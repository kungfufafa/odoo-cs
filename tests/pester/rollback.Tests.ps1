BeforeAll {
    $libDir = Join-Path $PSScriptRoot '..' '..' 'lib'
    . (Join-Path $libDir 'logging.ps1')
    . (Join-Path $libDir 'rollback.ps1')
}

Describe 'Rollback Module' {
    BeforeEach {
        Clear-Rollback
        $script:TestVar = 0
    }

    It 'Register-Rollback adds to stack' {
        Register-Rollback 'Test action' { $script:TestVar = 1 }
        $script:RollbackStack.Count | Should -Be 1
        $script:RollbackStack[0].Description | Should -Be 'Test action'
    }

    It 'Invoke-Rollback executes actions in reverse order' {
        Register-Rollback 'Action 1' { $script:TestVar += 1 }
        Register-Rollback 'Action 2' { $script:TestVar += 10 }
        
        Invoke-Rollback
        
        $script:TestVar | Should -Be 11
        $script:RollbackStack.Count | Should -Be 0
    }

    It 'Clear-Rollback resets stack' {
        Register-Rollback 'Test action' { }
        $script:RollbackStack.Count | Should -Be 1
        
        Clear-Rollback
        
        $script:RollbackStack.Count | Should -Be 0
    }

    It 'Invoke-Rollback handles empty stack gracefully' {
        { Invoke-Rollback } | Should -Not -Throw
    }

    It 'Invoke-Rollback continues after individual action failure' {
        Register-Rollback 'Action 1' { $script:TestVar = 1 }
        Register-Rollback 'Fail Action' { throw 'Test error' }
        Register-Rollback 'Action 3' { $script:TestVar += 3 }

        # Should not throw and still execute Action 1 and 3
        { Invoke-Rollback } | Should -Not -Throw
        $script:TestVar | Should -Be 4
    }
}
