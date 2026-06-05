#!/usr/bin/env pwsh
# ─── Publish @macss/modular-api to npm ────────────────────────
# Usage:
#   .\publish.ps1              # publish to npm
#   .\publish.ps1 -DryRun      # simulate publish (no upload)
# ───────────────────────────────────────────────────────────────

param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location $PSScriptRoot

# ─── Load token from .env ─────────────────────────────────────
$envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envFile)) {
    Write-Error "Missing .env file. Create ts/.env with: TOKEN_NPM=npm_..."
    exit 1
}

$envLines = Get-Content $envFile
$token = ($envLines | Where-Object { $_ -match '^\s*TOKEN_NPM\s*=' } | ForEach-Object { ($_ -split '=', 2)[1].Trim() }) | Select-Object -First 1

if (-not $token) {
    Write-Error ".env must contain TOKEN_NPM=npm_... (get it from https://www.npmjs.com/settings/~/tokens)"
    exit 1
}

# ─── Check token expiration ───────────────────────────────────
$tokenExpiry = [DateTime]::new(2026, 7, 28)
$daysLeft = ($tokenExpiry - (Get-Date)).Days

if ($daysLeft -lt 0) {
    Write-Error "TOKEN_NPM expired on $($tokenExpiry.ToString('yyyy-MM-dd')). Rotate it at https://www.npmjs.com/settings/~/tokens"
    exit 1
}
if ($daysLeft -le 14) {
    Write-Warning "⚠️  TOKEN_NPM expires in $daysLeft days ($($tokenExpiry.ToString('yyyy-MM-dd'))). Rotate soon!"
}

# ─── Install dependencies ─────────────────────────────────────
Write-Host "`n🔧 Installing dependencies..." -ForegroundColor Cyan
npm ci --silent
if ($LASTEXITCODE -ne 0) { Write-Error "npm ci failed"; exit 1 }

# ─── Clean previous build ─────────────────────────────────────
Write-Host "`n🧹 Cleaning dist/..." -ForegroundColor Cyan
if (Test-Path dist) { Remove-Item dist -Recurse -Force }

# ─── Build ─────────────────────────────────────────────────────
Write-Host "`n📦 Building package..." -ForegroundColor Cyan
npm run build
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit 1 }

# ─── Run tests ─────────────────────────────────────────────────
Write-Host "`n🧪 Running tests..." -ForegroundColor Cyan
npm test
if ($LASTEXITCODE -ne 0) { Write-Error "Tests failed"; exit 1 }

# ─── Publish ──────────────────────────────────────────────────
$env:NODE_AUTH_TOKEN = $token

# Create temporary .npmrc with token for scoped registry
$npmrc = "//registry.npmjs.org/:_authToken=$token"
$npmrcPath = Join-Path $PSScriptRoot '.npmrc'
$npmrcExisted = Test-Path $npmrcPath

try {
    Set-Content -Path $npmrcPath -Value $npmrc -NoNewline

    if ($DryRun) {
        Write-Host "`n🔍 Dry run (no upload)..." -ForegroundColor Yellow
        npm publish --access public --dry-run
        if ($LASTEXITCODE -ne 0) { Write-Error "Dry run failed"; exit 1 }
    } else {
        Write-Host "`n🚀 Publishing to npm..." -ForegroundColor Green
        npm publish --access public
        if ($LASTEXITCODE -ne 0) { Write-Error "Publish failed"; exit 1 }
    }
} finally {
    # Clean up .npmrc (don't leave token on disk)
    if (-not $npmrcExisted -and (Test-Path $npmrcPath)) {
        Remove-Item $npmrcPath -Force
    }
    Remove-Item Env:\NODE_AUTH_TOKEN -ErrorAction SilentlyContinue
}

if ($DryRun) {
    Write-Host "`n✅ Dry run completed — nothing was published." -ForegroundColor Yellow
} else {
    Write-Host "`n✅ Published successfully!" -ForegroundColor Green
}
Pop-Location
