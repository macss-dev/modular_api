# =============================================================================
# typecheck.ps1 — pyright across the five Python packages
#
# Every package's pyproject.toml configures pyright in strict mode, with a
# relaxed "annotate every expression" family under tests/ and example/. That
# configuration was declared for a long time without pyright ever being
# installed, so 1211 diagnostics accumulated where nobody could see them —
# including two public annotations that named a type too weak to use.
#
# This script is what makes the configuration exigible: it is the Python
# counterpart of `npm test` in the TypeScript packages, which chains
# `tsc --noEmit` before vitest because vitest does not typecheck either.
#
# Usage:
#   pwsh .\code\py\typecheck.ps1
#   pwsh .\code\py\typecheck.ps1 -Package modular_api_postgres
#
# Prerequisites:
#   - Python venv at code/py/modular_api/.venv
#   - pyright installed into it: pip install -e "code/py/modular_api[dev]"
#     (pyright downloads its own node runtime on first run)
#
# Exits non-zero if any package reports an error, so it can gate a commit,
# a pre-push hook or a CI step.
# =============================================================================

[CmdletBinding()]
param(
    # Check a single package instead of all five.
    [string] $Package,

    # The interpreter to run pyright with. Defaults to the local venv when it exists, otherwise to
    # whatever `python` is on PATH.
    [string] $Python
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pyRoot = $PSScriptRoot

# The venv path used to be hardcoded, which made this gate runnable on exactly one machine — and a
# gate that has only ever run in one place is close to a gate that has never run. CI has no venv, so
# it falls through to the interpreter on PATH and the same script serves both.
$venvPython = Join-Path $pyRoot 'modular_api\.venv\Scripts\python.exe'
$python =
    if ($Python) { $Python }
    elseif (Test-Path -LiteralPath $venvPython) { $venvPython }
    else { (Get-Command python -ErrorAction SilentlyContinue).Source }

if (-not $python) {
    Write-Error "No interpreter found: no venv at $venvPython, and no 'python' on PATH. Pass -Python <path>."
    exit 1
}

$packages = @(
    'modular_api'
    'modular_api_rest_client'
    'modular_api_postgres'
    'modular_api_graphql_client'
    'modular_api_sqlserver'
)

if ($Package) {
    if ($packages -notcontains $Package) {
        Write-Error "Unknown package '$Package'. Expected one of: $($packages -join ', ')"
        exit 1
    }
    $packages = @($Package)
}

$failed = @()

foreach ($name in $packages) {
    $directory = Join-Path $pyRoot $name
    Write-Host "── $name " -NoNewline

    # `--outputjson` rather than the text output: the summary line is what we
    # report, and parsing it is more robust than scraping human-readable text.
    Push-Location $directory
    try {
        # `--pythonpath` no es redundante con lanzar pyright desde ese intérprete: pyright resuelve
        # los imports contra el entorno que *él* encuentra —y encuentra `.venv` del paquete si
        # existe—, no contra quien lo lanzó. Sin esta bandera, una corrida local siempre resolvía
        # contra el venv del desarrollador y daba limpio mientras CI fallaba por un driver opcional
        # que ese venv tenía instalado. Con la bandera, lo local y CI miran el mismo entorno.
        $raw = & $python -m pyright --pythonpath $python --outputjson 2>$null
    }
    finally {
        Pop-Location
    }

    try {
        $report = $raw | ConvertFrom-Json
    }
    catch {
        Write-Host "could not run pyright" -ForegroundColor Red
        $failed += $name
        continue
    }

    $errors = @($report.generalDiagnostics | Where-Object { $_.severity -eq 'error' })
    $warnings = @($report.generalDiagnostics | Where-Object { $_.severity -eq 'warning' })

    if ($errors.Count -gt 0) {
        Write-Host "$($errors.Count) error(s)" -ForegroundColor Red
        foreach ($diagnostic in $errors) {
            $relative = $diagnostic.file -replace [regex]::Escape($pyRoot), ''
            $line = $diagnostic.range.start.line + 1
            $rule = if ($diagnostic.rule) { $diagnostic.rule } else { 'error' }
            $message = ($diagnostic.message -split "`n")[0]
            Write-Host "    $relative`:$line  $rule`: $message"
        }
        $failed += $name
    }
    elseif ($warnings.Count -gt 0) {
        Write-Host "clean ($($warnings.Count) warning(s))" -ForegroundColor Yellow
    }
    else {
        Write-Host "clean" -ForegroundColor Green
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "All $($packages.Count) package(s) typecheck clean." -ForegroundColor Green
exit 0
