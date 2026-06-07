Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$containerName = if ($env:MODULAR_API_SQLSERVER_CONTAINER) {
    $env:MODULAR_API_SQLSERVER_CONTAINER
} else {
    'modular_api_sqlserver_2019'
}

$deadline = (Get-Date).AddMinutes(3)

while ((Get-Date) -lt $deadline) {
    $status = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerName 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and $status -eq 'healthy') {
        Write-Host "SQL Server container is healthy: $containerName" -ForegroundColor Green
        exit 0
    }

    Start-Sleep -Seconds 2
}

Write-Host 'SQL Server container did not become healthy in time.' -ForegroundColor Red
& docker logs --tail 200 $containerName
throw "Timed out waiting for SQL Server container health: $containerName"