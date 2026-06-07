Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..\..\..')).Path
$fixturePath = (Resolve-Path (Join-Path $repoRoot 'code\tests\fixtures\graphql\sqlserver\01_stage1_smoke.sql')).Path
$containerName = if ($env:MODULAR_API_SQLSERVER_CONTAINER) {
    $env:MODULAR_API_SQLSERVER_CONTAINER
} else {
    'modular_api_sqlserver_2019'
}

& (Join-Path $scriptDir 'up.ps1')

Write-Host 'Copying SQL fixture into SQL Server container...' -ForegroundColor Yellow
& docker cp $fixturePath "${containerName}:/tmp/01_stage1_smoke.sql"
if ($LASTEXITCODE -ne 0) {
    throw 'docker cp failed for SQL Server fixture.'
}

$command = 'if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -d master -b -i "/tmp/01_stage1_smoke.sql"; else /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -d master -b -i "/tmp/01_stage1_smoke.sql"; fi'

Write-Host 'Applying Stage 1 smoke fixture...' -ForegroundColor Yellow
& docker exec $containerName /bin/bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to apply SQL Server Stage 1 fixture.'
}

Write-Host 'SQL Server Stage 1 fixture is ready.' -ForegroundColor Green