[CmdletBinding()]
param(
    [string]$InfraRoot,
    [string]$GeminiSourceContainer = "llm-council-standard-gemini-service-1",
    [string]$GptSourceContainer = "llm-council-standard-gpt-service-1",
    [string]$LocalAiSourceContainer = "llm-council-standard-local-ai-service-1",
    [string]$GeminiImage,
    [string]$GptImage,
    [string]$LocalAiImage,
    [ValidateRange(5, 30)]
    [int]$SampleCount = 5,
    [ValidateRange(24, 240)]
    [int]$PressureCount = 64
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($InfraRoot)) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the BP1.75 C3.2B worker proof."
}

$prefix = "bp175-c32b-worker-proof"
$collectorName = "$prefix-collector"
$zipkinName = "$prefix-zipkin"
$clientName = "$prefix-client"
$backendNetwork = "$prefix-backend"
$ingestNetwork = "llm-council-otel-ingest"
$messagingNetwork = "llm-council-messaging"
$platformNetwork = "llm-council-platform"
$kafkaName = "llm-council-standard-kafka-1"
$collectorImage = "otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6"
$zipkinImage = "ghcr.io/openzipkin-contrib/zipkin-otel:0.3.0@sha256:097c7d44b1481857fa7ce8ce4dc6548fec672a48bc23901d6bff9ae0f15dc56d"
$proofConfig = (Resolve-Path (Join-Path $InfraRoot "projects\observability\otelcol\collector-proof.yaml")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("$prefix-" + [guid]::NewGuid().ToString("N"))
$token = "$prefix-" + [guid]::NewGuid().ToString("N")
$createdContainers = [System.Collections.Generic.List[string]]::new()
$sourceStates = @{}
$sourceDetails = @{}
$cleanupComplete = $false

$workers = @(
    [pscustomobject]@{
        Key = "gemini"; Service = "gemini-service"; Source = $GeminiSourceContainer
        Image = $GeminiImage; Port = 8082
        RequestTopic = "gemini.search.requests"; ReplyTopic = "gemini.search.replies"
        DlqTopic = "gemini.search.requests.dlq"
        ProcessSpan = "gemini.search.requests process"
        ReplySpan = "gemini.search.replies send"
        DlqSpan = "gemini.search.requests.dlq send"
    },
    [pscustomobject]@{
        Key = "gpt"; Service = "gpt-service"; Source = $GptSourceContainer
        Image = $GptImage; Port = 8083
        RequestTopic = "gpt.analyze.requests"; ReplyTopic = "gpt.analyze.replies"
        DlqTopic = "gpt.analyze.requests.dlq"
        ProcessSpan = "gpt.analyze.requests process"
        ReplySpan = "gpt.analyze.replies send"
        DlqSpan = "gpt.analyze.requests.dlq send"
    },
    [pscustomobject]@{
        Key = "local-ai"; Service = "local-ai-service"; Source = $LocalAiSourceContainer
        Image = $LocalAiImage; Port = 8086
        RequestTopic = "local-ai.requests"; ReplyTopic = "local-ai.replies"
        DlqTopic = "local-ai.requests.dlq"
        ProcessSpan = "local-ai.requests process"
        ReplySpan = "local-ai.replies send"
        DlqSpan = "local-ai.requests.dlq send"
    }
)

function Invoke-Docker {
    param([string[]]$Arguments, [string]$FailureMessage)
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
    return $output
}

function Assert-Contains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if (-not $Content.Contains($Needle)) {
        throw "C3.2B worker proof failed: expected $Name was absent."
    }
}

function Assert-NotContains {
    param([string]$Content, [string]$Needle, [string]$Name)
    if ($Content.Contains($Needle)) {
        throw "C3.2B worker proof failed: prohibited $Name was present."
    }
}

function Assert-Running {
    param([string]$ContainerName, [string]$Name)
    $state = (& docker inspect --format '{{.State.Running}}' $ContainerName 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $state -ne "true") {
        throw "C3.2B worker proof failed: $Name is not running."
    }
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
    throw "C3.2B worker proof failed: $Name did not remain running for five seconds."
}

