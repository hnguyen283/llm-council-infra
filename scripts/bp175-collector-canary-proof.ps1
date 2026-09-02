[CmdletBinding()]
param(
    [string]$InfraRoot
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InfraRoot)) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the BP1.75 Collector canary proof."
}

$project = "bp175-collector-proof"
$composeFile = Join-Path $InfraRoot "projects\observability\docker-compose.yml"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bp175-collector-proof-" + [guid]::NewGuid().ToString("N"))
$collectorId = $null
$zipkinId = $null
$proofClientId = $null
$proofClientName = "$project-client"
$proofClientImage = "ghcr.io/openzipkin-contrib/zipkin-otel:0.3.0@sha256:097c7d44b1481857fa7ce8ce4dc6548fec672a48bc23901d6bff9ae0f15dc56d"
$previousToken = [Environment]::GetEnvironmentVariable("OTEL_COLLECTOR_INGEST_TOKEN", "Process")
$previousConfig = [Environment]::GetEnvironmentVariable("OTEL_COLLECTOR_CONFIG_FILE", "Process")
$ingestToken = "bp175-proof-" + [guid]::NewGuid().ToString("N")

function Invoke-Docker {
    param([string[]]$Arguments, [string]$FailureMessage)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Assert-Contains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if (-not $Content.Contains($Needle)) {
        throw "Collector proof failed: expected $Name was absent."
    }
}

function Assert-NotContains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if ($Content.Contains($Needle)) {
        throw "Collector proof failed: prohibited $Name was present."
    }
}

function Assert-CollectorRunning {
    $collectorState = (& docker inspect --format '{{.State.Running}}' $collectorId).Trim()
    if ($collectorState -ne "true") {
        throw "Collector proof failed: Collector is not running."
    }
}

function New-Resource {
    param([string]$ServiceName)
    return @{
        attributes = @(
            @{ key = "service.name"; value = @{ stringValue = $ServiceName } },
            @{ key = "service.version"; value = @{ stringValue = "1.0.0" } },
            @{ key = "unregistered.resource"; value = @{ stringValue = "bp175-resource-marker" } }
        )
    }
}

function New-TracePayload {
    param(
        [string]$ServiceName,
        [string]$Marker,
        [string]$ForbiddenAttribute,
        [string]$UnregisteredAttribute = "",
        [string]$SpanName = "RetrievalPipeline"
    )
    $attributes = @(
        @{ key = "rag.query_length"; value = @{ intValue = "7" } },
        @{ key = "llm_council.telemetry.test_marker"; value = @{ stringValue = $Marker } }
    )
    if (-not [string]::IsNullOrWhiteSpace($ForbiddenAttribute)) {
        $attributes += @{ key = $ForbiddenAttribute; value = @{ stringValue = "bp175-forbidden-marker" } }
    }
    if (-not [string]::IsNullOrWhiteSpace($UnregisteredAttribute)) {
        $attributes += @{ key = $UnregisteredAttribute; value = @{ stringValue = "bp175-unregistered-value" } }
    }
    $nowNanos = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
    return @{
        resourceSpans = @(
            @{
                resource = New-Resource $ServiceName
                scopeSpans = @(
                    @{
                        scope = @{ name = "bp175-collector-proof" }
                        spans = @(
                            @{
                                traceId = "0123456789abcdef0123456789abcdef"
                                spanId = "0123456789abcdef"
                                name = $SpanName
                                kind = 1
                                startTimeUnixNano = $nowNanos
                                endTimeUnixNano = $nowNanos
                                attributes = $attributes
                            }
                        )
                    }
                )
            }
        )
    }
}

