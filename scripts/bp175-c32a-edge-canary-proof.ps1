[CmdletBinding()]
param(
    [string]$InfraRoot,
    [string]$SourceContainer = "llm-council-standard-api-gateway-1",
    [string]$ApiGatewayImage,
    [ValidateRange(10, 100)]
    [int]$SampleCount = 25,
    [ValidateRange(64, 1000)]
    [int]$PressureCount = 160
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InfraRoot)) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the BP1.75 C3.2A edge proof."
}

$prefix = "bp175-c32a-edge-proof"
$baselineName = "$prefix-baseline"
$canaryName = "$prefix-canary"
$rollbackName = "$prefix-rollback"
$collectorName = "$prefix-collector"
$zipkinName = "$prefix-zipkin"
$clientName = "$prefix-client"
$backendNetwork = "$prefix-backend"
$ingestNetwork = "llm-council-otel-ingest"
$collectorImage = "otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6"
$zipkinImage = "ghcr.io/openzipkin-contrib/zipkin-otel:0.3.0@sha256:097c7d44b1481857fa7ce8ce4dc6548fec672a48bc23901d6bff9ae0f15dc56d"
$proofConfig = (Resolve-Path (Join-Path $InfraRoot "projects\observability\otelcol\collector-proof.yaml")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("$prefix-" + [guid]::NewGuid().ToString("N"))
$token = "$prefix-" + [guid]::NewGuid().ToString("N")
$source = $null
$clientId = $null
$cleanupComplete = $false

function Invoke-Docker {
    param([string[]]$Arguments, [string]$FailureMessage)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Assert-Contains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if (-not $Content.Contains($Needle)) { throw "C3.2A edge proof failed: expected $Name was absent." }
}

function Assert-NotContains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if ($Content.Contains($Needle)) { throw "C3.2A edge proof failed: prohibited $Name was present." }
}

function Assert-Running {
    param([string]$ContainerName, [string]$Name)
    $state = (& docker inspect --format '{{.State.Running}}' $ContainerName 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $state -ne "true") { throw "C3.2A edge proof failed: $Name is not running." }
}

function Wait-StablyRunning {
    param([string]$ContainerName, [string]$Name)
    $stableSeconds = 0
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $state = (& docker inspect --format '{{.State.Running}}' $ContainerName 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $state -eq "true") {
            $stableSeconds++
            if ($stableSeconds -ge 5) { return }
        } else {
            $stableSeconds = 0
        }
        Start-Sleep -Seconds 1
    }
    throw "C3.2A edge proof failed: $Name did not remain running for five seconds."
}

function Wait-ApiHealth {
    param([string]$ContainerName)
    for ($attempt = 0; $attempt -lt 75; $attempt++) {
        Start-Sleep -Seconds 2
        & docker exec $ContainerName wget -q -T 5 -O /dev/null http://localhost:8080/actuator/health 2>$null
        if ($LASTEXITCODE -eq 0) { return }
    }
    throw "C3.2A edge proof failed: $ContainerName did not become healthy."
}

function New-ApiContainer {
    param([string]$Name, [bool]$CollectorEnabled)
    $overrides = @{
        EUREKA_CLIENT_ENABLED = "false"
        OTEL_SERVICE_NAME = "api-gateway"
    }
    if ($CollectorEnabled) {
        $overrides['OTEL_EXPORTER_OTLP_ENDPOINT'] = "http://${collectorName}:4318"
        $overrides['OTEL_EXPORTER_OTLP_PROTOCOL'] = "http/protobuf"
        $overrides['OTEL_EXPORTER_OTLP_HEADERS'] = "Authorization=Bearer $token"
        $overrides['MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_HEADERS_AUTHORIZATION'] = "Bearer $token"
        $overrides['MANAGEMENT_OTLP_TRACING_HEADERS_AUTHORIZATION'] = "Bearer $token"
        $overrides['MANAGEMENT_TRACING_EXPORT_OTLP_ENABLED'] = "true"
    } else {
        $overrides['MANAGEMENT_TRACING_EXPORT_OTLP_ENABLED'] = "false"
        $overrides['MANAGEMENT_OTLP_TRACING_EXPORT_ENABLED'] = "false"
    }

    $arguments = @("create", "--name", $Name, "--network", "llm-council-app")
    foreach ($entry in $source.Config.Env) {
        $key = $entry.Split('=', 2)[0]
        if (-not $overrides.ContainsKey($key)) { $arguments += @("-e", $entry) }
    }
    foreach ($key in $overrides.Keys) { $arguments += @("-e", "$key=$($overrides[$key])") }
    foreach ($mount in $source.Mounts | Where-Object { $_.Destination -eq '/run/secrets/api-gateway' }) {
        $arguments += @("--mount", "type=bind,source=$($mount.Source),target=$($mount.Destination),readonly")
    }
    $arguments += $ApiGatewayImage
    Invoke-Docker $arguments "Could not create $Name from the tested API Gateway image."
    foreach ($network in @("llm-council-data", "llm-council-observability", "llm-council-platform")) {
        Invoke-Docker @("network", "connect", $network, $Name) "Could not attach $Name to $network."
    }
    if ($CollectorEnabled) {
        Invoke-Docker @("network", "connect", $ingestNetwork, $Name) "Could not attach $Name to private Collector ingress."
    }
}

