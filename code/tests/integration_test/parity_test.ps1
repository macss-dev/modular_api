# =============================================================================
# parity_test.ps1 — Cross-language parity integration tests
#
# Starts all three implementation servers (Dart, TypeScript, Python) in parallel
# on separate ports, exercises every public endpoint, then compares responses to
# verify identical behaviour across all three languages.
#
# Usage:
#   pwsh .\code\tests\integration_test\parity_test.ps1
#
# Prerequisites:
#   - Dart SDK on PATH
#   - Node.js / npx on PATH
#   - Python venv at py/.venv with modular_api installed
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths & ports ────────────────────────────────────────────────────────────

$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$dartDir  = Join-Path $repoRoot 'dart'
$tsDir    = Join-Path $repoRoot 'ts'
$pyDir    = Join-Path $repoRoot 'py'

# Each implementation runs on its own port so all three are alive simultaneously.
$dartPort = 8081
$tsPort   = 8082
$pyPort   = 8083

# Bypass corporate proxy for localhost — necessary in environments where the
# PowerShell profile configures proxy bypass but -NoProfile skips it.
$env:NO_PROXY = 'localhost,127.0.0.1'

# Current runtime topology:
# - business and operational routes share the same API basePath
# These helpers keep the parity suite aligned with that single source of truth.
$script:ModuleBasePath = '/api/v1'
$script:OperationalBasePath = $script:ModuleBasePath

function Join-ApiPath {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    $normalizedBase = if ([string]::IsNullOrWhiteSpace($BasePath) -or $BasePath -eq '/') {
        ''
    } else {
        '/' + $BasePath.Trim('/ ')
    }

    $normalizedRelative = '/' + $RelativePath.Trim('/ ')
    return ($normalizedBase + $normalizedRelative) -replace '/{2,}', '/'
}

function Get-ModulePath {
    param([string]$RelativePath)
    return Join-ApiPath -BasePath $script:ModuleBasePath -RelativePath $RelativePath
}

function Get-OperationalPath {
    param([string]$RelativePath)
    return Join-ApiPath -BasePath $script:OperationalBasePath -RelativePath $RelativePath
}

# ── Colour helpers ───────────────────────────────────────────────────────────

function Write-Pass  { param([string]$Msg) Write-Host "  [PASS] $Msg" -ForegroundColor Green }
function Write-Fail  { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red }
function Write-Title { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }

# ── Counters ─────────────────────────────────────────────────────────────────

$script:totalTests  = 0
$script:passedTests = 0
$script:failedTests = 0
$script:failures    = @()

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Description
    )
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

# ── Server lifecycle ─────────────────────────────────────────────────────────

function Start-ExampleServer {
    <#
    .SYNOPSIS
        Starts an example server and waits until it responds on /health.
    .DESCRIPTION
        Uses file-based redirection to avoid the .NET stdout/stderr buffer
        deadlock that occurs with stream-based redirection.
    #>
    param(
        [string]$Name,
        [string]$WorkDir,
        [string]$Command,
        [string[]]$Arguments,
        [int]$Port,
        [hashtable]$Environment = @{}
    )

    Write-Host "  Starting $Name on port $Port..." -ForegroundColor Yellow

    $stdoutLog = Join-Path $env:TEMP "modular_parity_${Name}_stdout.log"
    $stderrLog = Join-Path $env:TEMP "modular_parity_${Name}_stderr.log"

    $startProcessArgs = @{
        FilePath               = $Command
        ArgumentList           = $Arguments
        WorkingDirectory       = $WorkDir
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $stdoutLog
        RedirectStandardError  = $stderrLog
    }
    if ($Environment.Count -gt 0) {
        $startProcessArgs.Environment = $Environment
    }

    $process = Start-Process @startProcessArgs

    $healthUrl = "http://127.0.0.1:$Port$(Get-OperationalPath '/health')"

    # Wait for the server to become healthy (max 30 s).
    $deadline  = (Get-Date).AddSeconds(30)
    $isReady   = $false
    $lastError = ''

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500

        # Abort early if the process already exited (e.g. port conflict).
        if ($process.HasExited) {
            Write-Host "  $Name process exited with code $($process.ExitCode)." -ForegroundColor Red
            break
        }

        try {
            $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 3 $healthUrl 2>$null
            if ($code -eq '200') {
                $isReady = $true
                break
            }
        } catch {
            $lastError = $_.Exception.Message
        }
    }

    if (-not $isReady) {
        Write-Host "  $Name last poll error: $lastError" -ForegroundColor Red
        Write-Host "  $Name stderr:" -ForegroundColor Red
        if (Test-Path $stderrLog) { Get-Content $stderrLog | ForEach-Object { Write-Host "    $_" } }
        Write-Host "  $Name stdout:" -ForegroundColor Red
        if (Test-Path $stdoutLog) { Get-Content $stdoutLog | ForEach-Object { Write-Host "    $_" } }
        Stop-ExampleServer -Process $process -Name $Name
        throw "$Name server did not become healthy within 30 seconds."
    }

    Write-Host "  $Name server is ready on port $Port." -ForegroundColor Green
    return $process
}

