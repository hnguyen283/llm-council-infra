[CmdletBinding()]
param(
    [string]$InfraRoot,
    [string]$BackendRoot,
    [switch]$SkipBuild,
    [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($InfraRoot)) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if ([string]::IsNullOrWhiteSpace($BackendRoot)) {
    $BackendRoot = (Resolve-Path (Join-Path $InfraRoot "..\llm-council")).Path
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the BP1.75 C3 proof."
}
if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) {
    throw "Maven is required for the BP1.75 C3 Java probe."
}

$project = "bp175-c3-orchestrator-proof"
$network = "$project-net"
$valkeyName = "$project-valkey"
$zipkinName = "$project-zipkin"
$collectorName = "$project-collector"
$graphName = "$project-graphrag"
$graphImage = "local/bp175-c3-graphrag:local"
$probeImage = "local/bp175-c3-orchestrator-probe:local"
$collectorImage = "otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6"
$zipkinImage = "ghcr.io/openzipkin-contrib/zipkin-otel:0.3.0@sha256:097c7d44b1481857fa7ce8ce4dc6548fec672a48bc23901d6bff9ae0f15dc56d"
$valkeyImage = "valkey/valkey:8.1-alpine@sha256:77643d152547b446fc15cbafaff22004545663fcd40c6b28038ad283837baa75"
$javaBaseImage = "eclipse-temurin:21-jre-alpine@sha256:704db3c40204a44f471191446ddd9cda5d60dab40f0e15c6507b815ed897238b"
$collectorConfig = (Resolve-Path (Join-Path $InfraRoot "projects\observability\otelcol\collector-proof.yaml")).Path
$probeDockerfile = Join-Path $BackendRoot "orchestrator-service\target\C3GraphRagCanaryProbe.Dockerfile"
$probeStage = Join-Path $BackendRoot "bp175-c3-probe-stage"
$networkCreated = $false
$valkeyId = $null
$zipkinId = $null
$collectorId = $null
$graphId = $null

$ingestToken = "bp175-c3-ingest-" + [guid]::NewGuid().ToString("N")
$internalToken = "bp175-c3-internal-" + [guid]::NewGuid().ToString("N")
$tenantId = "11111111-1111-4111-8111-111111111111"
$safeQuery = "BP175 C3 cache verification"
$cachePayload = @{ content = "BP175 C3 fixture response"; confidence_score = 0.91; entities = @(); relationships = @(); citations = @(); mode = 1 } | ConvertTo-Json -Compress