function Measure-HealthSamples {
    param([string]$ContainerName, [int]$Count)
    $durations = [System.Collections.Generic.List[double]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        & docker exec $ContainerName wget -q -T 5 -O /dev/null http://localhost:8080/actuator/health 2>$null
        $watch.Stop()
        if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof failed: health sample $index failed for $ContainerName." }
        $durations.Add($watch.Elapsed.TotalMilliseconds)
    }
    $ordered = @($durations | Sort-Object)
    $p95Index = [Math]::Min($ordered.Count - 1, [Math]::Ceiling($ordered.Count * 0.95) - 1)
    return [double]$ordered[$p95Index]
}

function New-Resource {
    param([string]$ServiceName)
    return @{ attributes = @(
        @{ key = "service.name"; value = @{ stringValue = $ServiceName } },
        @{ key = "service.version"; value = @{ stringValue = "c32a-proof" } },
        @{ key = "unregistered.resource"; value = @{ stringValue = "bp175-resource-value" } }
    ) }
}

function New-EdgePayload {
    param(
        [string]$Marker,
        [string]$ServiceName = "api-gateway",
        [string]$SpanName = "http get /actuator/health",
        [string]$ExtraAttribute = "",
        [string]$ExtraValue = "",
        [switch]$WithEvent,
        [switch]$WithLink
    )
    $attributes = @(
        @{ key = "method"; value = @{ stringValue = "GET" } },
        @{ key = "outcome"; value = @{ stringValue = "SUCCESS" } },
        @{ key = "status"; value = @{ stringValue = "200" } },
        @{ key = "uri"; value = @{ stringValue = "/actuator/health" } },
        @{ key = "llm_council.telemetry.test_marker"; value = @{ stringValue = $Marker } }
    )
    if (-not [string]::IsNullOrWhiteSpace($ExtraAttribute)) {
        $attributes += @{ key = $ExtraAttribute; value = @{ stringValue = $ExtraValue } }
    }
    $nowNanos = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
    $span = @{
        traceId = [guid]::NewGuid().ToString("N")
        spanId = [guid]::NewGuid().ToString("N").Substring(0, 16)
        name = $SpanName
        kind = 2
        startTimeUnixNano = $nowNanos
        endTimeUnixNano = $nowNanos
        attributes = $attributes
    }
    if ($WithEvent) {
        $span.events = @(@{ timeUnixNano = $nowNanos; name = "bp175-event"; attributes = @(@{ key = "event.value"; value = @{ stringValue = "bp175-event-value" } }) })
    }
    if ($WithLink) {
        $span.links = @(@{ traceId = [guid]::NewGuid().ToString("N"); spanId = [guid]::NewGuid().ToString("N").Substring(0, 16); attributes = @(@{ key = "link.value"; value = @{ stringValue = "bp175-link-value" } }) })
    }
    return @{ resourceSpans = @(@{ resource = New-Resource $ServiceName; scopeSpans = @(@{ scope = @{ name = "bp175-c32a-proof" }; spans = @($span) }) }) }
}