function Get-CloneName {
    param([string]$Stage, [string]$Key)
    return "$prefix-$Stage-$Key"
}

function New-WorkerPayload {
    param([object]$Worker, [string]$CorrelationId)
    $contentCanary = "bp175-c32b-content-canary-do-not-export"
    switch ($Worker.Key) {
        "gemini" {
            return [ordered]@{
                correlationId = $CorrelationId; query = $contentCanary
                maxResults = 1; excludeUrls = @(); recommendedModel = $null
                standardizedPrompt = $null; groundingHint = "SEARCH"
                maxOutputTokens = $null; billingContext = $null
            }
        }
        "gpt" {
            return [ordered]@{
                correlationId = $CorrelationId; originalQuery = $contentCanary
                snippets = @(); mode = "GROUP_AND_CONTRADICT"
                recommendedModel = $null; standardizedPrompt = $null
                billingContext = $null
            }
        }
        "local-ai" {
            return [ordered]@{
                correlationId = $CorrelationId; prompt = $contentCanary
                mode = "PLAN"; maxVariants = 1; recommendedModel = $null
                standardizedPrompt = $null; billingContext = $null
            }
        }
        default { throw "Unknown worker key: $($Worker.Key)" }
    }
}

function Get-TopicOffsetSum {
    param([string]$Topic)
    $raw = & docker exec $kafkaName /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic $Topic 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read Kafka offsets for $Topic." }
    $sum = [long]0
    $matched = $false
    foreach ($line in @($raw)) {
        if ($line -match ':(?<offset>[0-9]+)$') {
            $sum += [long]$Matches.offset
            $matched = $true
        }
    }
    if (-not $matched) { return [long]0 }
    return $sum
}

function Wait-TopicIncrement {
    param([string]$Topic, [long]$Before, [string]$Name)
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $current = Get-TopicOffsetSum $Topic
        if ($current -gt $Before) { return $current }
        Start-Sleep -Milliseconds 200
    }
    throw "C3.2B worker proof failed: $Name did not increment $Topic."
}

function Send-WorkerRequest {
    param([object]$Worker, [string]$CorrelationId)
    $json = (New-WorkerPayload $Worker $CorrelationId) | ConvertTo-Json -Depth 8 -Compress
    $headers = "kafka_replyTopic:$($Worker.ReplyTopic),kafka_correlationId:$CorrelationId"
    $line = $headers + [char]9 + $json
    $producerArgs = @(
        "exec", "-i", $kafkaName,
        "/opt/kafka/bin/kafka-console-producer.sh",
        "--bootstrap-server", "localhost:9092",
        "--topic", $Worker.RequestTopic,
        "--property", "parse.headers=true"
    )
    $line | & docker @producerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Could not send synthetic request to $($Worker.RequestTopic)."
    }
}

function Measure-WorkerSet {
    param([string]$Stage, [int]$Count)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($worker in $workers) {
        $durations = [System.Collections.Generic.List[double]]::new()
        for ($index = 0; $index -lt $Count; $index++) {
            $before = Get-TopicOffsetSum $worker.ReplyTopic
            $correlation = "$prefix-$Stage-$($worker.Key)-$index-" + [guid]::NewGuid().ToString("N")
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Send-WorkerRequest $worker $correlation
            [void](Wait-TopicIncrement $worker.ReplyTopic $before "$Stage $($worker.Service) reply")
            $watch.Stop()
            $durations.Add($watch.Elapsed.TotalMilliseconds)
        }
        $ordered = @($durations | Sort-Object)
        $p95Index = [Math]::Min($ordered.Count - 1, [Math]::Ceiling($ordered.Count * 0.95) - 1)
        $results.Add([pscustomobject]@{
            Service = $worker.Service
            P95 = [double]$ordered[$p95Index]
            Count = $Count
        })
    }
    return @($results)
}