function Stop-ExampleServer {
    <#
    .SYNOPSIS
        Kills the server process and its entire child process tree.
    #>
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Name
    )
    try {
        if (-not $Process.HasExited) {
            # taskkill /T kills the whole process tree — necessary because
            # some runtimes (dart, node) spawn child workers.
            $null = & taskkill /PID $Process.Id /T /F 2>&1
            $Process.WaitForExit(5000) | Out-Null
        }
    } catch {
        # Process already exited — nothing to do.
    }
    Write-Host "  $Name server stopped." -ForegroundColor Yellow
}

# ── HTTP helpers ─────────────────────────────────────────────────────────────

function Invoke-Endpoint {
    <#
    .SYNOPSIS
        Calls an endpoint via curl.exe and returns status code, content-type, and body.
        Does NOT throw on 4xx/5xx — captures the response as-is.
        Uses curl.exe to avoid PowerShell byte-array / disposed-stream quirks.
    #>
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body   = $null
    )

    # -s  silent, -w  write metadata after body, -X  method
    $curlArgs = @('-s', '-X', $Method, '-w', "`n%{http_code}`n%{content_type}")

    if ($Body) {
        $curlArgs += '-H'; $curlArgs += 'Content-Type: application/json'
        $curlArgs += '-d'; $curlArgs += $Body
    }

    $curlArgs += $Uri

    $raw = & curl.exe @curlArgs 2>$null
    # Last two lines are http_code and content_type (from -w).
    $lines = $raw -split "`n"
    $contentType = $lines[-1]
    $statusCode  = [int]$lines[-2]
    $bodyText    = ($lines[0..($lines.Length - 3)]) -join "`n"

    return @{
        StatusCode  = $statusCode
        ContentType = $contentType
        Body        = $bodyText
    }
}

# ── Endpoint test suites ─────────────────────────────────────────────────────
#
# Every test function receives $ImplName (for output) and $BaseUrl
# (e.g. http://127.0.0.1:8081) so it is server-agnostic.

function Test-DocsEndpoint {
    <#
    .SYNOPSIS
        Verifies GET /docs returns Swagger UI HTML from CDN (PRD-003).
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $docsPath = Get-OperationalPath '/docs'
    $openApiJsonPath = Get-OperationalPath '/openapi.json'
    $response = Invoke-Endpoint -Uri "$BaseUrl$docsPath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName $docsPath → 200"

    $contentType = "$($response.ContentType)"
    Assert-True ($contentType -match 'text/html') `
        "$ImplName $docsPath Content-Type contains text/html"

    $body = $response.Body
    Assert-True ($body -match '@macss/docs-ui') `
        "$ImplName $docsPath body contains @macss/docs-ui CDN reference"

    Assert-True ($body -match 'DocsUI\.init') `
        "$ImplName $docsPath body contains DocsUI.init bootloader"

    Assert-True ($body -match [regex]::Escape($openApiJsonPath)) `
        "$ImplName $docsPath body points at $openApiJsonPath"

    Assert-True ($body -match '<title>Modular API') `
        "$ImplName $docsPath title is 'Modular API'"

    Assert-True ($body -notmatch 'scalar') `
        "$ImplName $docsPath no Scalar regression (PRD-003)"

    # PRD-004: dark mode CSS lives inside the docs-ui JS bundle (injected at
    # runtime via injectStyles).  Verifying '@macss/docs-ui' and 'DocsUI.init'
    # above is sufficient — CSS quality is tested in docs-ui's own test suite.

    return $body
}