function Invoke-Docker {
    param([string[]]$Arguments, [string]$FailureMessage)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Get-HexDigest {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-HmacDigest {
    param([byte[]]$Key, [byte[]]$Bytes)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([BitConverter]::ToString($hmac.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $hmac.Dispose()
    }
}

function Wait-GraphReady {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & docker exec $graphName python -c "import grpc; channel=grpc.insecure_channel('localhost:50051'); grpc.channel_ready_future(channel).result(timeout=1)" 2>$null
        $ready = $LASTEXITCODE -eq 0
        $ErrorActionPreference = $previousErrorActionPreference
        if ($ready) { return }
        Start-Sleep -Seconds 1
    }
    throw "C3 proof failed: GraphRAG gRPC service did not become ready."
}

function Start-GraphRag {
    param([bool]$TelemetryEnabled)
    $sdkDisabled = if ($TelemetryEnabled) { "false" } else { "true" }
    Invoke-Docker @(
        "run", "-d", "--rm", "--name", $graphName,
        "--network", $network, "--network-alias", "graphrag-retrieval-service",
        "-e", "RUN_MODE=RETRIEVER",
        "-e", "PRODUCTION=false",
        "-e", "SPRING_PROFILES_ACTIVE=",
        "-e", "ACCOUNT_INTERNAL_SERVICE_TOKEN=$internalToken",
        "-e", "REDIS_HOST=valkey",
        "-e", "REDIS_PORT=6379",
        "-e", "OTEL_SERVICE_NAME=graphrag-retrieval-service",
        "-e", "OTEL_EXPORTER_OTLP_ENDPOINT=otel-collector:4317",
        "-e", "OTEL_EXPORTER_OTLP_BEARER_TOKEN=$ingestToken",
        "-e", "OTEL_SDK_DISABLED=$sdkDisabled",
        "-e", "OBSERVABILITY_ENABLED=true",
        $graphImage
    ) "C3 proof failed: could not start the isolated GraphRAG retriever."
    $script:graphId = (& docker ps -q --filter "name=$graphName").Trim()
    if ([string]::IsNullOrWhiteSpace($script:graphId)) { throw "C3 proof failed: GraphRAG container was not created." }
    Wait-GraphReady
}

function Stop-GraphRag {
    if (-not [string]::IsNullOrWhiteSpace($script:graphId)) {
        Invoke-Docker @("rm", "-f", $graphName) "C3 proof failed: could not stop the isolated GraphRAG retriever."
        $script:graphId = $null
    }
}

function Run-Probe {
    param([bool]$TelemetryEnabled, [int]$Iterations)
    $enabled = if ($TelemetryEnabled) { "true" } else { "false" }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $result = (& docker run --rm --network $network `
        -e "BP175_C3_GRAPHRAG_TARGET=graphrag-retrieval-service:50051" `
        -e "BP175_C3_GRAPHRAG_AUTHORIZATION=Bearer $internalToken" `
        -e "BP175_C3_TENANT_ID=$tenantId" `
        -e "BP175_C3_QUERY=$safeQuery" `
        -e "BP175_C3_TELEMETRY_ENABLED=$enabled" `
        -e "BP175_C3_ITERATIONS=$Iterations" `
        -e "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317" `
        -e "OTEL_COLLECTOR_INGEST_TOKEN=$ingestToken" `
        $probeImage 2>&1 | Out-String)
    $probeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    Write-Host ("C3 probe process: telemetry={0} exit={1}" -f $enabled, $probeExitCode)
    if ($probeExitCode -ne 0) { $diagnosticErrorPreference = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $graphDiagnostics = (& docker logs $graphName 2>&1 | Select-Object -Last 30 | Out-String); $ErrorActionPreference = $diagnosticErrorPreference; throw "C3 proof failed: Java GraphRAG probe failed. $result GraphRAG diagnostics: $graphDiagnostics" }
    if ($result -notmatch "p95_ms=([0-9.]+)") { throw "C3 proof failed: Java probe did not report a p95 duration." }
    return [double]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TraceContinuity {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $json = (& docker exec $zipkinName wget -qO- "http://localhost:9411/api/v2/traces?serviceName=orchestrator-service&limit=100" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json) -and $json.TrimStart().StartsWith("[")) {
            try {
                $traces = $json | ConvertFrom-Json
                $spans = @()
                foreach ($trace in @($traces)) {
                    foreach ($span in @($trace)) { $spans += $span }
                }
                $javaSpans = @($spans | Where-Object { $_.name -ieq "graphragclient.executelocalsearch" })
                $graphSpans = @($spans | Where-Object { $_.name -ieq "retrievalpipeline" })
                foreach ($javaSpan in $javaSpans) {
                    foreach ($graphSpan in $graphSpans) {
                        if ($javaSpan.traceId -eq $graphSpan.traceId -and $javaSpan.id -eq $graphSpan.parentId) {
                            return @{ traceId = $javaSpan.traceId; javaSpanId = $javaSpan.id; graphSpanId = $graphSpan.id }
                        }
                    }
                }
            } catch {
                # Zipkin may still be indexing the first accepted batch.
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "C3 proof failed: no Java-to-GraphRAG parent-child trace was indexed by Zipkin."
}

try {
    if (-not $SkipBuild) {
    Push-Location $BackendRoot
    try {
        & mvn -q -pl common,orchestrator-service -am test-compile
        if ($LASTEXITCODE -ne 0) { throw "C3 proof failed: Java probe test compilation failed." }
        & mvn -q -pl common,orchestrator-service -am dependency:copy-dependencies -DincludeScope=test -DoutputDirectory=target/c3-lib
        if ($LASTEXITCODE -ne 0) { throw "C3 proof failed: Java probe dependency staging failed." }
    } finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $probeStage) {
        Remove-Item -LiteralPath $probeStage -Recurse -Force
    }
    New-Item -ItemType Directory -Path $probeStage -Force | Out-Null
    Copy-Item (Join-Path $BackendRoot "common\target\classes") (Join-Path $probeStage "common-classes") -Recurse
    Copy-Item (Join-Path $BackendRoot "orchestrator-service\target\classes") (Join-Path $probeStage "orchestrator-classes") -Recurse
    Copy-Item (Join-Path $BackendRoot "orchestrator-service\target\test-classes") (Join-Path $probeStage "orchestrator-test-classes") -Recurse
    Copy-Item (Join-Path $BackendRoot "orchestrator-service\target\c3-lib") (Join-Path $probeStage "lib") -Recurse

    $probeDockerfileContent = @"
FROM $javaBaseImage
WORKDIR /workspace
COPY bp175-c3-probe-stage/common-classes/ /workspace/common/target/classes/
COPY bp175-c3-probe-stage/orchestrator-classes/ /workspace/orchestrator-service/target/classes/
COPY bp175-c3-probe-stage/orchestrator-test-classes/ /workspace/orchestrator-service/target/test-classes/
COPY bp175-c3-probe-stage/lib/ /workspace/lib/
ENTRYPOINT ["sh", "-c", "exec java -cp '/workspace/orchestrator-service/target/test-classes:/workspace/orchestrator-service/target/classes:/workspace/common/target/classes:/workspace/lib/*' com.aio.orchestrator.grpc.C3GraphRagCanaryProbe"]
"@
    [System.IO.File]::WriteAllText($probeDockerfile, $probeDockerfileContent, [System.Text.UTF8Encoding]::new($false))
    Invoke-Docker @("build", "-f", $probeDockerfile, "-t", $probeImage, $BackendRoot) "C3 proof failed: could not build the Java probe image."
    Invoke-Docker @("build", "-t", $graphImage, (Join-Path $BackendRoot "graphrag-service")) "C3 proof failed: could not build the GraphRAG image."
    }

    $networkNames = @(& docker network ls --format "{{.Name}}")
    if ($networkNames -notcontains $network) {
        Invoke-Docker @("network", "create", "-d", "bridge", $network) "C3 proof failed: could not create the isolated private network."
        $networkCreated = $true
    }
    Invoke-Docker @("run", "-d", "--rm", "--name", $valkeyName, "--network", $network, "--network-alias", "valkey", $valkeyImage) "C3 proof failed: could not start Valkey."
    $valkeyId = (& docker ps -q --filter "name=$valkeyName").Trim()
    if ([string]::IsNullOrWhiteSpace($valkeyId)) { throw "C3 proof failed: Valkey container was not created." }

    Start-GraphRag $false
    $cacheKey = (& docker exec $graphName python -c "from src.db.cache import _cache_key; print(_cache_key('$tenantId', 'local', '$safeQuery')[0])" | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($cacheKey) -or -not $cacheKey.StartsWith("query_cache:v2:")) {
        throw "C3 proof failed: GraphRAG did not provide a valid content-safe cache key."
    }
    $seedScript = "import json; from src.db.cache import _client; from src.db.cache import _cache_key; assert _client is not None; _client.set(_cache_key('$tenantId', 'local', '$safeQuery')[0], json.dumps({'content': 'BP175 C3 fixture response', 'confidence_score': 0.91, 'entities': [], 'relationships': [], 'citations': [], 'mode': 1}))"
    & docker exec $graphName python -c $seedScript
    if ($LASTEXITCODE -ne 0) { throw "C3 proof failed: could not seed the content-safe cache fixture." }
    $baselineP95 = Run-Probe $false 20
    Write-Host ("C3 stage: telemetry-disabled baseline p95={0:F3} ms" -f $baselineP95)
    Stop-GraphRag

    Invoke-Docker @("run", "-d", "--rm", "--name", $zipkinName, "--network", $network, "--network-alias", "zipkin", $zipkinImage) "C3 proof failed: could not start Zipkin."
    $zipkinId = (& docker ps -q --filter "name=$zipkinName").Trim()
    if ([string]::IsNullOrWhiteSpace($zipkinId)) { throw "C3 proof failed: Zipkin container was not created." }
    Invoke-Docker @("run", "-d", "--name", $collectorName, "--network", $network, "--network-alias", "otel-collector", "--tmpfs", "/var/lib/otelcol/queue:rw,nosuid,nodev,noexec,size=64m", "-e", "OTELCOL_INGEST_TOKEN=$ingestToken", "--mount", "type=bind,source=$collectorConfig,target=/etc/otelcol/config.yaml,readonly", $collectorImage, "--config=/etc/otelcol/config.yaml") "C3 proof failed: could not start the disposable Collector."
    $collectorId = (& docker ps -q --filter "name=$collectorName").Trim()
    if ([string]::IsNullOrWhiteSpace($collectorId)) { throw "C3 proof failed: Collector container was not created." }

    Start-GraphRag $true
    $canaryP95 = Run-Probe $true 20
    Write-Host ("C3 stage: Collector canary p95={0:F3} ms" -f $canaryP95)
    $overheadLimit = [Math]::Max($baselineP95 + 25.0, $baselineP95 * 1.5)
    if ($canaryP95 -gt $overheadLimit) {
        throw "C3 proof failed: Collector canary p95 $canaryP95 ms exceeded bounded limit $overheadLimit ms."
    }
    Start-Sleep -Seconds 6
    $continuity = Get-TraceContinuity
    Write-Host "C3 stage: Java-to-GraphRAG trace continuity verified"

    Invoke-Docker @("stop", $collectorName) "C3 proof failed: could not simulate the Collector outage."
    $outageP95 = Run-Probe $true 10
    Write-Host ("C3 stage: Collector outage product p95={0:F3} ms" -f $outageP95)
    Invoke-Docker @("start", $collectorName) "C3 proof failed: could not recover the Collector."
    Start-Sleep -Seconds 3
    $recoveryP95 = Run-Probe $true 10
    Write-Host ("C3 stage: Collector recovery p95={0:F3} ms" -f $recoveryP95)
    Start-Sleep -Seconds 6

    $collectorLogErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $collectorLog = (& docker logs $collectorName 2>&1 | Out-String)
    $ErrorActionPreference = $collectorLogErrorPreference
    if ($collectorLog -notmatch "GraphRagClient.executeLocalSearch") { throw "C3 proof failed: Collector did not accept the Java GraphRAG client span." }
    if ($collectorLog -notmatch "RetrievalPipeline") { throw "C3 proof failed: Collector did not accept the GraphRAG retrieval span." }
    if ($collectorLog -notmatch "rag.operation") { throw "C3 proof failed: Collector did not retain the registered operation field." }
    foreach ($forbidden in @($safeQuery, $tenantId, $internalToken, $ingestToken)) {
        if ($collectorLog.Contains($forbidden)) { throw "C3 proof failed: Collector output contained a prohibited fixture value." }
    }

    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
            New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
        }
        $evidence = [ordered]@{
            schemaVersion = "llm-council.bp175-c3-evidence/v1"
            recordedAtUtc = [DateTime]::UtcNow.ToString("o")
            baselineP95Ms = [Math]::Round($baselineP95, 3)
            canaryP95Ms = [Math]::Round($canaryP95, 3)
            outageP95Ms = [Math]::Round($outageP95, 3)
            recoveryP95Ms = [Math]::Round($recoveryP95, 3)
            traceContinuity = [ordered]@{
                parentService = "orchestrator-service"
                parentSpan = "GraphRagClient.executeLocalSearch"
                childService = "graphrag-retrieval-service"
                childSpan = "RetrievalPipeline"
                parentChildVerified = $true
            }
            collectorOutageProductPath = "passed"
            collectorRecovery = "passed"
            privateNetwork = $network
            cleanup = "named containers and private network removed in finally"
        }
        [System.IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host ("BP1.75 C3 proof passed: baseline_p95_ms={0:F3}; canary_p95_ms={1:F3}; outage_p95_ms={2:F3}; recovery_p95_ms={3:F3}; trace_id={4}; private_network={5}." -f $baselineP95, $canaryP95, $outageP95, $recoveryP95, $continuity.traceId, $network)
}
finally {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    foreach ($name in @($graphName, $collectorName, $zipkinName, $valkeyName)) {
        & docker rm -f $name 2>$null | Out-Null
    }
    if ($networkCreated) {
        & docker network rm $network 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $probeDockerfile) {
        Remove-Item -LiteralPath $probeDockerfile -Force
    }
    if (Test-Path -LiteralPath $probeStage) {
        Remove-Item -LiteralPath $probeStage -Recurse -Force
    }
    $ErrorActionPreference = $previousErrorActionPreference
}