function Assert-Latency {
    param([object[]]$Baseline, [object[]]$Candidate, [double]$AdditiveMs, [double]$Factor, [string]$Name)
    foreach ($base in $Baseline) {
        $actual = @($Candidate | Where-Object { $_.Service -eq $base.Service })[0]
        if ($null -eq $actual) {
            throw "C3.2B worker proof failed: $Name result missing for $($base.Service)."
        }
        $limit = [Math]::Max($base.P95 + $AdditiveMs, $base.P95 * $Factor)
        if ($actual.P95 -gt $limit) {
            throw "C3.2B worker proof failed: $Name p95 $($actual.P95) ms exceeded $limit ms for $($base.Service)."
        }
    }
}

function New-WorkerSet {
    param([string]$Stage, [bool]$CollectorEnabled)
    foreach ($worker in $workers) {
        $name = Get-CloneName $Stage $worker.Key
        $collision = (& docker ps -aq --filter "name=^/$name$" | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($collision)) {
            throw "C3.2B worker proof refuses to replace existing container $name."
        }
    }

    foreach ($worker in $workers) {
        $name = Get-CloneName $Stage $worker.Key
        $source = $sourceDetails[$worker.Key]
        $overrides = @{
            GEMINI_API_KEY = ""
            OPENAI_API_KEY = ""
            OLLAMA_BASE_URL = ""
            LOCAL_AI_HEARTBEAT_ENABLED = "false"
            EUREKA_CLIENT_ENABLED = "false"
            OTEL_SERVICE_NAME = $worker.Service
        }
        if ($CollectorEnabled) {
            $overrides["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
            $overrides["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://$($collectorName):4318"
            $overrides["OTEL_EXPORTER_OTLP_HEADERS"] = "Authorization=Bearer $token"
            $overrides["MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_HEADERS_AUTHORIZATION"] = "Bearer $token"
            $overrides["MANAGEMENT_OTLP_TRACING_HEADERS_AUTHORIZATION"] = "Bearer $token"
            $overrides["MANAGEMENT_TRACING_EXPORT_OTLP_ENABLED"] = "true"
        } else {
            $overrides["MANAGEMENT_TRACING_EXPORT_OTLP_ENABLED"] = "false"
            $overrides["MANAGEMENT_OTLP_TRACING_EXPORT_ENABLED"] = "false"
        }

        $arguments = @("create", "--name", $name, "--network", $messagingNetwork)
        foreach ($entry in $source.Config.Env) {
            $key = $entry.Split("=", 2)[0]
            if (-not $overrides.ContainsKey($key)) { $arguments += @("-e", $entry) }
        }
        foreach ($key in $overrides.Keys) {
            $arguments += @("-e", "$key=$($overrides[$key])")
        }
        $arguments += $worker.Image
        Invoke-Docker $arguments "Could not create $name from exact worker image." | Out-Null
        $createdContainers.Add($name)
        Invoke-Docker @("network", "connect", $platformNetwork, $name) "Could not attach $name to $platformNetwork." | Out-Null
        if ($CollectorEnabled) {
            Invoke-Docker @("network", "connect", $ingestNetwork, $name) "Could not attach $name to private Collector ingress." | Out-Null
        }
        Invoke-Docker @("start", $name) "Could not start $name." | Out-Null
    }
}

function Wait-WorkerSet {
    param([string]$Stage)
    $ready = @{}
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        foreach ($worker in $workers) {
            $name = Get-CloneName $Stage $worker.Key
            if ($ready[$name]) { continue }
            & docker exec $name wget -q -T 2 -O /dev/null "http://localhost:$($worker.Port)/actuator/health" 2>$null
            if ($LASTEXITCODE -eq 0) { $ready[$name] = $true }
        }
        if ($ready.Count -eq $workers.Count) { return }
        Start-Sleep -Seconds 2
    }
    $missing = @($workers | ForEach-Object { Get-CloneName $Stage $_.Key } | Where-Object { -not $ready[$_] })
    throw "C3.2B worker proof failed: clones did not become healthy: $($missing -join ', ')."
}

function Remove-WorkerSet {
    param([string]$Stage)
    foreach ($worker in $workers) {
        $name = Get-CloneName $Stage $worker.Key
        & docker rm -f $name 2>$null | Out-Null
        [void]$createdContainers.Remove($name)
    }
}

function Send-MalformedRequests {
    foreach ($worker in $workers) {
        $before = Get-TopicOffsetSum $worker.DlqTopic
        $producerArgs = @(
            "exec", "-i", $kafkaName,
            "/opt/kafka/bin/kafka-console-producer.sh",
            "--bootstrap-server", "localhost:9092",
            "--topic", $worker.RequestTopic
        )
        '{"correlationId":"bp175-c32b-invalid-content-canary"' | & docker @producerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Could not send malformed synthetic request to $($worker.RequestTopic)."
        }
        [void](Wait-TopicIncrement $worker.DlqTopic $before "$($worker.Service) DLQ")
    }
}

