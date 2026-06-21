[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $repoRoot

# ─── Per-project file chains ───────────────────────────────────────────────
$projects = @(
    @{
        Name        = "data"
        Base        = @("projects/data/docker-compose.yml")
        Dev         = @("projects/data/docker-compose.yml", "projects/data/overlays/dev-ports.yml")
        Networks    = @("llm-council-data")
        SpringSvcs  = @()
    },
    @{
        Name        = "messaging"
        Base        = @("projects/messaging/docker-compose.yml")
        Dev         = @("projects/messaging/docker-compose.yml", "projects/messaging/overlays/dev-ports.yml")
        Networks    = @("llm-council-messaging")
        SpringSvcs  = @()
    },
    @{
        Name        = "ai-runtime"
        Base        = @("projects/ai-runtime/docker-compose.yml")
        Dev         = @("projects/ai-runtime/docker-compose.yml", "projects/ai-runtime/overlays/dev-ports.yml")
        Networks    = @("llm-council-ai-runtime")
        SpringSvcs  = @()
    },
    @{
        Name        = "observability"
        Base        = @("projects/observability/docker-compose.yml")
        Dev         = @("projects/observability/docker-compose.yml", "projects/observability/overlays/dev-ports.yml")
        Prod        = @("projects/observability/docker-compose.yml", "projects/observability/overlays/prod.yml")
        LocalObs    = @("projects/observability/docker-compose.yml", "projects/observability/overlays/prod.yml", "projects/observability/overlays/local-observability.yml")
        Networks    = @("llm-council-observability", "llm-council-app")
        SpringSvcs  = @()
    },
    @{
        Name        = "platform"
        Base        = @("projects/platform/docker-compose.yml")
        Dev         = @("projects/platform/docker-compose.yml", "projects/platform/overlays/dev-ports.yml")
        Prod        = @("projects/platform/docker-compose.yml", "projects/platform/overlays/prod.yml")
        LogFiles    = @("projects/platform/docker-compose.yml", "projects/platform/overlays/prod.yml", "projects/platform/overlays/log-files.yml")
        Networks    = @("llm-council-platform")
        SpringSvcs  = @("config-server", "discovery-server")
    },
    @{
        Name        = "core"
        Base        = @("projects/core/docker-compose.yml")
        Dev         = @("projects/core/docker-compose.yml", "projects/core/overlays/dev-ports.yml")
        Prod        = @("projects/core/docker-compose.yml", "projects/core/overlays/prod.yml")
        ProdLite    = @("projects/core/docker-compose.yml", "projects/core/overlays/prod.yml", "projects/core/overlays/prod-lite.yml")
        LogFiles    = @("projects/core/docker-compose.yml", "projects/core/overlays/prod.yml", "projects/core/overlays/log-files.yml")
        HttpsFacade = @("projects/core/docker-compose.yml", "projects/core/overlays/prod.yml", "projects/core/overlays/https-api-facade.yml")
        Networks    = @("llm-council-data", "llm-council-messaging", "llm-council-observability",
                        "llm-council-platform", "llm-council-app", "llm-council-ai-runtime")
        SpringSvcs  = @("api-gateway", "auth-service", "account-service", "orchestrator-service",
                        "gemini-service", "gpt-service", "prompt-service", "local-ai-service")
    }
)

# Prometheus must scrape every Spring service that exposes /actuator/prometheus
# plus the Graph-RAG Python services that expose /metrics.
$expectedPrometheusTargets = @(
    "api-gateway:8080",
    "auth-service:8084",
    "orchestrator-service:8081",
    "gemini-service:8082",
    "gpt-service:8083",
    "account-service:8087",
    "prompt-service:8085",
    "local-ai-service:8086",
    "graphrag-retrieval-service:9100",
    "graphrag-indexing-worker:9100"
)

# Critical-risk container images (license risk band 4 in
# llm-council-docs/technical/licensing.html). Any rendered Compose chain that
# resolves a service to one of these patterns must fail validation. See
# reports/architecture-roadmap/2026-05-22/02/critical-dependency-replacement-plan.md
# for the approved replacements.
$forbiddenImagePatterns = @(
    '^redis:7\.4(?:[-.].*)?$',     # SSPL-1.0 + RSALv2 (Valkey replaces it)
    '^confluentinc/cp-',           # Confluent Community License (Apache Kafka KRaft replaces it)
    '^grafana/grafana(?::|$)',     # AGPL-3.0 (Perses replaces it). Does not match grafana/alloy or grafana/grafana-* sidecars.
    '^grafana/loki(?::|$)'         # AGPL-3.0 (VictoriaLogs replaces it). Does not match grafana/loki-canary or loki-stack.
)

$envFile = (Join-Path $repoRoot ".env")
$envFileArgs = @()
if (Test-Path $envFile) {
    $envFileArgs = @("--env-file", $envFile)
}

# ─── Helpers ───────────────────────────────────────────────────────────────
function Get-ComposeConfig {
    param([string]$Name, [string[]]$Files, [string[]]$Profiles = @())

    Write-Host "Validating $Name Compose config..."
    $args = @()
    $args += $envFileArgs
    foreach ($file in $Files) { $args += @("-f", $file) }
    foreach ($profile in $Profiles) { $args += @("--profile", $profile) }
    $args += @("config", "--format", "json")
    $json = & docker compose @args
    if ($LASTEXITCODE -ne 0) { throw "$Name Compose config failed." }
    return $json | ConvertFrom-Json
}

function Get-PublishedPorts {
    param($Config)
    $ports = @()
    foreach ($svc in $Config.services.PSObject.Properties) {
        if ($null -eq $svc.Value.ports) { continue }
        foreach ($p in $svc.Value.ports) {
            if ([string]::IsNullOrWhiteSpace([string]$p.published)) { continue }
            $ports += "{0}:{1}:{2}" -f $svc.Name, [string]$p.published, [string]$p.target
        }
    }
    return $ports | Sort-Object
}

function Get-PortBindings {
    param($Config)
    $bindings = @{}
    foreach ($svc in $Config.services.PSObject.Properties) {
        if ($null -eq $svc.Value.ports) { continue }
        foreach ($p in $svc.Value.ports) {
            if ([string]::IsNullOrWhiteSpace([string]$p.published)) { continue }
            $key = "{0}:{1}:{2}" -f $svc.Name, [string]$p.published, [string]$p.target
            $bindings[$key] = [string]$p.host_ip
        }
    }
    return $bindings
}

function Assert-SetEquals {
    param([string]$Name, [string[]]$Expected, [string[]]$Actual)
    $exp = @($Expected | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    $act = @($Actual   | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    if ($exp.Count -eq 0 -and $act.Count -eq 0) { return }
    $diff = Compare-Object $exp $act
    if ($diff) {
        Write-Host "$Name mismatch."
        Write-Host "Expected:"; $exp | ForEach-Object { Write-Host "  $_" }
        Write-Host "Actual:";   $act | ForEach-Object { Write-Host "  $_" }
        throw "$Name assertion failed."
    }
}

function Assert-NetworksExternal {
    param([string]$Name, $Config, [string[]]$Expected)
    if ($null -eq $Config.networks) {
        throw "$Name declares no networks. Expected: $($Expected -join ', ')."
    }
    foreach ($net in $Expected) {
        $entry = $Config.networks.$net
        if ($null -eq $entry) {
            throw "$Name is missing network declaration for '$net'."
        }
        if (-not $entry.external) {
            throw "$Name declares network '$net' but not as external. All inter-project networks must be external: true."
        }
    }
}

function Assert-NoJdwp {
    param([string]$Name, $Config)
    foreach ($svc in $Config.services.PSObject.Properties) {
        $opts = [string]$svc.Value.environment.JAVA_TOOL_OPTIONS
        if ($opts.Contains("agentlib:jdwp")) {
            throw "$Name still enables JDWP for $($svc.Name)."
        }
    }
}

function Assert-DevJdwp {
    param([string]$Name, $Config, [string[]]$Services)
    foreach ($svc in $Services) {
        $opts = [string]$Config.services.$svc.environment.JAVA_TOOL_OPTIONS
        if (-not $opts.Contains("agentlib:jdwp")) {
            throw "$Name dev config does not enable JDWP for $svc."
        }
    }
}

function Assert-NoLogDirInBase {
    param([string]$Name, $Config)
    foreach ($svc in $Config.services.PSObject.Properties) {
        $logDir = [string]$svc.Value.environment.LOG_DIR
        if (-not [string]::IsNullOrWhiteSpace($logDir)) {
            throw "$Name base config sets LOG_DIR for $($svc.Name). LOG_DIR must only be set via log-files overlay."
        }
    }
}

function Assert-LogDirPresentForServices {
    param([string]$Name, $Config, [string[]]$Services)
    foreach ($svc in $Services) {
        $logDir = [string]$Config.services.$svc.environment.LOG_DIR
        if ([string]::IsNullOrWhiteSpace($logDir)) {
            throw "$Name log-files config is missing LOG_DIR for $svc."
        }
    }
}

function Assert-LoopbackBinding {
    param([string]$Name, $Config, [string[]]$Services)
    $bindings = Get-PortBindings $Config
    foreach ($key in $bindings.Keys) {
        $svc = ($key -split ":")[0]
        if ($Services -notcontains $svc) { continue }
        $hostIp = $bindings[$key]
        if ([string]::IsNullOrWhiteSpace($hostIp)) {
            throw "$Name binds $key without host_ip. Observability ports must bind to loopback in local-operator mode."
        }
        if ($hostIp -ne "127.0.0.1" -and $hostIp -ne "::1") {
            throw "$Name binds $key to '$hostIp', expected loopback (127.0.0.1 or ::1)."
        }
    }
}

function Assert-ServiceProfile {
    param([string]$Name, $Config, [string]$Service, [string]$Profile)
    $entry = $Config.services.$Service
    if ($null -eq $entry) {
        throw "$Name is missing service: $Service"
    }
    $profiles = @($entry.profiles)
    if ($profiles -notcontains $Profile) {
        throw "$Name service '$Service' must be gated by profile '$Profile'."
    }
}

function Assert-ProjectServiceImageTags {
    param([string]$Name, $Config, [string[]]$Services)
    foreach ($svc in $Services) {
        $entry = $Config.services.$svc
        if ($null -eq $entry) {
            throw "$Name is missing service: $svc"
        }
        $image = [string]$entry.image
        if ([string]::IsNullOrWhiteSpace($image)) {
            throw ('{0}: service ''{1}'' is missing an explicit image tag.' -f $Name, $svc)
        }
        if (-not $image.Contains("/$svc")) {
            throw ('{0}: service ''{1}'' image tag ''{2}'' does not include the service name.' -f $Name, $svc, $image)
        }
        if ($null -eq $entry.build) {
            throw ('{0}: service ''{1}'' lost its build context. Image tags must be additive; keep build: alongside image:.' -f $Name, $svc)
        }
    }
}

function Assert-PrometheusTargets {
    param([string[]]$Expected)
    $prometheusFile = "infra/prometheus.yml"
    if (-not (Test-Path $prometheusFile)) { throw "infra/prometheus.yml not found." }
    $content = Get-Content $prometheusFile -Raw
    foreach ($target in $Expected) {
        if (-not $content.Contains($target)) {
            throw "infra/prometheus.yml is missing target: $target"
        }
    }
}

function Assert-NoCriticalImages {
    param([string]$Name, $Config, [string[]]$Patterns)
    $violations = @()
    foreach ($svc in $Config.services.PSObject.Properties) {
        $image = [string]$svc.Value.image
        if ([string]::IsNullOrWhiteSpace($image)) { continue }
        foreach ($pattern in $Patterns) {
            if ($image -match $pattern) {
                $violations += ('  {0}: {1}  (matches /{2}/)' -f $svc.Name, $image, $pattern)
                break
            }
        }
    }
    if ($violations.Count -gt 0) {
        Write-Host "$Name uses Critical-risk images:"
        $violations | ForEach-Object { Write-Host $_ }
        Write-Host "See llm-council-docs/technical/licensing.html for replacement targets."
        throw "$Name forbidden-image assertion failed."
    }
}

# ─── Per-project validation ────────────────────────────────────────────────
foreach ($p in $projects) {
    Write-Host ""
    Write-Host "=== Project: $($p.Name) ==="

    $base = Get-ComposeConfig "$($p.Name) base" $p.Base
    Assert-SetEquals "$($p.Name) base published ports" @() @(Get-PublishedPorts $base)
    Assert-NetworksExternal "$($p.Name) base" $base $p.Networks
    Assert-NoLogDirInBase "$($p.Name) base" $base
    Assert-NoCriticalImages "$($p.Name) base" $base $forbiddenImagePatterns
    if ($p.SpringSvcs.Count -gt 0) {
        Assert-NoJdwp "$($p.Name) base" $base
        Assert-ProjectServiceImageTags "$($p.Name) base" $base $p.SpringSvcs
    }

    if ($p.Dev) {
        $dev = Get-ComposeConfig "$($p.Name) dev" $p.Dev
        Assert-NetworksExternal "$($p.Name) dev" $dev $p.Networks
        Assert-NoCriticalImages "$($p.Name) dev" $dev $forbiddenImagePatterns
        if ($p.SpringSvcs.Count -gt 0) {
            Assert-DevJdwp "$($p.Name) dev" $dev $p.SpringSvcs
        }
    }

    if ($p.Prod) {
        $prod = Get-ComposeConfig "$($p.Name) prod" $p.Prod
        Assert-NetworksExternal "$($p.Name) prod" $prod $p.Networks
        Assert-NoJdwp "$($p.Name) prod" $prod
        Assert-NoCriticalImages "$($p.Name) prod" $prod $forbiddenImagePatterns
    }

    if ($p.ProdLite) {
        $prodLite = Get-ComposeConfig "$($p.Name) prod-lite" $p.ProdLite
        $prodLiteNetworks = @($p.Networks | Where-Object { $_ -ne "llm-council-ai-runtime" })
        Assert-NetworksExternal "$($p.Name) prod-lite" $prodLite $prodLiteNetworks
        Assert-NoJdwp "$($p.Name) prod-lite" $prodLite
        Assert-NoCriticalImages "$($p.Name) prod-lite" $prodLite $forbiddenImagePatterns
    }

    if ($p.LogFiles) {
        $logFiles = Get-ComposeConfig "$($p.Name) log-files" $p.LogFiles
        Assert-LogDirPresentForServices "$($p.Name) log-files" $logFiles $p.SpringSvcs
        Assert-NoCriticalImages "$($p.Name) log-files" $logFiles $forbiddenImagePatterns
    }

    if ($p.HttpsFacade) {
        $httpsFacade = Get-ComposeConfig "$($p.Name) https-facade" $p.HttpsFacade
        Assert-NetworksExternal "$($p.Name) https-facade" $httpsFacade $p.Networks
        Assert-NoJdwp "$($p.Name) https-facade" $httpsFacade
        Assert-NoCriticalImages "$($p.Name) https-facade" $httpsFacade $forbiddenImagePatterns
    }
}

# ─── Per-project port assertions ───────────────────────────────────────────
$coreProj = $projects | Where-Object { $_.Name -eq "core" }
$coreProd = Get-ComposeConfig "core prod (ports)" $coreProj.Prod
Assert-SetEquals "core prod published ports" @("api-gateway:8080:8080") @(Get-PublishedPorts $coreProd)
Assert-NoCriticalImages "core prod (ports)" $coreProd $forbiddenImagePatterns

$coreProdLite = Get-ComposeConfig "core prod-lite (ports)" $coreProj.ProdLite
Assert-SetEquals "core prod-lite published ports" @("api-gateway:8080:8080") @(Get-PublishedPorts $coreProdLite)
Assert-NoCriticalImages "core prod-lite (ports)" $coreProdLite $forbiddenImagePatterns

$coreProdLiteWithLocalAi = Get-ComposeConfig "core prod-lite laptop-local-ai profile" $coreProj.ProdLite @("laptop-local-ai")
Assert-ServiceProfile "core prod-lite laptop-local-ai profile" $coreProdLiteWithLocalAi "local-ai-service" "laptop-local-ai"
Assert-NetworksExternal "core prod-lite laptop-local-ai profile" $coreProdLiteWithLocalAi $coreProj.Networks

$coreHttpsFacade = Get-ComposeConfig "core https-facade (ports)" $coreProj.HttpsFacade
Assert-SetEquals "core https-facade published ports" @("api-gateway:8080:8080", "api-gateway-https:8443:8443") @(Get-PublishedPorts $coreHttpsFacade)
Assert-LoopbackBinding "core https-facade" $coreHttpsFacade @("api-gateway-https")
Assert-NoCriticalImages "core https-facade (ports)" $coreHttpsFacade $forbiddenImagePatterns

$obsProj = $projects | Where-Object { $_.Name -eq "observability" }
$obsProd = Get-ComposeConfig "observability prod (ports)" $obsProj.Prod
Assert-SetEquals "observability prod published ports" @() @(Get-PublishedPorts $obsProd)
Assert-NoCriticalImages "observability prod (ports)" $obsProd $forbiddenImagePatterns

$obsLocal = Get-ComposeConfig "observability local-obs" $obsProj.LocalObs
$expectedLocalObsPorts = @(
    "prometheus:9090:9090",
    "zipkin:9411:9411",
    "victorialogs:9428:9428"
)
Assert-SetEquals "observability local-obs published ports" $expectedLocalObsPorts @(Get-PublishedPorts $obsLocal)
Assert-LoopbackBinding "observability local-obs" $obsLocal @("prometheus", "zipkin", "victorialogs")
Assert-NoCriticalImages "observability local-obs" $obsLocal $forbiddenImagePatterns

# ─── Prometheus targets ────────────────────────────────────────────────────
Assert-PrometheusTargets $expectedPrometheusTargets

Write-Host ""
Write-Host "Compose validation OK across all configured project chains."