function Test-HealthEndpoint {
    <#
    .SYNOPSIS
        Verifies GET /health returns IETF Health Check format.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $healthPath = Get-OperationalPath '/health'
    $response = Invoke-Endpoint -Uri "$BaseUrl$healthPath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName $healthPath → 200"

    $contentType = "$($response.ContentType)"
    Assert-True ($contentType -match 'application/health\+json') `
        "$ImplName $healthPath Content-Type is application/health+json"

    $bodyText = $response.Body
    $json = $bodyText | ConvertFrom-Json

    Assert-True ($json.status -eq 'pass') `
        "$ImplName $healthPath status is 'pass'"

    Assert-True ($json.version -eq '1.0.0') `
        "$ImplName $healthPath version is '1.0.0'"

    Assert-True ($json.releaseId -eq '1.0.0-debug') `
        "$ImplName $healthPath releaseId is '1.0.0-debug'"

    Assert-True ($null -ne $json.checks.example) `
        "$ImplName $healthPath checks contains 'example'"

    Assert-True ($json.checks.example.status -eq 'pass') `
        "$ImplName $healthPath checks.example.status is 'pass'"

    return $json
}

function Test-MetricsEndpoint {
    <#
    .SYNOPSIS
        Verifies GET /metrics returns Prometheus text exposition format.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    # Hit a use case first so metrics have at least one observation.
    $helloPath = Get-ModulePath '/greetings/hello-world'
    $metricsPath = Get-OperationalPath '/metrics'
    $null = Invoke-Endpoint -Uri "$BaseUrl$helloPath" `
        -Method POST -Body '{"name":"MetricsWarmup"}'

    $response = Invoke-Endpoint -Uri "$BaseUrl$metricsPath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName $metricsPath → 200"

    $contentType = "$($response.ContentType)"
    Assert-True ($contentType -match 'text/plain') `
        "$ImplName $metricsPath Content-Type contains text/plain"

    $body = $response.Body

    Assert-True ($body -match 'http_requests_total') `
        "$ImplName $metricsPath contains http_requests_total"

    Assert-True ($body -match 'http_request_duration_seconds') `
        "$ImplName $metricsPath contains http_request_duration_seconds"

    Assert-True ($body -match 'greetings_total') `
        "$ImplName $metricsPath contains custom counter greetings_total"

    return $body
}

function Test-UseCaseSuccess {
    <#
    .SYNOPSIS
        POST /api/v1/greetings/hello-world with valid input → 200.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $helloPath = Get-ModulePath '/greetings/hello-world'
    $response = Invoke-Endpoint -Uri "$BaseUrl$helloPath" `
        -Method POST -Body '{"name":"World"}'

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName POST hello (valid) → 200"

    if ($response.StatusCode -ne 200) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.message -eq 'Hello, World!') `
        "$ImplName POST hello (valid) message is 'Hello, World!'"

    return $json
}

function Test-UseCaseValidationFailure {
    <#
    .SYNOPSIS
        POST /api/v1/greetings/hello-world with empty name → 400.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $helloPath = Get-ModulePath '/greetings/hello-world'
    $response = Invoke-Endpoint -Uri "$BaseUrl$helloPath" `
        -Method POST -Body '{"name":""}'

    Assert-True ($response.StatusCode -eq 400) `
        "$ImplName POST hello (empty name) → 400"

    if ($response.StatusCode -notin @(400, 422)) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.error -eq 'name is required') `
        "$ImplName POST hello (empty name) error is 'name is required'"

    return $json
}

function Test-UseCaseMissingBody {
    <#
    .SYNOPSIS
        POST /api/v1/greetings/hello-world with empty object → 400.
        fromJson validates required fields — returns "Missing required field: name".
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $helloPath = Get-ModulePath '/greetings/hello-world'
    $response = Invoke-Endpoint -Uri "$BaseUrl$helloPath" `
        -Method POST -Body '{}'

    Assert-True ($response.StatusCode -eq 400) `
        "$ImplName POST hello (empty object) → 400"

    if ($response.StatusCode -notin @(400, 422)) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.error -eq 'Missing required field: name') `
        "$ImplName POST hello (empty object) error is 'Missing required field: name'"

    return $json
}

function Test-UseCaseWrongType {
    <#
    .SYNOPSIS
        POST /api/v1/greetings/hello-world with wrong type → 400.
        fromJson validates JSON types — returns "Field 'name' must be of type string".
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $helloPath = Get-ModulePath '/greetings/hello-world'
    $response = Invoke-Endpoint -Uri "$BaseUrl$helloPath" `
        -Method POST -Body '{"name":123}'

    Assert-True ($response.StatusCode -eq 400) `
        "$ImplName POST hello (wrong type) → 400"

    if ($response.StatusCode -notin @(400, 422)) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.error -eq "Field 'name' must be of type string") `
        "$ImplName POST hello (wrong type) error is 'Field ''name'' must be of type string'"

    return $json
}

# ── Time/Now UseCase tests ───────────────────────────────────────────────────