function New-Resource {
    param([string]$ServiceName)
    return @{
        attributes = @(
            @{ key = "service.name"; value = @{ stringValue = $ServiceName } },
            @{ key = "service.version"; value = @{ stringValue = "c32b-proof" } },
            @{ key = "unregistered.resource"; value = @{ stringValue = "bp175-resource-value" } }
        )
    }
}

function New-KafkaPayload {
    param(
        [string]$Marker,
        [string]$ServiceName = "gemini-service",
        [string]$SpanName = "gemini.search.requests process",
        [int]$Kind = 5,
        [string]$Operation = "process",
        [string]$SourceName = "gemini.search.requests",
        [string]$DestinationName = "",
        [string]$ExtraAttribute = "",
        [string]$ExtraValue = "",
        [switch]$WithEvent,
        [switch]$WithLink
    )
    $attributes = @(
        @{ key = "messaging.system"; value = @{ stringValue = "kafka" } },
        @{ key = "messaging.operation"; value = @{ stringValue = $Operation } },
        @{ key = "llm_council.telemetry.test_marker"; value = @{ stringValue = $Marker } }
    )
    if (-not [string]::IsNullOrWhiteSpace($SourceName)) {
        $attributes += @{ key = "messaging.source.kind"; value = @{ stringValue = "topic" } }
        $attributes += @{ key = "messaging.source.name"; value = @{ stringValue = $SourceName } }
    }
    if (-not [string]::IsNullOrWhiteSpace($DestinationName)) {
        $attributes += @{ key = "messaging.destination.kind"; value = @{ stringValue = "topic" } }
        $attributes += @{ key = "messaging.destination.name"; value = @{ stringValue = $DestinationName } }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExtraAttribute)) {
        $attributes += @{ key = $ExtraAttribute; value = @{ stringValue = $ExtraValue } }
    }

    $nowNanos = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
    $span = @{
        traceId = [guid]::NewGuid().ToString("N")
        spanId = [guid]::NewGuid().ToString("N").Substring(0, 16)
        name = $SpanName
        kind = $Kind
        startTimeUnixNano = $nowNanos
        endTimeUnixNano = $nowNanos
        attributes = $attributes
    }
    if ($WithEvent) {
        $span.events = @(@{
            timeUnixNano = $nowNanos
            name = "bp175-event"
            attributes = @(@{ key = "event.value"; value = @{ stringValue = "bp175-event-value" } })
        })
    }
    if ($WithLink) {
        $span.links = @(@{
            traceId = [guid]::NewGuid().ToString("N")
            spanId = [guid]::NewGuid().ToString("N").Substring(0, 16)
            attributes = @(@{ key = "link.value"; value = @{ stringValue = "bp175-link-value" } })
        })
    }
    return @{
        resourceSpans = @(@{
            resource = New-Resource $ServiceName
            scopeSpans = @(@{
                scope = @{ name = "bp175-c32b-proof" }
                spans = @($span)
            })
        })
    }
}

function Write-ClientPayload {
    param([hashtable]$Payload, [string]$Name)
    $localPath = Join-Path $tempRoot "$Name.json"
    $containerPath = "/tmp/$Name.json"
    [System.IO.File]::WriteAllText(
        $localPath,
        ($Payload | ConvertTo-Json -Depth 14),
        [System.Text.UTF8Encoding]::new($false))
    Invoke-Docker @("cp", $localPath, "$($clientName):$containerPath") "Could not copy $Name into proof client." | Out-Null
    return $containerPath
}

