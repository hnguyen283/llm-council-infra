[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$BackendRoot,
    [string]$InfraRoot
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredRoot {
    param([string]$ExplicitRoot, [string]$EnvironmentVariable, [string]$FallbackRoot)
    $candidate = $ExplicitRoot
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $FallbackRoot }
    return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
}

function Require-Text {
    param([string]$Content, [string]$Expected, [string]$Name)
    if (-not $Content.Contains($Expected)) {
        throw "BP1.75 Collector check failed: missing $Name ($Expected)"
    }
}

function Reject-Text {
    param([string]$Content, [string]$Forbidden, [string]$Name)
    if ($Content.Contains($Forbidden)) {
        throw "BP1.75 Collector check failed: forbidden $Name ($Forbidden)"
    }
}

function Assert-SetEqual {
    param([string[]]$Actual, [string[]]$Expected, [string]$Name)
    $actualSet = @($Actual | Sort-Object -Unique)
    $expectedSet = @($Expected | Sort-Object -Unique)
    if (($actualSet -join "`n") -ne ($expectedSet -join "`n")) {
        throw "BP1.75 Collector check failed: $Name mismatch. Actual=[$($actualSet -join ', ')] Expected=[$($expectedSet -join ', ')]"
    }
}

function Get-TopLevelYamlList {
    param([string]$Content, [string]$Section)
    $match = [regex]::Match($Content, "(?ms)^$([regex]::Escape($Section)):\s*`n(?<body>.*?)(?=^[A-Za-z][A-Za-z0-9]*:|\z)")
    if (-not $match.Success) { throw "BP1.75 Collector check failed: registry section $Section is missing." }
    return @([regex]::Matches($match.Groups['body'].Value, '(?m)^  - (?<value>[^\r\n]+)$') | ForEach-Object { $_.Groups['value'].Value.Trim() })
}

function Get-RegistryAttributeKeys {
    param([string]$Content)
    $match = [regex]::Match($Content, '(?ms)^allowedSpanAttributes:\s*\n(?<body>.*?)(?=^[A-Za-z][A-Za-z0-9]*:|\z)')
    if (-not $match.Success) { throw 'BP1.75 Collector check failed: allowedSpanAttributes is missing.' }
    return @([regex]::Matches($match.Groups['body'].Value, '(?m)^  - key: (?<value>[^\r\n]+)$') | ForEach-Object { $_.Groups['value'].Value.Trim() })
}

