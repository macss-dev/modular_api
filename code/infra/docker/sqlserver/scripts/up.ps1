Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = (Resolve-Path (Join-Path $scriptDir '..\..\compose.yml')).Path

Write-Host 'Starting SQL Server 2019 container...' -ForegroundColor Yellow
& docker compose -f $composeFile up -d sqlserver2019
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose up failed.'
}

& (Join-Path $scriptDir 'wait.ps1')