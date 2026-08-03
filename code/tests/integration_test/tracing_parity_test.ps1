# =============================================================================
# tracing_parity_test.ps1 — Gate G6, cross-language span-shape parity
#
# Runs each implementation's span-shape dump script and compares the result, key
# for key, against code/tests/fixtures/tracing/span_shape.json.
#
# Why a separate script from parity_test.ps1: that suite's whole structure is
# "three servers up, compare HTTP responses". Span shape needs "three
# subprocesses, compare stdout" — no ports, no long-running servers. Folding it
# in would mean this check could not run without booting three servers first.
#
# Why a fixture at all, when three mirrored suites already assert the same
# attributes: a per-language test asserts the attributes that ARE present and
# never the ones that are not. An extra attribute in one implementation passes
# every existing test. The comparison here is EXACT, which is the only way that
# drift gets caught.
#
# Usage:
#   pwsh .\code\tests\integration_test\tracing_parity_test.ps1
#
# Prerequisites:
#   - Dart SDK on PATH
#   - Node.js / npx on PATH
#   - Python venv at code/py/modular_api/.venv with modular_api installed
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$dartDir  = Join-Path (Join-Path $repoRoot 'dart') 'modular_api'
$tsDir    = Join-Path (Join-Path $repoRoot 'ts') 'modular_api'
$pyDir    = Join-Path (Join-Path $repoRoot 'py') 'modular_api'
$fixture  = Join-Path $repoRoot 'tests\fixtures\tracing\span_shape.json'

$env:NO_PROXY = 'localhost,127.0.0.1'

function Write-Pass  { param([string]$Msg) Write-Host "  [PASS] $Msg" -ForegroundColor Green }
function Write-Fail  { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red }
function Write-Title { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }

$script:totalTests  = 0
$script:passedTests = 0
$script:failedTests = 0
$script:failures    = @()

function Assert-True {
    param([bool]$Condition, [string]$Description)
    $script:totalTests++
    if ($Condition) {
        $script:passedTests++
        Write-Pass $Description
    } else {
        $script:failedTests++
        $script:failures += $Description
        Write-Fail $Description
    }
}

# ── Running the dumps ────────────────────────────────────────────────────────

# The dump scripts print the framework's own JSON log lines to stdout as well, so
# the payload is found by its sentinel rather than by position. Position would
# work today and break the first time a log line is added.
function Get-SpanShape {
    param(
        [string]$Name,
        [string]$WorkDir,
        [string]$Command,
        [string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    Write-Host "  running $Name ..." -ForegroundColor DarkGray

    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $Environment[$key])
    }

    $originalLocation = Get-Location
    try {
        Set-Location $WorkDir
        $output = & $Command @Arguments 2>&1
    } finally {
        Set-Location $originalLocation
        foreach ($key in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key])
        }
    }

    $line = $output | Where-Object { "$_" -like 'SPAN_SHAPE_JSON:*' } | Select-Object -Last 1
    if (-not $line) {
        Write-Host ($output -join "`n") -ForegroundColor DarkYellow
        throw "$Name produced no SPAN_SHAPE_JSON line"
    }

    return ("$line".Substring('SPAN_SHAPE_JSON:'.Length) | ConvertFrom-Json)
}

# ── Comparison ───────────────────────────────────────────────────────────────

# Normalized to one sorted line per span, so a mismatch reads as a diff rather
# than as a walk through nested objects.
function Format-Shape {
    param($Shape)

    $lines = foreach ($span in $Shape.spans) {
        $parent = if ($null -eq $span.parent) { '<root>' } else { $span.parent }
        $keys = if ($null -eq $span.attributeKeys) { @() } else { @($span.attributeKeys) }
        '{0} [kind={1}] [parent={2}] [attrs={3}]' -f $span.name, $span.kind, $parent, (($keys | Sort-Object) -join ',')
    }

    return (@($lines) | Sort-Object) -join "`n"
}

function Test-AgainstFixture {
    param([string]$Name, $Shape, [string]$Expected)

    $actual = Format-Shape -Shape $Shape

    Assert-True ($actual -eq $Expected) "$Name span shape matches the fixture"

    if ($actual -ne $Expected) {
        Write-Host '    expected:' -ForegroundColor DarkYellow
        ($Expected -split "`n") | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
        Write-Host '    actual:' -ForegroundColor DarkYellow
        ($actual -split "`n") | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
    }
}

# ── Run ──────────────────────────────────────────────────────────────────────

Write-Title 'Loading the expected span shape'

if (-not (Test-Path $fixture)) { throw "fixture not found: $fixture" }
$expectedShape = Format-Shape -Shape (Get-Content $fixture -Raw | ConvertFrom-Json)
($expectedShape -split "`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Title 'Capturing span shapes'

$pyVenv = Join-Path $pyDir '.venv\Scripts\python.exe'
if (-not (Test-Path $pyVenv)) { $pyVenv = 'python' }

$dartShape = Get-SpanShape -Name 'Dart' -WorkDir $dartDir `
    -Command 'dart' -Arguments @('run', 'tool/dump_span_shape.dart')

$tsShape = Get-SpanShape -Name 'TypeScript' -WorkDir $tsDir `
    -Command 'npx' -Arguments @('--yes', 'tsx', 'tool/dumpSpanShape.ts')

$pyShape = Get-SpanShape -Name 'Python' -WorkDir $pyDir `
    -Command $pyVenv -Arguments @('-m', 'tools.dump_span_shape') `
    -Environment @{ PYTHONPATH = 'src' }

Write-Title 'Comparing against the fixture'

Test-AgainstFixture -Name 'Dart'       -Shape $dartShape -Expected $expectedShape
Test-AgainstFixture -Name 'TypeScript' -Shape $tsShape   -Expected $expectedShape
Test-AgainstFixture -Name 'Python'     -Shape $pyShape   -Expected $expectedShape

Write-Title 'Comparing the three against each other'

# Not redundant with the above. If all three drifted the same way, they would
# still agree with each other while failing the fixture — reporting both tells
# you whether one implementation broke or the contract itself moved.
$dartFormatted = Format-Shape -Shape $dartShape
Assert-True ($dartFormatted -eq (Format-Shape -Shape $tsShape)) 'Dart and TypeScript agree'
Assert-True ($dartFormatted -eq (Format-Shape -Shape $pyShape)) 'Dart and Python agree'

Write-Host "`n──────────────────────────────────────────────────────────────" -ForegroundColor Magenta

if ($script:failedTests -eq 0) {
    Write-Host "G6 PASSED — ALL $($script:totalTests) TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "$($script:passedTests)/$($script:totalTests) passed, $($script:failedTests) FAILED:" -ForegroundColor Red
    foreach ($failure in $script:failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
}

Write-Host "──────────────────────────────────────────────────────────────`n" -ForegroundColor Magenta

exit $script:failedTests