function Get-QuotedValues {
    param([string]$Content)
    return @([regex]::Matches($Content, '"(?<value>[^"]+)"') | ForEach-Object { $_.Groups['value'].Value })
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
$infraRoot = Resolve-RequiredRoot $InfraRoot "BP175_INFRA_ROOT" (Join-Path $WorkspaceRoot "llm-council-infra")
$backendRoot = Resolve-RequiredRoot $BackendRoot "BP175_BACKEND_ROOT" (Join-Path $WorkspaceRoot "llm-council")

$actualConfigPath = Join-Path $infraRoot "projects\observability\otelcol\collector-canary.yaml"
$proofConfigPath = Join-Path $infraRoot "projects\observability\otelcol\collector-proof.yaml"
$composePath = Join-Path $infraRoot "projects\observability\docker-compose.yml"
$graphPath = Join-Path $infraRoot "projects\graphrag\docker-compose.yml"
$coreOverlayPath = Join-Path $infraRoot "projects\core\overlays\collector-canary.yml"
$optionPath = Join-Path $infraRoot "options\prod-full-local-observability-collector-canary\option.env"
$composeFilesPath = Join-Path $infraRoot "options\prod-full-local-observability-collector-canary\compose.files"
$manualRegistryPath = Join-Path $backendRoot "docs\architecture\observation-envelope-v1.yaml"
$httpRegistryPath = Join-Path $backendRoot "docs\architecture\standard-sdk-http-telemetry-v1.yaml"
$kafkaRegistryPath = Join-Path $backendRoot "docs\architecture\standard-sdk-kafka-telemetry-v1.yaml"
$backendDockerConfigPath = Join-Path $backendRoot "config-repo\application-docker.yml"

foreach ($requiredPath in @($actualConfigPath, $proofConfigPath, $composePath, $graphPath, $coreOverlayPath, $optionPath, $composeFilesPath, $manualRegistryPath, $httpRegistryPath, $kafkaRegistryPath, $backendDockerConfigPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "BP1.75 Collector check failed: required path is missing: $requiredPath"
    }
}

$actual = Get-Content -LiteralPath $actualConfigPath -Raw
$proof = Get-Content -LiteralPath $proofConfigPath -Raw
$compose = Get-Content -LiteralPath $composePath -Raw
$graph = Get-Content -LiteralPath $graphPath -Raw
$coreOverlay = Get-Content -LiteralPath $coreOverlayPath -Raw
$option = Get-Content -LiteralPath $optionPath -Raw
$composeFiles = Get-Content -LiteralPath $composeFilesPath -Raw
$manualRegistry = Get-Content -LiteralPath $manualRegistryPath -Raw
$httpRegistry = Get-Content -LiteralPath $httpRegistryPath -Raw
$kafkaRegistry = Get-Content -LiteralPath $kafkaRegistryPath -Raw
$backendDockerConfig = Get-Content -LiteralPath $backendDockerConfigPath -Raw

Require-Text $manualRegistry 'schemaVersion: llm-council.observation-envelope/v1' 'unchanged manual registry schema'
Reject-Text $manualRegistry 'standard-sdk-http-telemetry' 'SDK fields in the manual registry'
Require-Text $httpRegistry 'schemaVersion: llm-council.standard-sdk-http-telemetry/v1' 'SDK HTTP registry schema'
Require-Text $httpRegistry 'status: bp175-c32a-edge-canary' 'SDK HTTP registry status'
Require-Text $kafkaRegistry 'schemaVersion: llm-council.standard-sdk-kafka-telemetry/v1' 'SDK Kafka registry schema'
Require-Text $kafkaRegistry 'status: bp175-c32b-provider-worker-canary' 'SDK Kafka registry status'

$httpServices = Get-TopLevelYamlList $httpRegistry 'allowedServiceNames'
$httpSpanNames = Get-TopLevelYamlList $httpRegistry 'allowedSpanNames'
$httpSpanKinds = Get-TopLevelYamlList $httpRegistry 'allowedSpanKinds'
$httpResourceAttributes = Get-TopLevelYamlList $httpRegistry 'allowedResourceAttributeNames'
$httpSpanAttributes = Get-RegistryAttributeKeys $httpRegistry
$httpProofAttributes = Get-TopLevelYamlList $httpRegistry 'proofOnlyAttributeNames'
$httpProhibitedAttributes = Get-TopLevelYamlList $httpRegistry 'prohibitedAttributeNames'
$kafkaServices = Get-TopLevelYamlList $kafkaRegistry 'allowedServiceNames'
$kafkaSpanNames = Get-TopLevelYamlList $kafkaRegistry 'allowedSpanNames'
$kafkaSpanKinds = Get-TopLevelYamlList $kafkaRegistry 'allowedSpanKinds'
$kafkaResourceAttributes = Get-TopLevelYamlList $kafkaRegistry 'allowedResourceAttributeNames'
$kafkaSpanAttributes = Get-RegistryAttributeKeys $kafkaRegistry
$kafkaProofAttributes = Get-TopLevelYamlList $kafkaRegistry 'proofOnlyAttributeNames'
$kafkaProhibitedAttributes = Get-TopLevelYamlList $kafkaRegistry 'prohibitedAttributeNames'
Assert-SetEqual $httpServices @('api-gateway') 'SDK service registry'
Assert-SetEqual $httpSpanNames @('http get /actuator/health') 'SDK span-name registry'
Assert-SetEqual $httpSpanKinds @('SPAN_KIND_SERVER') 'SDK span-kind registry'
Assert-SetEqual $httpResourceAttributes @('service.name', 'service.version') 'SDK resource registry'
Assert-SetEqual $httpSpanAttributes @('method', 'outcome', 'status', 'uri') 'SDK span-attribute registry'
Assert-SetEqual $httpProofAttributes @('llm_council.telemetry.test_marker') 'SDK proof-only registry'
Assert-SetEqual $kafkaServices @('gemini-service', 'gpt-service', 'local-ai-service') 'SDK Kafka service registry'
Assert-SetEqual $kafkaSpanNames @('gemini.search.requests process', 'gemini.search.replies send', 'gemini.search.requests.dlq send', 'gpt.analyze.requests process', 'gpt.analyze.replies send', 'gpt.analyze.requests.dlq send', 'local-ai.requests process', 'local-ai.replies send', 'local-ai.requests.dlq send') 'SDK Kafka span-name registry'
Assert-SetEqual $kafkaSpanKinds @('SPAN_KIND_CONSUMER', 'SPAN_KIND_PRODUCER') 'SDK Kafka span-kind registry'
Assert-SetEqual $kafkaResourceAttributes @('service.name', 'service.version') 'SDK Kafka resource registry'
Assert-SetEqual $kafkaSpanAttributes @('messaging.system', 'messaging.operation', 'messaging.source.kind', 'messaging.source.name', 'messaging.destination.kind', 'messaging.destination.name') 'SDK Kafka span-attribute registry'
Assert-SetEqual $kafkaProofAttributes @('llm_council.telemetry.test_marker') 'SDK Kafka proof-only registry'

$expectedServices = @('graphrag-retrieval-service', 'orchestrator-service') + $httpServices + $kafkaServices
$expectedSpans = @('RetrievalPipeline', 'VectorSearch', 'GraphTraversal', 'GraphRagClient.executeLocalSearch', 'GraphRagClient.executeGlobalSearch') + $httpSpanNames + $kafkaSpanNames
foreach ($collectorConfig in @($actual, $proof)) {
    foreach ($required in @(
        'endpoint: 0.0.0.0:4317',
        'endpoint: 0.0.0.0:4318',
        'bearertokenauth/ingest:',
        'authenticator: bearertokenauth/ingest',
        'filter/allowlisted-services:',
        'filter/allowlisted-shape:',
        'filter/prohibited-fields:',
        'transform/attribute-registry:',
        'resource/trusted-stamp:',
        'probabilistic_sampler/canary:',
        'memory_limiter:',
        'otlp_http/zipkin-comparison:',
        'sending_queue:',
        'retry_on_failure:',
        'Len(events) > 0',
        'Len(links) > 0',
        'value: bp175-canary-v4'
    )) { Require-Text $collectorConfig $required 'Collector policy element' }

    $serviceLine = [regex]::Match($collectorConfig, '(?m)^\s*- resource\.attributes\["service\.name"\] != .+$').Value
    $serviceValues = @([regex]::Matches($serviceLine, 'service\.name"\] != "(?<value>[^"]+)"') | ForEach-Object { $_.Groups['value'].Value })
    Assert-SetEqual $serviceValues $expectedServices 'Collector service allow-list'

    $shapeLine = [regex]::Match($collectorConfig, '(?m)^\s*- name != "RetrievalPipeline".+$').Value
    $shapeValues = @([regex]::Matches($shapeLine, 'name != "(?<value>[^"]+)"') | ForEach-Object { $_.Groups['value'].Value })
    Assert-SetEqual $shapeValues $expectedSpans 'Collector span-name allow-list'

    foreach ($kind in $httpSpanKinds) { Require-Text $collectorConfig "kind != $kind" 'SDK span-kind gate' }
    foreach ($attribute in $httpProhibitedAttributes) { Require-Text $collectorConfig "attributes[`"$attribute`"] != nil" 'SDK prohibited-attribute gate' }
    foreach ($attribute in $kafkaProhibitedAttributes) { Require-Text $collectorConfig "attributes[`"$attribute`"] != nil" 'SDK Kafka prohibited-attribute gate' }
    foreach ($valueGate in @(
        'attributes["method"] != "GET"',
        'attributes["outcome"] != "SUCCESS"',
        'attributes["status"] != "200"',
        'attributes["uri"] != "/actuator/health"'
    )) { Require-Text $collectorConfig $valueGate 'closed SDK value gate' }

    $resourceKeep = [regex]::Match($collectorConfig, 'keep_keys\(attributes, \[(?<values>[^\]]+)\]\)\s*\r?\n\s*- context: span').Groups['values'].Value
    Assert-SetEqual (Get-QuotedValues $resourceKeep) $httpResourceAttributes 'Collector resource registry'
    $httpKeep = [regex]::Match($collectorConfig, 'keep_keys\(attributes, \[(?<values>[^\]]+)\]\) where resource\.attributes\["service\.name"\] == "api-gateway"').Groups['values'].Value
    if ([string]::IsNullOrWhiteSpace($httpKeep)) { throw 'BP1.75 Collector check failed: API Gateway attribute transform is missing.' }
    Assert-SetEqual (Get-QuotedValues $httpKeep) ($httpSpanAttributes + $httpProofAttributes) 'Collector SDK attribute registry'
    Reject-Text $httpKeep 'http.url' 'raw URL in retained SDK attributes'
    Reject-Text $httpKeep 'exception' 'exception data in retained SDK attributes'

    foreach ($service in $kafkaServices) {
        $escapedService = [regex]::Escape($service)
        $kafkaKeep = [regex]::Match($collectorConfig, "keep_keys\(attributes, \[(?<values>[^\]]+)\]\) where resource\.attributes\[`"service\.name`"\] == `"$escapedService`"").Groups['values'].Value
        if ([string]::IsNullOrWhiteSpace($kafkaKeep)) { throw "BP1.75 Collector check failed: $service Kafka attribute transform is missing." }
        Assert-SetEqual (Get-QuotedValues $kafkaKeep) ($kafkaSpanAttributes + $kafkaProofAttributes) "$service Kafka attribute registry"
    }
    foreach ($requiredKafkaGate in @(
        'attributes["messaging.system"] != "kafka"',
        'attributes["messaging.operation"] != "process"',
        'attributes["messaging.operation"] != "publish"',
        'attributes["messaging.source.kind"] != "topic"',
        'attributes["messaging.destination.kind"] != "topic"'
    )) { Require-Text $collectorConfig $requiredKafkaGate 'closed Kafka value gate' }
    foreach ($discarded in @('messaging.consumer.id', 'messaging.kafka.client_id', 'messaging.kafka.consumer.group', 'messaging.kafka.message.offset', 'messaging.kafka.source.partition', 'peer.service', 'spring.kafka.listener.id', 'spring.kafka.template.name')) {
        foreach ($service in $kafkaServices) {
            $workerKeep = [regex]::Match($collectorConfig, "keep_keys\(attributes, \[(?<values>[^\]]+)\]\) where resource\.attributes\[`"service\.name`"\] == `"$([regex]::Escape($service))`"").Groups['values'].Value
            Reject-Text $workerKeep $discarded "discarded Kafka attribute $discarded"
        }
    }
}

Reject-Text $actual 'debug/test-sink:' 'debug exporter in the sustained canary'
Require-Text $proof 'debug/test-sink:' 'disposable proof debug exporter'
Require-Text $compose 'otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6' 'pinned Collector image'
Require-Text $compose 'OTELCOL_INGEST_TOKEN:' 'Collector ingest secret wiring'
Require-Text $compose 'OTEL_COLLECTOR_CONFIG_FILE:-collector-canary.yaml' 'default sustained Collector configuration'
Require-Text $compose 'networks: [llm-council-otel-ingest, llm-council-observability]' 'Collector-only backend path'
Reject-Text $compose 'opentelemetry-collector-contrib:latest' 'floating Collector tag'
Reject-Text $compose 'ports:' 'published Collector ports'

Require-Text $graph 'llm-council-otel-ingest:   { external: true }' 'GraphRAG ingest network'
Require-Text $graph 'OTEL_SERVICE_NAME: graphrag-retrieval-service' 'GraphRAG retrieval identity'
Require-Text $graph 'OTEL_EXPORTER_OTLP_BEARER_TOKEN: ${OTEL_COLLECTOR_INGEST_TOKEN:-}' 'GraphRAG Collector authentication'
Reject-Text $graph 'llm-council-observability' 'direct GraphRAG backend network'
$indexerStart = $graph.IndexOf('  graphrag-indexing-worker:')
if ($indexerStart -lt 0) { throw 'BP1.75 Collector check failed: GraphRAG indexer service is missing.' }
$indexer = $graph.Substring($indexerStart)
Reject-Text $indexer 'llm-council-otel-ingest' 'unsupported indexer OTLP ingress'
Reject-Text $indexer 'OTEL_EXPORTER_OTLP_' 'unsupported indexer telemetry export'

Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_GRPC=otel-collector:4317' 'Collector-only GraphRAG endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_ORCHESTRATOR=http://otel-collector:4317' 'Collector-only Orchestrator endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_PROTOCOL_ORCHESTRATOR=grpc' 'Orchestrator gRPC protocol'
Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_API_GATEWAY=http://otel-collector:4318' 'API Gateway Collector endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_PROTOCOL_API_GATEWAY=http/protobuf' 'API Gateway OTLP/HTTP protocol'
Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_GEMINI=http://otel-collector:4318' 'Gemini Collector endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_PROTOCOL_GEMINI=http/protobuf' 'Gemini OTLP/HTTP protocol'
Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_GPT=http://otel-collector:4318' 'GPT Collector endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_PROTOCOL_GPT=http/protobuf' 'GPT OTLP/HTTP protocol'
Require-Text $option 'OTEL_EXPORTER_OTLP_ENDPOINT_LOCAL_AI=http://otel-collector:4318' 'Local AI Collector endpoint'
Require-Text $option 'OTEL_EXPORTER_OTLP_PROTOCOL_LOCAL_AI=http/protobuf' 'Local AI OTLP/HTTP protocol'
Reject-Text $option 'zipkin:' 'direct Zipkin canary endpoint'
Reject-Text $option 'openlit' 'direct OpenLIT canary endpoint'
Reject-Text $option 'clickhouse' 'direct ClickHouse canary endpoint'

Require-Text $composeFiles 'projects/core/overlays/collector-canary.yml' 'opt-in core Collector overlay'
Require-Text $coreOverlay '  api-gateway:' 'API Gateway edge overlay'
Require-Text $coreOverlay '  orchestrator-service:' 'preserved Orchestrator overlay'
Require-Text $coreOverlay 'OTEL_SERVICE_NAME: api-gateway' 'API Gateway identity'
Require-Text $coreOverlay 'OTEL_EXPORTER_OTLP_ENDPOINT_API_GATEWAY' 'API Gateway endpoint override'
Require-Text $coreOverlay 'OTEL_EXPORTER_OTLP_PROTOCOL_API_GATEWAY' 'API Gateway protocol override'
Require-Text $coreOverlay 'MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_HEADERS_AUTHORIZATION' 'Spring Boot 4 OTLP bearer header'
Require-Text $coreOverlay 'MANAGEMENT_OTLP_TRACING_HEADERS_AUTHORIZATION' 'Spring Boot compatibility OTLP bearer header'
Require-Text $coreOverlay '  gemini-service:' 'Gemini worker overlay'
Require-Text $coreOverlay '  gpt-service:' 'GPT worker overlay'
Require-Text $coreOverlay '  local-ai-service:' 'Local AI worker overlay'
Require-Text $coreOverlay 'OTEL_SERVICE_NAME: gemini-service' 'Gemini worker identity'
Require-Text $coreOverlay 'OTEL_SERVICE_NAME: gpt-service' 'GPT worker identity'
Require-Text $coreOverlay 'OTEL_SERVICE_NAME: local-ai-service' 'Local AI worker identity'
Require-Text $coreOverlay 'OTEL_EXPORTER_OTLP_ENDPOINT_GEMINI' 'Gemini endpoint override'
Require-Text $coreOverlay 'OTEL_EXPORTER_OTLP_ENDPOINT_GPT' 'GPT endpoint override'
Require-Text $coreOverlay 'OTEL_EXPORTER_OTLP_ENDPOINT_LOCAL_AI' 'Local AI endpoint override'
Reject-Text $coreOverlay 'zipkin:' 'direct Zipkin edge endpoint'
Reject-Text $coreOverlay 'openlit' 'direct OpenLIT edge endpoint'
Reject-Text $coreOverlay 'clickhouse' 'direct ClickHouse edge endpoint'
Reject-Text $coreOverlay 'ports:' 'published edge Collector ports'

# C3.2A/C3.2B are opt-in. The shared Docker defaults must remain on their pre-cutover route.
$defaultZipkin = '${OTEL_EXPORTER_OTLP_ENDPOINT:http://zipkin:9411}/v1/traces'
if (([regex]::Matches($backendDockerConfig, [regex]::Escape($defaultZipkin))).Count -ne 2) {
    throw 'BP1.75 Collector check failed: C3.2B changed the default backend OTLP route.'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'BP1.75 Collector check failed: docker is required to validate the exact Collector configuration.'
}
$image = 'otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6'
foreach ($configPath in @($actualConfigPath, $proofConfigPath)) {
    $resolvedConfig = (Resolve-Path -LiteralPath $configPath).Path
    & docker run --rm --env 'OTELCOL_INGEST_TOKEN=bp175-static-validation-token' --mount "type=bind,source=$resolvedConfig,target=/etc/otelcol/config.yaml,readonly" $image validate --config=/etc/otelcol/config.yaml
    if ($LASTEXITCODE -ne 0) { throw "BP1.75 Collector check failed: exact pinned image rejected $configPath" }
}

Write-Host 'BP1.75 Collector canary checks passed: manual/HTTP/Kafka registry separation, C3.1 compatibility, C3.2A/C3.2B parity, opt-in routing, and pinned configs are valid.'