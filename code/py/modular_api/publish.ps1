#!/usr/bin/env pwsh
# ─── Publish modular-api to PyPI ──────────────────────────────
# Usage:
#   .\publish.ps1              # publish to PyPI
#   .\publish.ps1 -TestPyPI    # publish to TestPyPI first
# ───────────────────────────────────────────────────────────────

param(
    [switch]$TestPyPI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Push-Location $PSScriptRoot

# ─── Load token from .env ─────────────────────────────────────
$envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envFile)) {
    Write-Error "Missing .env file. Create py/.env with: TOKEN_PYPI=pypi-..."
    exit 1
}

$envLines = Get-Content $envFile
$token     = ($envLines | Where-Object { $_ -match '^\s*TOKEN_PYPI\s*='     } | ForEach-Object { ($_ -split '=', 2)[1].Trim() }) | Select-Object -First 1
$testToken = ($envLines | Where-Object { $_ -match '^\s*TOKEN_TEST_PYPI\s*=' } | ForEach-Object { ($_ -split '=', 2)[1].Trim() }) | Select-Object -First 1

if ($TestPyPI) {
    if (-not $testToken) {
        Write-Error ".env must contain TOKEN_TEST_PYPI=pypi-... (get it from https://test.pypi.org)"
        exit 1
    }
} else {
    if (-not $token) {
        Write-Error ".env must contain TOKEN_PYPI=pypi-..."
        exit 1
    }
}

# ─── Ensure build tools are installed ──────────────────────────
Write-Host "`n🔧 Checking build tools..." -ForegroundColor Cyan
python -m pip install --quiet build twine

# ─── Clean previous builds ────────────────────────────────────
Write-Host "`n🧹 Cleaning dist/ and build/..." -ForegroundColor Cyan
if (Test-Path dist)  { Remove-Item dist  -Recurse -Force }
if (Test-Path build) { Remove-Item build -Recurse -Force }

# ─── Build ─────────────────────────────────────────────────────
Write-Host "`n📦 Building package..." -ForegroundColor Cyan
python -m build
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit 1 }

# ─── Upload ────────────────────────────────────────────────────
if ($TestPyPI) {
    Write-Host "`n🚀 Uploading to TestPyPI..." -ForegroundColor Yellow
    python -m twine upload --repository testpypi dist/* --username __token__ --password $testToken
} else {
    Write-Host "`n🚀 Uploading to PyPI..." -ForegroundColor Green
    python -m twine upload dist/* --username __token__ --password $token
}

if ($LASTEXITCODE -ne 0) { Write-Error "Upload failed"; exit 1 }

Write-Host "`n✅ Published successfully!" -ForegroundColor Green

Pop-Location