function Test-TimeNowDefault {
    <#
    .SYNOPSIS
        GET /api/v1/time/current-time (no tz param) → 200 with datetime and offset.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $timePath = Get-ModulePath '/time/current-time'
    $response = Invoke-Endpoint -Uri "$BaseUrl$timePath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName GET time/now (default) → 200"

    if ($response.StatusCode -ne 200) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($null -ne $json.datetime) `
        "$ImplName GET time/now (default) has datetime field"

    Assert-True ($null -ne $json.offset) `
        "$ImplName GET time/now (default) has offset field"

    return $json
}

function Test-TimeNowWithOffset {
    <#
    .SYNOPSIS
        GET /api/v1/time/current-time?tz=utc-5 → 200 with offset == -5.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $response = Invoke-Endpoint -Uri "${BaseUrl}$(Get-ModulePath '/time/current-time')?tz=utc-5"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName GET time/now?tz=utc-5 → 200"

    if ($response.StatusCode -ne 200) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.offset -eq -5) `
        "$ImplName GET time/now?tz=utc-5 offset is -5"

    Assert-True ($null -ne $json.datetime) `
        "$ImplName GET time/now?tz=utc-5 has datetime field"

    return $json
}

function Test-TimeNowInvalidTz {
    <#
    .SYNOPSIS
        GET /api/v1/time/current-time?tz=invalid → 400 validation error.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $response = Invoke-Endpoint -Uri "${BaseUrl}$(Get-ModulePath '/time/current-time')?tz=invalid"

    Assert-True ($response.StatusCode -eq 400) `
        "$ImplName GET time/now?tz=invalid → 400"

    if ($response.StatusCode -notin @(400, 422)) {
        Write-Host "    Body was: $($response.Body)" -ForegroundColor DarkGray
        return $null
    }

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.error -eq 'invalid timezone format, use utc, utc-5, utc+3') `
        "$ImplName GET time/now?tz=invalid error message is correct"

    return $json
}

