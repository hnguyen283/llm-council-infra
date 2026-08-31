[CmdletBinding()]
param(
    [string]$InfraRoot
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InfraRoot)) {
    $InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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

$actualConfigPath = Join-Path $InfraRoot "projects\observability\otelcol\collector-canary.yaml"
$proofConfigPath = Join-Path $InfraRoot "projects\observability\otelcol\collector-proof.yaml"
$composePath = Join-Path $InfraRoot "projects\observability\docker-compose.yml"
$graphPath = Join-Path $InfraRoot "projects\graphrag\docker-compose.yml"
$optionPath = Join-Path $InfraRoot "options\prod-full-local-observability-collector-canary\option.env"

foreach ($path in @($actualConfigPath, $proofConfigPath, $composePath, $graphPath, $optionPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "BP1.75 Collector check failed: required path is missing: $path"
    }
}

$actual = Get-Content -LiteralPath $actualConfigPath -Raw
$proof = Get-Content -LiteralPath $proofConfigPath -Raw
$compose = Get-Content -LiteralPath $composePath -Raw
$graph = Get-Content -LiteralPath $graphPath -Raw
$option = Get-Content -LiteralPath $optionPath -Raw

foreach ($required in @(
    'endpoint: 0.0.0.0:4317',
    'endpoint: 0.0.0.0:4318',
    'bearertokenauth/ingest:',
    'auth:',
    'authenticator: bearertokenauth/ingest',
    'filter/allowlisted-services:',
    'filter/allowlisted-shape:',
    'filter/prohibited-fields:',
    'transform/attribute-registry:',
    'keep_keys(attributes, ["rag.query_length"',
    'resource/trusted-stamp:',
    'probabilistic_sampler/canary:',
    'memory_limiter:',
    'otlp_http/zipkin-comparison:',
    'sending_queue:',
    'retry_on_failure:',
    'health_check:',
    'readers:',
    'prometheus:',
    'rag.query',
    'gen_ai.prompt',
    'input.value',
    'output.value'
)) {
    Require-Text $actual $required "sustained Collector policy element"
}
Reject-Text $actual 'debug/test-sink:' 'debug exporter in the sustained canary'
Require-Text $proof 'debug/test-sink:' 'disposable proof debug exporter'
Require-Text $proof 'transform/attribute-registry:' 'proof registry enforcement'
Require-Text $proof 'bearertokenauth/ingest:' 'proof ingress authentication'

Require-Text $compose 'otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6' 'pinned Collector image'
Require-Text $compose 'OTELCOL_INGEST_TOKEN:' 'Collector ingest secret wiring'
Require-Text $compose 'OTEL_COLLECTOR_CONFIG_FILE:-collector-canary.yaml' 'default sustained Collector configuration'
Require-Text $compose 'healthcheck:' 'Collector healthcheck'
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
Reject-Text $option 'zipkin:' 'direct Zipkin GraphRAG endpoint'
Reject-Text $option 'openlit' 'direct OpenLIT GraphRAG endpoint'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "BP1.75 Collector check failed: docker is required to validate the exact Collector configuration"
}

$image = 'otel/opentelemetry-collector-contrib@sha256:f2f01157055a9b2aab9df7118e1f1c9abf345e99b23bc7a2bc791db374a7d0f6'
foreach ($configPath in @($actualConfigPath, $proofConfigPath)) {
    $resolvedConfig = (Resolve-Path -LiteralPath $configPath).Path
    & docker run --rm --env 'OTELCOL_INGEST_TOKEN=bp175-static-validation-token' --mount "type=bind,source=$resolvedConfig,target=/etc/otelcol/config.yaml,readonly" $image validate --config=/etc/otelcol/config.yaml
    if ($LASTEXITCODE -ne 0) {
        throw "BP1.75 Collector check failed: exact pinned image rejected $configPath"
    }
}

Write-Host "BP1.75 Collector canary checks passed."