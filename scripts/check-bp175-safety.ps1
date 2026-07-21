[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-SourceFiles {
    param([string]$Path, [string[]]$Extensions)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required path is missing: $Path"
    }

    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $Extensions -contains $_.Extension -and
            $_.Name -ne "check-bp175-safety.ps1" -and
            $_.FullName -notmatch "[\\/](\.git|node_modules|dist|target|\.pytest_cache)[\\/]"
        }
}

function Assert-PatternAbsent {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Pattern,
        [string]$Name
    )

    $matches = $Files | Select-String -Pattern $Pattern -AllMatches
    if ($matches) {
        $locations = ($matches | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join ", "
        throw "BP1.75 safety check failed ($Name): $locations"
    }
}

$backendRoot = Join-Path $WorkspaceRoot "llm-council"
$infraRoot = Join-Path $WorkspaceRoot "llm-council-infra"
$adminRoot = Join-Path $WorkspaceRoot "llm-council-admin-ui"
$registry = Join-Path $backendRoot "docs\architecture\observation-envelope-v1.yaml"

if (-not (Test-Path -LiteralPath $registry)) {
    throw "BP1.75 registry is missing: $registry"
}

$registryContent = Get-Content -LiteralPath $registry -Raw
foreach ($required in @("schemaVersion: llm-council.observation-envelope/v1", "prohibitedAttributeNames:", "prohibitedValueClasses:")) {
    if (-not $registryContent.Contains($required)) {
        throw "BP1.75 registry is incomplete: missing '$required'"
    }
}

$javaAndPython = @(Get-SourceFiles $backendRoot @(".java", ".py"))
Assert-PatternAbsent $javaAndPython "query='\{\}'" "raw-query-log-template"
Assert-PatternAbsent $javaAndPython "prompt='\{\}'" "raw-prompt-log-template"
Assert-PatternAbsent $javaAndPython "next query='\{\}'" "raw-next-query-log-template"
Assert-PatternAbsent $javaAndPython "for query: '\{\}'" "raw-workflow-query-log-template"
Assert-PatternAbsent $javaAndPython 'set_attribute\(\s*["''](?:rag\.query|llm_council\.tenant_id|llm_council\.document_id|llm_council\.entity_name|gen_ai\.prompt|gen_ai\.completion)\b' "prohibited-span-attribute"

$activeInfra = @(Get-SourceFiles (Join-Path $infraRoot "projects") @(".yml", ".yaml", ".env")) +
    @(Get-SourceFiles (Join-Path $infraRoot "compose") @(".yml", ".yaml")) +
    @(Get-SourceFiles (Join-Path $infraRoot "options") @(".md", ".env", ".files")) +
    @(Get-SourceFiles (Join-Path $infraRoot "scripts") @(".bat", ".cmd", ".ps1", ".sh")) +
    @(Get-SourceFiles (Join-Path $infraRoot "env") @(".env", ".yml", ".yaml"))
Assert-PatternAbsent $activeInfra "(?i)arize-phoenix|arizephoenix/phoenix|PHOENIX_" "active-phoenix-dependency"

$backendConfig = @(Get-SourceFiles (Join-Path $backendRoot "config-repo") @(".yml", ".yaml", ".properties"))
Assert-PatternAbsent $backendConfig "(?i)arize-phoenix|arizephoenix/phoenix|PHOENIX_" "backend-phoenix-default"

$adminSource = @(Get-SourceFiles (Join-Path $adminRoot "src") @(".ts", ".html", ".scss"))
Assert-PatternAbsent $adminSource "(?i)arize-phoenix|arizephoenix|phoenix" "admin-phoenix-navigation"

Write-Host "BP1.75 safety checks passed. Registry, content-field guardrails, and Phoenix quarantine are active."