function Test-OpenApiJson {
    <#
    .SYNOPSIS
        GET /openapi.json returns a valid OpenAPI 3.0 spec with expected structure.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $openApiJsonPath = Get-OperationalPath '/openapi.json'
    $response = Invoke-Endpoint -Uri "$BaseUrl$openApiJsonPath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName $openApiJsonPath → 200"

    $contentType = "$($response.ContentType)"
    Assert-True ($contentType -match 'application/json') `
        "$ImplName $openApiJsonPath Content-Type is application/json"

    $json = $response.Body | ConvertFrom-Json

    Assert-True ($json.openapi -eq '3.0.0') `
        "$ImplName $openApiJsonPath openapi version is '3.0.0'"

    Assert-True ($json.info.title -eq 'Modular API') `
        "$ImplName $openApiJsonPath info.title is 'Modular API'"

    Assert-True ($null -ne $json.paths) `
        "$ImplName $openApiJsonPath has paths object"

    # The example registers POST /api/v1/greetings/hello-world
    $greetingsPath = $json.paths.'/api/v1/greetings/hello-world'
    Assert-True ($null -ne $greetingsPath) `
        "$ImplName $openApiJsonPath paths has /api/v1/greetings/hello-world"

    Assert-True ($null -ne $greetingsPath.post) `
        "$ImplName $openApiJsonPath /api/v1/greetings/hello-world has POST operation"

    # Request body schema
    $requestBodySchema = $greetingsPath.post.requestBody.content.'application/json'.schema
    Assert-True ($null -ne $requestBodySchema) `
        "$ImplName $openApiJsonPath POST hello has request body schema"

    # Response 200 schema
    $responseSchema = $greetingsPath.post.responses.'200'.content.'application/json'.schema
    Assert-True ($null -ne $responseSchema) `
        "$ImplName $openApiJsonPath POST hello has 200 response schema"

    # components.schemas — named schemas for Swagger UI Schemas section
    Assert-True ($null -ne $json.components) `
        "$ImplName $openApiJsonPath has components object"

    Assert-True ($null -ne $json.components.schemas) `
        "$ImplName $openApiJsonPath has components.schemas"

    $schemaNames = $json.components.schemas.PSObject.Properties.Name | Sort-Object
    Assert-True ($schemaNames -contains 'greetings_hello_world_Input') `
        "$ImplName $openApiJsonPath components.schemas has greetings_hello_world_Input"

    Assert-True ($schemaNames -contains 'greetings_hello_world_Output') `
        "$ImplName $openApiJsonPath components.schemas has greetings_hello_world_Output"

    # requestBody and response must use $ref to components.schemas
    Assert-True ($requestBodySchema.'$ref' -match 'greetings_hello_world_Input') `
        "$ImplName $openApiJsonPath POST hello requestBody uses `$ref to Input schema"

    Assert-True ($responseSchema.'$ref' -match 'greetings_hello_world_Output') `
        "$ImplName $openApiJsonPath POST hello response uses `$ref to Output schema"

    # Schema content — Input must have properties.name with type string
    $inputSchema = $json.components.schemas.'greetings_hello_world_Input'
    $hasInputName = ($null -ne $inputSchema.properties) -and ($null -ne $inputSchema.properties.name)
    Assert-True $hasInputName `
        "$ImplName $openApiJsonPath greetings_hello_world_Input has properties.name"

    if ($hasInputName) {
        Assert-True ($inputSchema.properties.name.type -eq 'string') `
            "$ImplName $openApiJsonPath greetings_hello_world_Input.name type is 'string'"
    }

    # Schema content — Output must have properties.message with type string
    $outputSchema = $json.components.schemas.'greetings_hello_world_Output'
    $hasOutputMessage = ($null -ne $outputSchema.properties) -and ($null -ne $outputSchema.properties.message)
    Assert-True $hasOutputMessage `
        "$ImplName $openApiJsonPath greetings_hello_world_Output has properties.message"

    if ($hasOutputMessage) {
        Assert-True ($outputSchema.properties.message.type -eq 'string') `
            "$ImplName $openApiJsonPath greetings_hello_world_Output.message type is 'string'"
    }

    # ── Time/Now endpoint in OpenAPI ─────────────────────────────────────────

    $timePath = $json.paths.'/api/v1/time/current-time'
    Assert-True ($null -ne $timePath) `
        "$ImplName $openApiJsonPath paths has /api/v1/time/current-time"

    Assert-True ($null -ne $timePath.get) `
        "$ImplName $openApiJsonPath /api/v1/time/current-time has GET operation"

    Assert-True ($schemaNames -contains 'time_current_time_Output') `
        "$ImplName $openApiJsonPath components.schemas has time_current_time_Output"

    return $json
}

function Test-OpenApiYaml {
    <#
    .SYNOPSIS
        GET /openapi.yaml returns a YAML representation of the OpenAPI spec.
    #>
    param([string]$ImplName, [string]$BaseUrl)

    $openApiYamlPath = Get-OperationalPath '/openapi.yaml'
    $response = Invoke-Endpoint -Uri "$BaseUrl$openApiYamlPath"

    Assert-True ($response.StatusCode -eq 200) `
        "$ImplName $openApiYamlPath → 200"

    $body = $response.Body

    Assert-True ($body -match 'openapi:') `
        "$ImplName $openApiYamlPath contains 'openapi:' key"

    Assert-True ($body -match 'info:') `
        "$ImplName $openApiYamlPath contains 'info:' key"

    Assert-True ($body -match 'paths:') `
        "$ImplName $openApiYamlPath contains 'paths:' key"

    Assert-True ($body -match '/api/v1/greetings/hello-world') `
        "$ImplName $openApiYamlPath contains /api/v1/greetings/hello-world path"

    Assert-True ($body -match 'components:') `
        "$ImplName $openApiYamlPath contains 'components:' section"

    Assert-True ($body -match 'schemas:') `
        "$ImplName $openApiYamlPath contains 'schemas:' section"

    return $body
}

# ── Per-implementation runner ────────────────────────────────────────────────

function Test-Implementation {
    <#
    .SYNOPSIS
        Exercises all endpoints for one implementation against an already-running server.
    #>
    param(
        [string]$Name,
        [string]$BaseUrl
    )

    Write-Title "Testing $Name"

    $results = @{
        Docs               = Test-DocsEndpoint            -ImplName $Name -BaseUrl $BaseUrl
        Health             = Test-HealthEndpoint           -ImplName $Name -BaseUrl $BaseUrl
        Metrics            = Test-MetricsEndpoint          -ImplName $Name -BaseUrl $BaseUrl
        UseCaseSuccess     = Test-UseCaseSuccess           -ImplName $Name -BaseUrl $BaseUrl
        UseCaseEmptyName   = Test-UseCaseValidationFailure -ImplName $Name -BaseUrl $BaseUrl
        UseCaseMissingBody = Test-UseCaseMissingBody       -ImplName $Name -BaseUrl $BaseUrl
        UseCaseWrongType   = Test-UseCaseWrongType         -ImplName $Name -BaseUrl $BaseUrl
        TimeNowDefault     = Test-TimeNowDefault           -ImplName $Name -BaseUrl $BaseUrl
        TimeNowWithOffset  = Test-TimeNowWithOffset        -ImplName $Name -BaseUrl $BaseUrl
        TimeNowInvalidTz   = Test-TimeNowInvalidTz         -ImplName $Name -BaseUrl $BaseUrl
        OpenApiJson        = Test-OpenApiJson              -ImplName $Name -BaseUrl $BaseUrl
        OpenApiYaml        = Test-OpenApiYaml              -ImplName $Name -BaseUrl $BaseUrl
    }
    return $results
}