function Send-Payload {
    param([hashtable]$Payload, [string]$Name)
    $containerPath = Write-ClientPayload $Payload $Name
    Invoke-Docker @(
        "exec", $clientName, "wget", "-q", "-O", "/dev/null",
        "--header=Content-Type: application/json",
        "--header=Authorization: Bearer $token",
        "--post-file=$containerPath",
        "http://$($collectorName):4318/v1/traces"
    ) "Collector rejected authenticated payload $Name." | Out-Null
}

function Send-Pressure {
    param([hashtable]$Payload)
    $containerPath = Write-ClientPayload $Payload "queue-pressure"
    $command = ('i=0; while [ $i -lt {0} ]; do wget -q -O /dev/null --header="Content-Type: application/json" --header="Authorization: Bearer {1}" --post-file={2} http://{3}:4318/v1/traces || true; i=$((i+1)); done' -f $PressureCount, $token, $containerPath, $collectorName)
    Invoke-Docker @("exec", $clientName, "sh", "-ec", $command) "Could not run bounded Collector queue pressure." | Out-Null
}

function Get-DebugSpans {
    param([string]$Logs)
    $result = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in ($Logs -split "\r?\n")) {
        if ($line -match '^\s*Span #[0-9]+') {
            if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($current["Name"])) {
                $result.Add([pscustomobject]$current)
            }
            $current = @{ TraceId = ""; ParentId = ""; SpanId = ""; Name = ""; Kind = "" }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*Trace ID\s*:\s*(?<value>\S+)') { $current["TraceId"] = $Matches.value; continue }
        if ($line -match '^\s*Parent ID\s*:\s*(?<value>\S*)') { $current["ParentId"] = $Matches.value; continue }
        if ($line -match '^\s*ID\s*:\s*(?<value>\S+)') { $current["SpanId"] = $Matches.value; continue }
        if ($line -match '^\s*Name\s*:\s*(?<value>.+)$') { $current["Name"] = $Matches.value.Trim(); continue }
        if ($line -match '^\s*Kind\s*:\s*(?<value>.+)$') { $current["Kind"] = $Matches.value.Trim(); continue }
    }
    if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($current["Name"])) {
        $result.Add([pscustomobject]$current)
    }
    return @($result)
}

