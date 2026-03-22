function Get-ResolvedWorkers {
    if ($OdooWorkers -ne 'auto') { return $OdooWorkers }
    $memoryGb = Get-MemoryGB
    if ($memoryGb -lt 4) { return '0' }
    $cpuCount = Get-CpuCount
    $cpuBased = ($cpuCount * 2) + 1
    $memoryBased = $memoryGb - 1
    $workers = [Math]::Min($cpuBased, $memoryBased)
    if ($workers -lt 2) { $workers = 2 }
    return [string]$workers
}

function Get-ResolvedMemorySoft {
    if ($OdooLimitMemorySoft -ne 'auto') { return $OdooLimitMemorySoft }
    $memoryGb = Get-MemoryGB
    if ($memoryGb -le 0) { return '2147483648' }
    $soft = [int64]($memoryGb * 1GB * 0.7)
    if ($soft -lt 2147483648) { $soft = 2147483648 }
    return [string]$soft
}

function Get-ResolvedMemoryHard {
    if ($OdooLimitMemoryHard -ne 'auto') { return $OdooLimitMemoryHard }
    $soft = [int64](Get-ResolvedMemorySoft)
    return [string]([int64]($soft * 1.2))
}

function Convert-ToOdooBool {
    param([int]$Value)
    if ($Value -eq 1) { return 'True' }
    return 'False'
}

function Write-OdooConfig {
    $addonsPath = $CustomAddonsDir
    if ($OdooServerDir) {
        $addonsPath = (Join-Path $OdooServerDir 'addons') + ',' + $CustomAddonsDir
    }
    $workers = Get-ResolvedWorkers
    $memorySoft = Get-ResolvedMemorySoft
    $memoryHard = Get-ResolvedMemoryHard

    $content = @"
[options]
admin_passwd = $OdooAdminPasswd
db_host = $DbHost
db_port = $DbPort
db_user = $DbUser
db_password = $DbPassword
dbfilter = $OdooDbFilter
addons_path = $addonsPath
data_dir = $DataDir
http_interface = $OdooHttpInterface
http_port = $OdooHttpPort
gevent_port = $OdooGeventPort
logfile = $LogFile
proxy_mode = $(Convert-ToOdooBool $OdooProxyMode)
list_db = $(Convert-ToOdooBool $OdooListDb)
workers = $workers
max_cron_threads = $OdooMaxCronThreads
db_maxconn = $OdooDbMaxConn
limit_memory_soft = $memorySoft
limit_memory_hard = $memoryHard
limit_time_cpu = $OdooLimitTimeCpu
limit_time_real = $OdooLimitTimeReal
without_demo = $OdooWithoutDemo
"@
    Set-Content -Path $ConfigFile -Value $content -Encoding UTF8
    Write-Log "wrote Odoo config to $ConfigFile (workers=$workers)"
}

function Write-RuntimeEnv {
    $resolvedOdooBin = if ($OdooBin) { $OdooBin } else { '' }
    $content = @"
`$script:Root = '$(Escape-PsLiteral $Root)'
`$script:ConfigFile = '$(Escape-PsLiteral $ConfigFile)'
`$script:OdooBin = '$(Escape-PsLiteral $resolvedOdooBin)'
`$script:DbName = '$(Escape-PsLiteral $DbName)'
`$script:OdooHttpPort = '$(Escape-PsLiteral $OdooHttpPort)'
`$script:StdoutLog = '$(Escape-PsLiteral $StdoutLog)'
`$script:OdooPidFile = '$(Escape-PsLiteral $OdooPidFile)'
"@
    Set-Content -Path $RuntimeEnvFile -Value $content -Encoding UTF8
}