# ── Cross-comparison ─────────────────────────────────────────────────────────

function Compare-Implementations {
    <#
    .SYNOPSIS
        Compares collected results from all implementations and asserts
        structural parity on every endpoint response.
    #>
    param(
        [hashtable]$Dart,
        [hashtable]$TypeScript,
        [hashtable]$Python
    )

    Write-Title 'Cross-implementation parity'

    # ── Health fields ────────────────────────────────────────────────────────

    Assert-True (
        ($Dart.Health.status -eq $TypeScript.Health.status) -and
        ($Dart.Health.status -eq $Python.Health.status)
    ) 'Health status identical across implementations'

    Assert-True (
        ($Dart.Health.version -eq $TypeScript.Health.version) -and
        ($Dart.Health.version -eq $Python.Health.version)
    ) 'Health version identical across implementations'

    Assert-True (
        ($Dart.Health.releaseId -eq $TypeScript.Health.releaseId) -and
        ($Dart.Health.releaseId -eq $Python.Health.releaseId)
    ) 'Health releaseId identical across implementations'

    # ── UseCase success ──────────────────────────────────────────────────────

    if ($Dart.UseCaseSuccess -and $TypeScript.UseCaseSuccess -and $Python.UseCaseSuccess) {
        Assert-True (
            ($Dart.UseCaseSuccess.message -eq $TypeScript.UseCaseSuccess.message) -and
            ($Dart.UseCaseSuccess.message -eq $Python.UseCaseSuccess.message)
        ) 'UseCase success response identical across implementations'
    } else {
        Write-Fail 'UseCase success response identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'UseCase success parity skipped — missing data'
    }

    # ── UseCase validation error ─────────────────────────────────────────────

    if ($Dart.UseCaseEmptyName -and $TypeScript.UseCaseEmptyName -and $Python.UseCaseEmptyName) {
        Assert-True (
            ($Dart.UseCaseEmptyName.error -eq $TypeScript.UseCaseEmptyName.error) -and
            ($Dart.UseCaseEmptyName.error -eq $Python.UseCaseEmptyName.error)
        ) 'UseCase validation error identical across implementations'
    } else {
        Write-Fail 'UseCase validation error identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'UseCase validation error parity skipped — missing data'
    }

    if ($Dart.UseCaseMissingBody -and $TypeScript.UseCaseMissingBody -and $Python.UseCaseMissingBody) {
        Assert-True (
            ($Dart.UseCaseMissingBody.error -eq $TypeScript.UseCaseMissingBody.error) -and
            ($Dart.UseCaseMissingBody.error -eq $Python.UseCaseMissingBody.error)
        ) 'UseCase missing-body error identical across implementations'
    } else {
        Write-Fail 'UseCase missing-body error identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'UseCase missing-body error parity skipped — missing data'
    }

    if ($Dart.UseCaseWrongType -and $TypeScript.UseCaseWrongType -and $Python.UseCaseWrongType) {
        Assert-True (
            ($Dart.UseCaseWrongType.error -eq $TypeScript.UseCaseWrongType.error) -and
            ($Dart.UseCaseWrongType.error -eq $Python.UseCaseWrongType.error)
        ) 'UseCase wrong-type error identical across implementations'
    } else {
        Write-Fail 'UseCase wrong-type error identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'UseCase wrong-type error parity skipped — missing data'
    }

    # ── Time/Now parity ──────────────────────────────────────────────────────
    # Offset must be identical when a fixed tz param is used.
    # Datetime values are NOT compared — each server's clock may differ by milliseconds.

    if ($Dart.TimeNowWithOffset -and $TypeScript.TimeNowWithOffset -and $Python.TimeNowWithOffset) {
        Assert-True (
            ($Dart.TimeNowWithOffset.offset -eq $TypeScript.TimeNowWithOffset.offset) -and
            ($Dart.TimeNowWithOffset.offset -eq $Python.TimeNowWithOffset.offset)
        ) 'Time/now offset identical across implementations (utc-5)'
    } else {
        Write-Fail 'Time/now offset identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'Time/now offset parity skipped — missing data'
    }

    if ($Dart.TimeNowInvalidTz -and $TypeScript.TimeNowInvalidTz -and $Python.TimeNowInvalidTz) {
        Assert-True (
            ($Dart.TimeNowInvalidTz.error -eq $TypeScript.TimeNowInvalidTz.error) -and
            ($Dart.TimeNowInvalidTz.error -eq $Python.TimeNowInvalidTz.error)
        ) 'Time/now invalid tz error identical across implementations'
    } else {
        Write-Fail 'Time/now invalid tz error identical across implementations (skipped — missing data)'
        $script:totalTests++; $script:failedTests++
        $script:failures += 'Time/now invalid tz error parity skipped — missing data'
    }

    # ── OpenAPI JSON structural parity ───────────────────────────────────────

    Assert-True (
        ($Dart.OpenApiJson.openapi -eq $TypeScript.OpenApiJson.openapi) -and
        ($Dart.OpenApiJson.openapi -eq $Python.OpenApiJson.openapi)
    ) 'OpenAPI version identical across implementations'

    Assert-True (
        ($Dart.OpenApiJson.info.title -eq $TypeScript.OpenApiJson.info.title) -and
        ($Dart.OpenApiJson.info.title -eq $Python.OpenApiJson.info.title)
    ) 'OpenAPI info.title identical across implementations'

    # All three must expose the same paths.
    $dartPaths = ($Dart.OpenApiJson.paths.PSObject.Properties.Name       | Sort-Object) -join ','
    $tsPaths   = ($TypeScript.OpenApiJson.paths.PSObject.Properties.Name | Sort-Object) -join ','
    $pyPaths   = ($Python.OpenApiJson.paths.PSObject.Properties.Name     | Sort-Object) -join ','

    Assert-True (
        ($dartPaths -eq $tsPaths) -and ($dartPaths -eq $pyPaths)
    ) "OpenAPI paths identical across implementations ($dartPaths)"

    # ── Swagger UI docs parity (PRD-003) ──────────────────────────────────────

    $swaggerKeywords = @('@macss/docs-ui', 'DocsUI.init', '<title>Modular API')
    foreach ($keyword in $swaggerKeywords) {
        $dartHas = $Dart.Docs       -match [regex]::Escape($keyword)
        $tsHas   = $TypeScript.Docs -match [regex]::Escape($keyword)
        $pyHas   = $Python.Docs     -match [regex]::Escape($keyword)
        Assert-True ($dartHas -and $tsHas -and $pyHas) `
            "Docs keyword '$keyword' present in all implementations"
    }

    # ── Shared-basePath docs HTML byte-identical across implementations ──────
    # All three templates must produce the same HTML (after title interpolation).

    Assert-True (
        ($Dart.Docs -eq $TypeScript.Docs) -and ($Dart.Docs -eq $Python.Docs)
    ) "$(Get-OperationalPath '/docs') HTML identical across all three implementations"

    # ── OpenAPI components.schemas parity ─────────────────────────────────────
    # All three must expose the same named schemas in components.schemas.

    $dartSchemas  = ($Dart.OpenApiJson.components.schemas.PSObject.Properties.Name       | Sort-Object) -join ','
    $tsSchemas    = ($TypeScript.OpenApiJson.components.schemas.PSObject.Properties.Name  | Sort-Object) -join ','
    $pySchemas    = ($Python.OpenApiJson.components.schemas.PSObject.Properties.Name      | Sort-Object) -join ','

    Assert-True (
        ($dartSchemas -eq $tsSchemas) -and ($dartSchemas -eq $pySchemas)
    ) "OpenAPI components.schemas identical across implementations ($dartSchemas)"

    # ── Schema content parity (properties, types, required) ──────────────────
    # Dart is the reference — TS and Python must produce identical schema content.

    $dartInputJson  = $Dart.OpenApiJson.components.schemas.'greetings_hello_world_Input'       | ConvertTo-Json -Depth 10 -Compress
    $tsInputJson    = $TypeScript.OpenApiJson.components.schemas.'greetings_hello_world_Input'  | ConvertTo-Json -Depth 10 -Compress
    $pyInputJson    = $Python.OpenApiJson.components.schemas.'greetings_hello_world_Input'      | ConvertTo-Json -Depth 10 -Compress

    Assert-True (
        ($dartInputJson -eq $tsInputJson) -and ($dartInputJson -eq $pyInputJson)
    ) 'OpenAPI greetings_hello_world_Input schema content identical across implementations'

    $dartOutputJson  = $Dart.OpenApiJson.components.schemas.'greetings_hello_world_Output'       | ConvertTo-Json -Depth 10 -Compress
    $tsOutputJson    = $TypeScript.OpenApiJson.components.schemas.'greetings_hello_world_Output'  | ConvertTo-Json -Depth 10 -Compress
    $pyOutputJson    = $Python.OpenApiJson.components.schemas.'greetings_hello_world_Output'      | ConvertTo-Json -Depth 10 -Compress

    Assert-True (
        ($dartOutputJson -eq $tsOutputJson) -and ($dartOutputJson -eq $pyOutputJson)
    ) 'OpenAPI greetings_hello_world_Output schema content identical across implementations'

    # ── Metrics format parity ────────────────────────────────────────────────

    $metricsKeywords = @('http_requests_total', 'http_request_duration_seconds', 'greetings_total')
    foreach ($keyword in $metricsKeywords) {
        $dartHas = $Dart.Metrics       -match $keyword
        $tsHas   = $TypeScript.Metrics -match $keyword
        $pyHas   = $Python.Metrics     -match $keyword
        Assert-True ($dartHas -and $tsHas -and $pyHas) `
            "Metric '$keyword' present in all implementations"
    }

    # ── OpenAPI YAML parity ──────────────────────────────────────────────────

    $yamlKeywords = @('openapi:', 'info:', 'paths:', '/api/v1/greetings/hello-world', '/api/v1/time/current-time')
    foreach ($keyword in $yamlKeywords) {
        $dartHas = $Dart.OpenApiYaml       -match [regex]::Escape($keyword)
        $tsHas   = $TypeScript.OpenApiYaml -match [regex]::Escape($keyword)
        $pyHas   = $Python.OpenApiYaml     -match [regex]::Escape($keyword)
        Assert-True ($dartHas -and $tsHas -and $pyHas) `
            "YAML keyword '$keyword' present in all implementations"
    }
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host   "║   Modular API — Cross-Language Parity Integration Tests     ║" -ForegroundColor Magenta
Write-Host   "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

$pyVenv = Join-Path $pyDir '.venv\Scripts\python.exe'

# npx is a .ps1 wrapper on some Node managers (fnm, nvm) which Start-Process
# cannot launch directly. Resolve the .cmd companion next to node.exe instead.
$nodeDir = Split-Path (Get-Command node).Source
$npxCmd  = Join-Path $nodeDir 'npx.cmd'

$dartProcess = $null
$tsProcess   = $null
$pyProcess   = $null

try {
    # ── Start all three servers in parallel ──────────────────────────────────

    Write-Title 'Starting servers'

    $dartProcess = Start-ExampleServer -Name 'Dart' -WorkDir $dartDir `
        -Command 'dart' -Arguments @('run', 'example/example.dart', $dartPort) `
        -Port $dartPort

    $tsProcess = Start-ExampleServer -Name 'TypeScript' -WorkDir $tsDir `
        -Command $npxCmd -Arguments @('--yes', 'tsx', 'example/example.ts', $tsPort) `
        -Port $tsPort

    $pyProcess = Start-ExampleServer -Name 'Python' -WorkDir $pyDir `
        -Command $pyVenv -Arguments @('-m', 'example.example', $pyPort) `
        -Environment @{ PYTHONPATH = 'src' } `
        -Port $pyPort

    # ── Exercise each implementation ─────────────────────────────────────────

    $dartResults = Test-Implementation -Name 'Dart'       -BaseUrl "http://127.0.0.1:$dartPort"
    $tsResults   = Test-Implementation -Name 'TypeScript' -BaseUrl "http://127.0.0.1:$tsPort"
    $pyResults   = Test-Implementation -Name 'Python'     -BaseUrl "http://127.0.0.1:$pyPort"

    # ── Cross-compare results ────────────────────────────────────────────────

    Compare-Implementations -Dart $dartResults -TypeScript $tsResults -Python $pyResults

} finally {
    # ── Tear down all servers ────────────────────────────────────────────────

    Write-Title 'Stopping servers'

    if ($dartProcess) { Stop-ExampleServer -Process $dartProcess -Name 'Dart' }
    if ($tsProcess)   { Stop-ExampleServer -Process $tsProcess   -Name 'TypeScript' }
    if ($pyProcess)   { Stop-ExampleServer -Process $pyProcess   -Name 'Python' }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n──────────────────────────────────────────────────────────────" -ForegroundColor Magenta

if ($script:failedTests -eq 0) {
    Write-Host "ALL $($script:totalTests) TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "$($script:passedTests)/$($script:totalTests) passed, $($script:failedTests) FAILED:" -ForegroundColor Red
    foreach ($failure in $script:failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
}

Write-Host "──────────────────────────────────────────────────────────────`n" -ForegroundColor Magenta

# Exit with non-zero if any test failed — useful for CI pipelines.
exit $script:failedTests
