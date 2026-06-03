Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = (Resolve-Path (Join-Path $scriptDir '..\..\compose.yml')).Path

Write-Host 'Stopping SQL Server 2019 container...' -ForegroundColor Yellow
& docker compose -f $composeFile down --remove-orphans
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose down failed.'
}