function Write-ClientPayload {
    param([hashtable]$Payload, [string]$Name)
    $localPath = Join-Path $tempRoot "$Name.json"
    $containerPath = "/tmp/$Name.json"
    [System.IO.File]::WriteAllText($localPath, ($Payload | ConvertTo-Json -Depth 14), [System.Text.UTF8Encoding]::new($false))
    Invoke-Docker @("cp", $localPath, "$clientId`:$containerPath") "Could not copy $Name into the disposable proof client."
    return $containerPath
}

function Send-Payload {
    param([hashtable]$Payload, [string]$Name)
    $containerPath = Write-ClientPayload $Payload $Name
    Invoke-Docker @("exec", $clientId, "wget", "-q", "-O", "/dev/null", "--header=Content-Type: application/json", "--header=Authorization: Bearer $token", "--post-file=$containerPath", "http://${collectorName}:4318/v1/traces") "Collector rejected authenticated payload $Name."
}

function Send-Pressure {
    param([hashtable]$Payload)
    $containerPath = Write-ClientPayload $Payload "queue-pressure"
    $command = "i=0; while [ `$i -lt $PressureCount ]; do wget -q -O /dev/null --header='Content-Type: application/json' --header='Authorization: Bearer $token' --post-file=$containerPath http://${collectorName}:4318/v1/traces || true; i=`$((i+1)); done"
    Invoke-Docker @("exec", $clientId, "sh", "-ec", $command) "Could not run bounded Collector queue pressure."
}

function Remove-ProofResources {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    foreach ($name in @($baselineName, $canaryName, $rollbackName, $clientName, $collectorName, $zipkinName)) {
        & docker rm -f $name 2>$null | Out-Null
    }
    & docker network rm $backendNetwork 2>$null | Out-Null
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    $ErrorActionPreference = $oldPreference
}

