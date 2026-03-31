$script:RollbackStack = @()

function Register-Rollback {
    param([string]$Description, [scriptblock]$Action)
    $script:RollbackStack += [PSCustomObject]@{ Description = $Description; Action = $Action }
    Write-Log -Level DEBUG "rollback registered: $Description"
}

function Invoke-Rollback {
    if ($script:RollbackStack.Count -eq 0) { return }
    Write-Log -Level WARN "executing rollback: $($script:RollbackStack.Count) action(s)"
    for ($i = $script:RollbackStack.Count - 1; $i -ge 0; $i--) {
        $entry = $script:RollbackStack[$i]
        try {
            Write-Log -Level WARN "  rollback: $($entry.Description)"
            & $entry.Action
        } catch {
            Write-Log -Level ERROR "  rollback failed: $($entry.Description) - $_"
        }
    }
    $script:RollbackStack = @()
}

function Clear-Rollback { $script:RollbackStack = @() }
