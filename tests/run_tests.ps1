[CmdletBinding()]
param (
    [switch]$VerboseOutput,
    [string]$TestFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PesterDir = Join-Path $ScriptDir 'pester'
$ResultsDir = Join-Path $ScriptDir 'results'

if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host 'Pester is not installed. Run: Install-Module -Name Pester -Force -SkipPublisherCheck' -ForegroundColor Red
    exit 1
}
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
}

$Config = New-PesterConfiguration
if ($TestFile) {
    if (-not (Test-Path -Path $TestFile)) {
        $Config.Run.Path = Join-Path $PesterDir $TestFile
    } else {
        $Config.Run.Path = $TestFile
    }
} else {
    $Config.Run.Path = $PesterDir
}

if ($VerboseOutput) {
    $Config.Output.Verbosity = 'Detailed'
} else {
    $Config.Output.Verbosity = 'Normal'
}

$Config.TestResult.Enabled = $true
$Config.TestResult.OutputPath = Join-Path $ResultsDir 'pester-results.xml'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Odoo — Pester Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
if ($TestFile) { Write-Host "Running: $($Config.Run.Path)" }
else { Write-Host "Running all tests in $PesterDir" }
Write-Host ""

$Result = Invoke-Pester -Configuration $Config

Write-Host ""
if ($Result.FailedCount -gt 0) {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  $($Result.FailedCount) test(s) failed!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 1
} else {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  All tests passed!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    exit 0
}