try {
    Remove-ProofResources
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $sourceResult = & docker inspect $SourceContainer 2>$null
    if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof requires running source container $SourceContainer for production-like env and secrets." }
    $source = ($sourceResult | ConvertFrom-Json)[0]
    if ([string]::IsNullOrWhiteSpace($ApiGatewayImage)) { $ApiGatewayImage = $source.Config.Image }
    & docker image inspect $ApiGatewayImage 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof image is unavailable: $ApiGatewayImage" }
    foreach ($network in @("llm-council-app", "llm-council-data", "llm-council-observability", "llm-council-platform", $ingestNetwork)) {
        & docker network inspect $network 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof requires existing network $network." }
    }

    New-ApiContainer $baselineName $false
    Invoke-Docker @("start", $baselineName) "Could not start telemetry-disabled baseline API Gateway."
    Wait-ApiHealth $baselineName
    $baselineP95 = Measure-HealthSamples $baselineName $SampleCount
    Invoke-Docker @("rm", "-f", $baselineName) "Could not remove baseline API Gateway."

    Invoke-Docker @("network", "create", "-d", "bridge", $backendNetwork) "Could not create isolated comparison-backend network."
    Invoke-Docker @("run", "-d", "--name", $zipkinName, "--network", $backendNetwork, "--network-alias", "zipkin", $zipkinImage) "Could not start isolated comparison backend."
    Invoke-Docker @("run", "-d", "--name", $collectorName, "--network", $ingestNetwork, "--tmpfs", "/var/lib/otelcol:rw,noexec,nosuid,size=96m,mode=1777", "-e", "OTELCOL_INGEST_TOKEN=$token", "--mount", "type=bind,source=$proofConfig,target=/etc/otelcol/config.yaml,readonly", $collectorImage, "--config=/etc/otelcol/config.yaml") "Could not start disposable proof Collector."
    Invoke-Docker @("network", "connect", $backendNetwork, $collectorName) "Could not connect Collector to isolated comparison backend."
    Start-Sleep -Seconds 3
    Assert-Running $collectorName "Collector"

    Invoke-Docker @("run", "-d", "--name", $clientName, "--network", $ingestNetwork, "--entrypoint", "/bin/sh", $zipkinImage, "-c", "while true; do sleep 3600; done") "Could not start disposable OTLP proof client."
    $clientId = (& docker ps -q --filter "name=^/${clientName}$").Trim()
    if ([string]::IsNullOrWhiteSpace($clientId)) { throw "C3.2A edge proof failed: proof client was not created." }

    New-ApiContainer $canaryName $true
    Invoke-Docker @("start", $canaryName) "Could not start Collector-enabled API Gateway canary."
    Wait-ApiHealth $canaryName

    $continuityTrace = "0123456789abcdef0123456789abcdef"
    $continuityParent = "fedcba9876543210"
    Invoke-Docker @("exec", $canaryName, "wget", "-q", "-T", "5", "-O", "/dev/null", "--header=traceparent: 00-$continuityTrace-$continuityParent-01", "http://localhost:8080/actuator/health") "Trace-continuity health request failed."
    Start-Sleep -Seconds 7
    $continuityLogs = (& docker logs $collectorName 2>&1 | Out-String).ToLowerInvariant()
    Assert-Contains $continuityLogs $continuityTrace "propagated trace ID"
    Assert-Contains $continuityLogs $continuityParent "propagated parent span ID"
    Assert-Contains $continuityLogs "http get /actuator/health" "real API Gateway health span"

    $canaryP95 = Measure-HealthSamples $canaryName $SampleCount
    $canaryLimit = [Math]::Max($baselineP95 + 25.0, $baselineP95 * 1.5)
    if ($canaryP95 -gt $canaryLimit) { throw "C3.2A edge proof failed: canary p95 $canaryP95 ms exceeded $canaryLimit ms." }

    Send-Payload (New-EdgePayload "bp175-edge-allowed") "allowed"
    Send-Payload (New-EdgePayload "bp175-edge-unknown-field" -ExtraAttribute "unregistered.field" -ExtraValue "bp175-unknown-value") "unknown-field"
    Send-Payload (New-EdgePayload "bp175-edge-raw-url" -ExtraAttribute "http.url" -ExtraValue "https://edge.invalid/private?token=bp175-raw-url-value") "raw-url"
    Send-Payload (New-EdgePayload "bp175-edge-prohibited" -ExtraAttribute "http.request.header.authorization" -ExtraValue "Bearer bp175-forbidden-value") "prohibited"
    Send-Payload (New-EdgePayload "bp175-edge-body" -ExtraAttribute "http.request.body" -ExtraValue "bp175-body-value") "body"
    Send-Payload (New-EdgePayload "bp175-edge-untrusted" -ServiceName "untrusted-edge-service") "untrusted"
    Send-Payload (New-EdgePayload "bp175-edge-unknown-span" -SpanName "http get /unregistered") "unknown-span"
    Send-Payload (New-EdgePayload "bp175-edge-event" -WithEvent) "event"
    Send-Payload (New-EdgePayload "bp175-edge-link" -WithLink) "link"
    Start-Sleep -Seconds 5

    Invoke-Docker @("stop", $zipkinName) "Could not stop isolated comparison backend."
    Send-Pressure (New-EdgePayload "bp175-edge-queue-pressure")
    Start-Sleep -Seconds 8
    Assert-Running $collectorName "Collector under bounded backend outage"
    & docker exec $canaryName wget -q -T 5 -O /dev/null http://localhost:8080/actuator/health 2>$null
    if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof failed: API Gateway health failed during exporter saturation." }
    Invoke-Docker @("start", $zipkinName) "Could not restart isolated comparison backend."
    Start-Sleep -Seconds 10
    Assert-Running $collectorName "Collector after comparison-backend recovery"

    $metrics = (& docker exec $clientId wget -qO- http://${collectorName}:8888/metrics 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof failed: Collector self-metrics were unavailable." }
    Assert-Contains $metrics "otelcol_receiver_accepted_spans" "accepted-span signal"
    Assert-Contains $metrics "otelcol_processor_filter" "filtered-span signal"
    Assert-Contains $metrics "otelcol_exporter_queue" "exporter queue signal"

    Invoke-Docker @("stop", $collectorName) "Could not stop Collector for API exporter outage proof."
    $outageP95 = Measure-HealthSamples $canaryName $SampleCount
    $outageLimit = [Math]::Max($baselineP95 + 75.0, $baselineP95 * 2.0)
    if ($outageP95 -gt $outageLimit) { throw "C3.2A edge proof failed: outage p95 $outageP95 ms exceeded $outageLimit ms." }
    Invoke-Docker @("start", $collectorName) "Could not restart Collector after API exporter outage."
    Wait-StablyRunning $collectorName "Collector after exporter recovery"
    & docker exec $canaryName wget -q -T 5 -O /dev/null http://localhost:8080/actuator/health 2>$null
    if ($LASTEXITCODE -ne 0) { throw "C3.2A edge proof failed: API Gateway health failed after Collector recovery." }
    Start-Sleep -Seconds 7

    $collectorLogs = (& docker logs $collectorName 2>&1 | Out-String)
    Assert-Contains $collectorLogs "bp175-edge-allowed" "allowed edge trace"
    Assert-Contains $collectorLogs "bp175-edge-unknown-field" "unknown-field trace after stripping"
    Assert-Contains $collectorLogs "bp175-edge-raw-url" "raw-URL trace after stripping"
    Assert-Contains $collectorLogs "service.namespace" "trusted namespace stamp"
    Assert-Contains $collectorLogs "llm_council.telemetry_gateway" "trusted gateway stamp"
    Assert-NotContains $collectorLogs "bp175-unknown-value" "unknown attribute value"
    Assert-NotContains $collectorLogs "bp175-raw-url-value" "raw URL/query value"
    Assert-NotContains $collectorLogs "bp175-forbidden-value" "authorization value"
    Assert-NotContains $collectorLogs "bp175-body-value" "body value"
    Assert-NotContains $collectorLogs "bp175-event-value" "event value"
    Assert-NotContains $collectorLogs "bp175-link-value" "link value"
    foreach ($droppedMarker in @("bp175-edge-prohibited", "bp175-edge-body", "bp175-edge-untrusted", "bp175-edge-unknown-span", "bp175-edge-event", "bp175-edge-link")) {
        Assert-NotContains $collectorLogs $droppedMarker "dropped negative-canary marker $droppedMarker"
    }
    if ($collectorLogs -match '(?m)^\s*->\s*(http\.url|exception|spring\.security)') {
        throw "C3.2A edge proof failed: an unregistered real SDK attribute reached the proof sink."
    }
    if ($collectorLogs -notmatch '(?i)(retry|queue is full|sending_queue)') {
        throw "C3.2A edge proof failed: bounded retry/queue-pressure signal was absent."
    }

    Invoke-Docker @("rm", "-f", $canaryName) "Could not remove API Gateway canary for rollback."
    New-ApiContainer $rollbackName $false
    Invoke-Docker @("start", $rollbackName) "Could not start rollback API Gateway."
    Wait-ApiHealth $rollbackName
    $rollbackP95 = Measure-HealthSamples $rollbackName 10
    $rollbackNetworks = (& docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $rollbackName).Trim()
    if ($rollbackNetworks.Contains($ingestNetwork)) { throw "C3.2A edge proof failed: rollback API Gateway remained on Collector ingress." }

    Remove-ProofResources
    foreach ($name in @($baselineName, $canaryName, $rollbackName, $clientName, $collectorName, $zipkinName)) {
        $remaining = (& docker ps -aq --filter "name=^/${name}$" | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($remaining)) { throw "C3.2A edge proof failed: cleanup left container $name." }
    }
    & docker network inspect $backendNetwork 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "C3.2A edge proof failed: cleanup left network $backendNetwork." }
    if (Test-Path -LiteralPath $tempRoot) { throw "C3.2A edge proof failed: cleanup left generated files." }
    $cleanupComplete = $true

    Write-Host ("BP1.75 C3.2A edge proof passed: image={0}; samples={1}; p95-ms baseline={2:N1}, canary={3:N1}, outage={4:N1}, rollback={5:N1}; authenticated real-span continuity, closed registry, privacy negatives, bounded saturation, recovery, rollback, and cleanup succeeded." -f $ApiGatewayImage, $SampleCount, $baselineP95, $canaryP95, $outageP95, $rollbackP95)
}
catch {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $diagnostic = (& docker logs --tail 120 $collectorName 2>&1 | Select-String -Pattern '(?i)error|fatal|queue|storage|retry' | Out-String)
    $ErrorActionPreference = $oldPreference
    if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
        $diagnostic = $diagnostic.Replace($token, '<redacted-token>')
        Write-Warning ("Sanitized Collector diagnostics:`n" + $diagnostic.Trim())
    }
    throw
}
finally {
    if (-not $cleanupComplete) { Remove-ProofResources }
}