function Write-Payload {
    param([hashtable]$Payload, [string]$Name)
    $localPath = Join-Path $tempRoot "$Name.json"
    $containerPath = "/tmp/$Name.json"
    [System.IO.File]::WriteAllText($localPath, ($Payload | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    Invoke-Docker @("cp", $localPath, "$proofClientId`:$containerPath") "Could not copy $Name into the disposable proof client."
    return $containerPath
}

function Send-OtlpJson {
    param([hashtable]$Payload, [string]$Name)
    $containerPath = Write-Payload $Payload $Name
    Invoke-Docker @("exec", $proofClientId, "wget", "-qO", "/dev/null", "--header=Content-Type: application/json", "--header=Authorization: Bearer $ingestToken", "--post-file=$containerPath", "http://otel-collector:4318/v1/traces") "Collector rejected the authenticated $Name payload."
}

function Expect-UnauthenticatedRejection {
    param([hashtable]$Payload, [string]$Name)
    $containerPath = Write-Payload $Payload $Name
    $output = (& docker exec $proofClientId sh -c "wget -S -O /dev/null --header='Content-Type: application/json' --post-file=$containerPath http://otel-collector:4318/v1/traces 2>&1 || true" | Out-String)
    if ($LASTEXITCODE -ne 0 -or $output -notmatch ' 401 ') {
        throw "Collector proof failed: unauthenticated forged service was not rejected with HTTP 401."
    }
}

function Send-QueuePressure {
    param([hashtable]$Payload)
    $containerPath = Write-Payload $Payload "queue-pressure"
    $command = "i=0; while [ `$i -lt 600 ]; do wget -qO /dev/null --header='Content-Type: application/json' --header='Authorization: Bearer $ingestToken' --post-file=$containerPath http://otel-collector:4318/v1/traces || exit 1; i=`$((i+1)); done"
    Invoke-Docker @("exec", $proofClientId, "sh", "-ec", $command) "Collector rejected bounded queue-pressure traffic."
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $env:OTEL_COLLECTOR_INGEST_TOKEN = $ingestToken
    $env:OTEL_COLLECTOR_CONFIG_FILE = "collector-proof.yaml"

    foreach ($network in @("llm-council-observability", "llm-council-otel-ingest")) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & docker network inspect $network 2>$null | Out-Null
        $networkExists = $LASTEXITCODE -eq 0
        $ErrorActionPreference = $previousErrorActionPreference
        if (-not $networkExists) {
            Invoke-Docker @("network", "create", "-d", "bridge", $network) "Could not create the required $network network."
        }
    }

    # Cold-start without the comparison backend. The Collector healthcheck must
    # become ready before Zipkin exists, then remain ready under downstream loss.
    Invoke-Docker @("compose", "-p", $project, "-f", $composeFile, "--profile", "collector-canary", "up", "-d", "--wait", "otel-collector") "Could not cold-start the disposable Collector proof."
    $collectorId = (& docker compose -p $project -f $composeFile --profile collector-canary ps -q otel-collector).Trim()
    if ([string]::IsNullOrWhiteSpace($collectorId)) { throw "Collector proof failed: Collector was not created." }
    Assert-CollectorRunning

    Invoke-Docker @("compose", "-p", $project, "-f", $composeFile, "--profile", "collector-canary", "up", "-d", "--wait", "--wait-timeout", "180", "zipkin") "Could not start the disposable comparison backend after Collector cold-start."
    $zipkinId = (& docker compose -p $project -f $composeFile --profile collector-canary ps -q zipkin).Trim()
    if ([string]::IsNullOrWhiteSpace($zipkinId)) { throw "Collector proof failed: comparison backend was not created." }
    Invoke-Docker @("run", "-d", "--rm", "--name", $proofClientName, "--network", "llm-council-otel-ingest", "--entrypoint", "/bin/sh", $proofClientImage, "-c", "while true; do sleep 3600; done") "Could not start the disposable proof client on the private Collector ingress network."
    $proofClientId = (& docker ps -q --filter "name=$proofClientName").Trim()
    if ([string]::IsNullOrWhiteSpace($proofClientId)) { throw "Collector proof failed: disposable proof client was not created." }

    Invoke-Docker @("exec", $proofClientId, "wget", "-qO", "/dev/null", "http://otel-collector:13133/") "Collector health endpoint did not respond from inside the private Docker network."

    Send-OtlpJson (New-TracePayload "graphrag-retrieval-service" "bp175-allowed-trace" "") "allowed-trace"
    Send-OtlpJson (New-TracePayload "orchestrator-service" "bp175-orchestrator-trace" "" "" "GraphRagClient.executeLocalSearch") "orchestrator-trace"
    Send-OtlpJson (New-TracePayload "graphrag-retrieval-service" "bp175-registry-trace" "" "unregistered.field") "unregistered-trace"
    Send-OtlpJson (New-TracePayload "graphrag-retrieval-service" "bp175-prohibited-trace" "rag.query") "prohibited-trace"
    Send-OtlpJson (New-TracePayload "untrusted-bp175-service" "bp175-untrusted-trace" "") "untrusted-trace"
    Expect-UnauthenticatedRejection (New-TracePayload "graphrag-retrieval-service" "bp175-forged-trace" "") "forged-trace"

    # Keep the comparison exporter unavailable while sending more than its
    # configured queue size. Product-side accepted input must not stop the
    # Collector; restarting the backend then demonstrates recovery.
    Invoke-Docker @("stop", $zipkinId) "Could not stop the disposable comparison backend."
    Send-QueuePressure (New-TracePayload "graphrag-retrieval-service" "bp175-queue-pressure" "")
    Start-Sleep -Seconds 7
    Assert-CollectorRunning

    Invoke-Docker @("start", $zipkinId) "Could not restart the disposable comparison backend."
    Start-Sleep -Seconds 10
    Assert-CollectorRunning

    $metricsAfterRecovery = (& docker exec $proofClientId wget -qO- http://otel-collector:8888/metrics 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Collector proof failed: could not query internal self-metrics after backend recovery." }
    Assert-Contains $metricsAfterRecovery "otelcol_receiver_accepted_spans" "accepted-span self-metric"
    Assert-Contains $metricsAfterRecovery "otelcol_exporter_queue" "queue self-metric"

    $collectorLog = (& docker compose -p $project -f $composeFile --profile collector-canary logs --no-color otel-collector 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Collector proof failed: could not retrieve the disposable debug test sink." }
    Assert-Contains $collectorLog "bp175-allowed-trace" "allowed trace"
    Assert-Contains $collectorLog "bp175-registry-trace" "registered attribute trace"
    Assert-Contains $collectorLog "bp175-orchestrator-trace" "Orchestrator C3 allowlisted trace"
    Assert-Contains $collectorLog "llm_council.telemetry_gateway" "trusted gateway stamp"
    Assert-Contains $collectorLog "service.namespace" "trusted namespace stamp"
    Assert-NotContains $collectorLog "bp175-prohibited-trace" "prohibited trace"
    Assert-NotContains $collectorLog "bp175-untrusted-trace" "untrusted service trace"
    Assert-NotContains $collectorLog "bp175-forged-trace" "unauthenticated forged trace"
    Assert-NotContains $collectorLog "bp175-forbidden-marker" "prohibited field value"
    Assert-NotContains $collectorLog "bp175-unregistered-value" "unregistered attribute value"
    Assert-NotContains $collectorLog "bp175-resource-marker" "unregistered resource attribute value"

    Write-Host "BP1.75 Collector proof passed: cold start, authenticated ingress, allowlist/registry filtering, bounded backend outage, self-metrics, and comparison-backend recovery all succeeded."
}
finally {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if (-not [string]::IsNullOrWhiteSpace($proofClientId)) {
        & docker rm -f $proofClientId 2>$null | Out-Null
    }
    & docker compose -p $project -f $composeFile --profile collector-canary down --volumes --remove-orphans 2>$null | Out-Null
    if ($null -eq $previousToken) { Remove-Item Env:OTEL_COLLECTOR_INGEST_TOKEN -ErrorAction SilentlyContinue } else { $env:OTEL_COLLECTOR_INGEST_TOKEN = $previousToken }
    if ($null -eq $previousConfig) { Remove-Item Env:OTEL_COLLECTOR_CONFIG_FILE -ErrorAction SilentlyContinue } else { $env:OTEL_COLLECTOR_CONFIG_FILE = $previousConfig }
    $ErrorActionPreference = $previousErrorActionPreference
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}