function Assert-TraceContinuity {
    param([string]$CollectorLogs)
    $spans = Get-DebugSpans $CollectorLogs
    foreach ($worker in $workers) {
        $consumers = @($spans | Where-Object { $_.Name -eq $worker.ProcessSpan })
        $producers = @($spans | Where-Object { $_.Name -eq $worker.ReplySpan })
        $matched = $false
        foreach ($consumer in $consumers) {
            if ($producers | Where-Object {
                $_.TraceId -eq $consumer.TraceId -and
                $_.ParentId -eq $consumer.SpanId -and
                $_.Kind -eq "Producer"
            }) {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            throw "C3.2B worker proof failed: request/reply trace continuity was absent for $($worker.Service)."
        }
    }
}

function Start-ProofInfrastructure {
    Invoke-Docker @("network", "create", "-d", "bridge", $backendNetwork) "Could not create comparison backend network." | Out-Null
    Invoke-Docker @("run", "-d", "--name", $zipkinName, "--network", $backendNetwork, "--network-alias", "zipkin", $zipkinImage) "Could not start comparison backend." | Out-Null
    $createdContainers.Add($zipkinName)
    Invoke-Docker @(
        "run", "-d", "--name", $collectorName, "--network", $ingestNetwork,
        "--tmpfs", "/var/lib/otelcol:rw,noexec,nosuid,size=96m,mode=1777",
        "-e", "OTELCOL_INGEST_TOKEN=$token",
        "--mount", "type=bind,source=$proofConfig,target=/etc/otelcol/config.yaml,readonly",
        $collectorImage, "--config=/etc/otelcol/config.yaml"
    ) "Could not start proof Collector." | Out-Null
    $createdContainers.Add($collectorName)
    Invoke-Docker @("network", "connect", $backendNetwork, $collectorName) "Could not connect Collector to comparison backend." | Out-Null
    Invoke-Docker @(
        "run", "-d", "--name", $clientName, "--network", $ingestNetwork,
        "--entrypoint", "/bin/sh", $zipkinImage, "-c", "while true; do sleep 3600; done"
    ) "Could not start OTLP proof client." | Out-Null
    $createdContainers.Add($clientName)
    Start-Sleep -Seconds 3
    Assert-Running $collectorName "Collector"
}

function Remove-ProofResources {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    foreach ($name in @($createdContainers.ToArray())) {
        & docker rm -f $name 2>$null | Out-Null
    }
    $createdContainers.Clear()
    & docker network rm $backendNetwork 2>$null | Out-Null
    foreach ($worker in $workers) {
        if ($sourceStates[$worker.Key] -eq "true") {
            & docker start $worker.Source 2>$null | Out-Null
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = [System.IO.Path]::GetFullPath($tempRoot)
        $allowed = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe proof cleanup target: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    $ErrorActionPreference = $oldPreference
}

try {
    foreach ($network in @($messagingNetwork, $platformNetwork, $ingestNetwork)) {
        & docker network inspect $network 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "C3.2B worker proof requires network $network." }
    }
    $kafkaHealth = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $kafkaName 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $kafkaHealth -ne "healthy") {
        throw "C3.2B worker proof requires healthy Kafka container $kafkaName."
    }

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    foreach ($worker in $workers) {
        $sourceResult = & docker inspect $worker.Source 2>$null
        if ($LASTEXITCODE -ne 0) { throw "C3.2B worker proof requires source container $($worker.Source)." }
        $source = ($sourceResult | ConvertFrom-Json)[0]
        $sourceDetails[$worker.Key] = $source
        $sourceStates[$worker.Key] = [string]$source.State.Running
        if ([string]::IsNullOrWhiteSpace($worker.Image)) { $worker.Image = $source.Config.Image }
        & docker image inspect $worker.Image 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "C3.2B worker proof image is unavailable: $($worker.Image)" }
    }

    foreach ($worker in $workers) {
        if ($sourceStates[$worker.Key] -eq "true") {
            Invoke-Docker @("stop", "--time", "10", $worker.Source) "Could not pause source worker $($worker.Source)." | Out-Null
        }
    }

    New-WorkerSet "baseline" $false
    Wait-WorkerSet "baseline"
    $baseline = Measure-WorkerSet "baseline" $SampleCount
    Remove-WorkerSet "baseline"

    Start-ProofInfrastructure
    New-WorkerSet "canary" $true
    Wait-WorkerSet "canary"
    $canary = Measure-WorkerSet "canary" $SampleCount
    Assert-Latency $baseline $canary 750.0 3.0 "canary"

    Send-MalformedRequests
    Send-Payload (New-KafkaPayload "bp175-worker-allowed") "allowed"
    Send-Payload (New-KafkaPayload "bp175-worker-unknown-field" -ExtraAttribute "unregistered.field" -ExtraValue "bp175-worker-unknown-value") "unknown-field"
    Send-Payload (New-KafkaPayload "bp175-worker-message-body" -ExtraAttribute "messaging.message.body" -ExtraValue "bp175-worker-body-value") "message-body"
    Send-Payload (New-KafkaPayload "bp175-worker-input" -ExtraAttribute "input.value" -ExtraValue "bp175-worker-input-value") "input-value"
    Send-Payload (New-KafkaPayload "bp175-worker-untrusted" -ServiceName "untrusted-worker") "untrusted"
    Send-Payload (New-KafkaPayload "bp175-worker-unknown-span" -SpanName "gemini.search.unknown process") "unknown-span"
    Send-Payload (New-KafkaPayload "bp175-worker-cross-service" -ServiceName "gpt-service") "cross-service"
    Send-Payload (New-KafkaPayload "bp175-worker-wrong-topic" -SourceName "gpt.analyze.requests") "wrong-topic"
    Send-Payload (New-KafkaPayload "bp175-worker-wrong-operation" -Operation "publish") "wrong-operation"
    Send-Payload (New-KafkaPayload "bp175-worker-wrong-kind" -Kind 4) "wrong-kind"
    Send-Payload (New-KafkaPayload "bp175-worker-event" -WithEvent) "event"
    Send-Payload (New-KafkaPayload "bp175-worker-link" -WithLink) "link"
    Start-Sleep -Seconds 7

    $initialLogs = (& docker logs $collectorName 2>&1 | Out-String)
    foreach ($worker in $workers) {
        Assert-Contains $initialLogs $worker.ProcessSpan "$($worker.Service) process span"
        Assert-Contains $initialLogs $worker.ReplySpan "$($worker.Service) reply span"
        Assert-Contains $initialLogs $worker.DlqSpan "$($worker.Service) DLQ span"
    }
    Assert-TraceContinuity $initialLogs
    Assert-NotContains $initialLogs "bp175-c32b-content-canary-do-not-export" "real worker message content"
    Assert-NotContains $initialLogs "bp175-c32b-invalid-content-canary" "malformed worker message content"

    Invoke-Docker @("stop", $zipkinName) "Could not stop comparison backend." | Out-Null
    Send-Pressure (New-KafkaPayload "bp175-worker-queue-pressure")
    $saturation = Measure-WorkerSet "saturation" 1
    Assert-Latency $baseline $saturation 1500.0 5.0 "comparison-backend saturation"
    Start-Sleep -Seconds 5
    Assert-Running $collectorName "Collector under comparison-backend outage"
    Invoke-Docker @("start", $zipkinName) "Could not restart comparison backend." | Out-Null
    Start-Sleep -Seconds 10

    $metrics = (& docker exec $clientName wget -qO- "http://$($collectorName):8888/metrics" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "C3.2B worker proof failed: Collector self-metrics were unavailable." }
    Assert-Contains $metrics "otelcol_receiver_accepted_spans" "accepted-span signal"
    Assert-Contains $metrics "otelcol_processor_filter" "filtered-span signal"
    Assert-Contains $metrics "otelcol_exporter_queue" "exporter queue signal"

    Invoke-Docker @("stop", $collectorName) "Could not stop Collector for exporter outage proof." | Out-Null
    $outage = Measure-WorkerSet "outage" $SampleCount
    Assert-Latency $baseline $outage 1500.0 5.0 "Collector outage"
    Invoke-Docker @("start", $collectorName) "Could not restart Collector." | Out-Null
    Wait-StablyRunning $collectorName "Collector after exporter recovery"
    $recovery = Measure-WorkerSet "recovery" 1
    Assert-Latency $baseline $recovery 1500.0 5.0 "Collector recovery"
    Start-Sleep -Seconds 7

    $collectorLogs = (& docker logs $collectorName 2>&1 | Out-String)
    Assert-Contains $collectorLogs "bp175-worker-allowed" "allowed worker trace"
    Assert-Contains $collectorLogs "bp175-worker-unknown-field" "unknown-field trace after stripping"
    Assert-Contains $collectorLogs "service.namespace" "trusted namespace stamp"
    Assert-Contains $collectorLogs "llm_council.telemetry_gateway" "trusted gateway stamp"
    Assert-NotContains $collectorLogs "bp175-worker-unknown-value" "unknown attribute value"
    Assert-NotContains $collectorLogs "bp175-worker-body-value" "message body value"
    Assert-NotContains $collectorLogs "bp175-worker-input-value" "input value"
    Assert-NotContains $collectorLogs "bp175-event-value" "event value"
    Assert-NotContains $collectorLogs "bp175-link-value" "link value"
    foreach ($droppedMarker in @(
        "bp175-worker-message-body", "bp175-worker-input", "bp175-worker-untrusted",
        "bp175-worker-unknown-span", "bp175-worker-cross-service",
        "bp175-worker-wrong-topic", "bp175-worker-wrong-operation",
        "bp175-worker-wrong-kind", "bp175-worker-event", "bp175-worker-link"
    )) {
        Assert-NotContains $collectorLogs $droppedMarker "dropped negative-canary marker $droppedMarker"
    }
    if ($collectorLogs -match '(?m)^\s*->\s*(messaging\.consumer\.id|messaging\.kafka\.|peer\.service|spring\.kafka\.|exception)') {
        throw "C3.2B worker proof failed: an unregistered Kafka SDK attribute reached the proof sink."
    }
    if ($collectorLogs -notmatch '(?i)(retry|queue is full|sending_queue)') {
        throw "C3.2B worker proof failed: bounded retry/queue-pressure signal was absent."
    }

    Remove-WorkerSet "canary"
    New-WorkerSet "rollback" $false
    Wait-WorkerSet "rollback"
    $rollback = Measure-WorkerSet "rollback" 3
    Assert-Latency $baseline $rollback 750.0 3.0 "rollback"
    foreach ($worker in $workers) {
        $name = Get-CloneName "rollback" $worker.Key
        $networks = (& docker inspect --format '{{range $key,$value := .NetworkSettings.Networks}}{{$key}} {{end}}' $name | Out-String).Trim()
        if ($networks.Contains($ingestNetwork)) {
            throw "C3.2B worker proof failed: rollback worker $name remained on Collector ingress."
        }
    }
    Remove-WorkerSet "rollback"

    Remove-ProofResources
    foreach ($worker in $workers) {
        foreach ($stage in @("baseline", "canary", "rollback")) {
            $name = Get-CloneName $stage $worker.Key
            $remaining = (& docker ps -aq --filter "name=^/$name$" | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($remaining)) {
                throw "C3.2B worker proof failed: cleanup left container $name."
            }
        }
    }
    foreach ($name in @($collectorName, $zipkinName, $clientName)) {
        $remaining = (& docker ps -aq --filter "name=^/$name$" | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($remaining)) {
            throw "C3.2B worker proof failed: cleanup left container $name."
        }
    }
    & docker network inspect $backendNetwork 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "C3.2B worker proof failed: cleanup left network $backendNetwork." }
    if (Test-Path -LiteralPath $tempRoot) { throw "C3.2B worker proof failed: cleanup left generated files." }
    $cleanupComplete = $true

    $summary = @()
    foreach ($worker in $workers) {
        $base = @($baseline | Where-Object { $_.Service -eq $worker.Service })[0]
        $can = @($canary | Where-Object { $_.Service -eq $worker.Service })[0]
        $down = @($outage | Where-Object { $_.Service -eq $worker.Service })[0]
        $back = @($rollback | Where-Object { $_.Service -eq $worker.Service })[0]
        $summary += "$($worker.Service):baseline=$([Math]::Round($base.P95,1)),canary=$([Math]::Round($can.P95,1)),outage=$([Math]::Round($down.P95,1)),rollback=$([Math]::Round($back.P95,1))"
    }
    Write-Host ("BP1.75 C3.2B worker proof passed: images={0}; samples={1}; p95-ms [{2}]; credential-free request/reply and DLQ flows, trace continuity, closed registry, privacy negatives, bounded saturation, outage/recovery, per-worker rollback, and cleanup succeeded." -f (($workers | ForEach-Object { $_.Image }) -join ","), $SampleCount, ($summary -join "; "))
}
catch {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $diagnostic = (& docker logs --tail 120 $collectorName 2>&1 | Select-String -Pattern '(?i)error|fatal|queue|storage|retry' | Out-String)
    $ErrorActionPreference = $oldPreference
    if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
        $diagnostic = $diagnostic.Replace($token, "<redacted-token>")
        Write-Warning ("Sanitized Collector diagnostics:" + [Environment]::NewLine + $diagnostic.Trim())
    }
    throw
}
finally {
    if (-not $cleanupComplete) { Remove-ProofResources }
}
