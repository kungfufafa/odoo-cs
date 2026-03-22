$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) '..\lib\config.ps1'
$platformLibPath = Join-Path (Split-Path -Parent $here) '..\lib\platform.ps1'

BeforeAll {
    . $platformLibPath
    . $libPath
}

Describe 'Config Module' {
    Context 'Get-ResolvedWorkers' {
        It 'returns explicit value when not auto' {
            $script:OdooWorkers = '4'
            Get-ResolvedWorkers | Should -Be '4'
        }
        It 'returns auto value based on CPU and RAM' {
            $script:OdooWorkers = 'auto'
            # Assuming mock or just running locally. We don't mock Get-MemoryGB here but we can test it returns a string.
            $result = Get-ResolvedWorkers
            $result | Should -BeOfType [string]
        }
    }

    Context 'Get-ResolvedMemorySoft' {
        It 'returns explicit value when not auto' {
            $script:OdooLimitMemorySoft = '1024'
            Get-ResolvedMemorySoft | Should -Be '1024'
        }
        It 'returns default value when memory is not auto' {
            $script:OdooLimitMemorySoft = 'auto'
            $result = Get-ResolvedMemorySoft
            $result | Should -BeOfType [string]
        }
    }

    Context 'Get-ResolvedMemoryHard' {
        It 'returns explicit value when not auto' {
            $script:OdooLimitMemoryHard = '2048'
            Get-ResolvedMemoryHard | Should -Be '2048'
        }
        It 'returns 1.2x soft limit when auto' {
            $script:OdooLimitMemoryHard = 'auto'
            $script:OdooLimitMemorySoft = '100'
            Get-ResolvedMemoryHard | Should -Be '120'
        }
    }

    Context 'Convert-ToOdooBool' {
        It 'returns True for 1' {
            Convert-ToOdooBool 1 | Should -Be 'True'
        }
        It 'returns False for 0' {
            Convert-ToOdooBool 0 | Should -Be 'False'
        }
    }

    Context 'Write-OdooConfig' {
        BeforeEach {
            $tempDir = Join-Path $here 'tmp_config'
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
            $script:ConfigFile = Join-Path $tempDir 'odoo.conf'
            $script:OdooAdminPasswd = 'admin'
            $script:DbHost = 'localhost'
            $script:DbPort = '5432'
            $script:DbUser = 'odoo'
            $script:DbPassword = 'odoo'
            $script:OdooDbFilter = '.*'
            $script:CustomAddonsDir = 'C:\addons'
            $script:DataDir = 'C:\data'
            $script:OdooHttpInterface = '0.0.0.0'
            $script:OdooHttpPort = '8069'
            $script:OdooGeventPort = '8072'
            $script:LogFile = 'odoo.log'
            $script:OdooProxyMode = 1
            $script:OdooListDb = 0
            $script:OdooWorkers = '0'
            $script:OdooMaxCronThreads = '1'
            $script:OdooDbMaxConn = '64'
            $script:OdooLimitMemorySoft = '1024'
            $script:OdooLimitMemoryHard = '2048'
            $script:OdooLimitTimeCpu = '60'
            $script:OdooLimitTimeReal = '120'
            $script:OdooWithoutDemo = 'all'
            $script:OdooServerDir = $null
        }

        AfterEach {
            $tempDir = Join-Path $here 'tmp_config'
            if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
        }

        It 'creates odoo.conf file containing all required elements' {
            Write-OdooConfig
            Test-Path $script:ConfigFile | Should -Be $true
            $content = Get-Content $script:ConfigFile
            $content | Should -Match '\[options\]'
            $content | Should -Match 'admin_passwd = admin'
            $content | Should -Match 'proxy_mode = True'
            $content | Should -Match 'list_db = False'
        }
    }
}
