param(
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path,
  [Alias("ComposeFile")]
  [string]$ComposeFileList = "$PSScriptRoot\..\.generated\prod-lite-local\compose.files.txt"
)

$ErrorActionPreference = "Stop"
$failed = $false

function Fail($message) {
  Write-Host "FAIL: $message" -ForegroundColor Red
  $script:failed = $true
}

function Pass($message) {
  Write-Host "PASS: $message" -ForegroundColor Green
}

function Require-File($path) {
  if (-not (Test-Path -LiteralPath $path)) {
    Fail "Missing required file: $path"
    return $false
  }
  return $true
}

$requiredMigrations = @(
  "llm-council\account-service\src\main\resources\db\migration\V18__privacy_locator_task_foundation.sql",
  "llm-council\account-service\src\main\resources\db\migration\V19__privacy_executable_rights.sql",
  "llm-council\account-service\src\main\resources\db\migration\V20__workspace_selector_rls.sql"
)

foreach ($migration in $requiredMigrations) {
  if (Require-File (Join-Path $RepoRoot $migration)) {
    Pass "Found $migration"
  }
}

$rlsText = Get-Content -Raw -Path (Join-Path $RepoRoot "llm-council\account-service\src\main\resources\db\migration\V19__privacy_executable_rights.sql")
if ($rlsText -notmatch "privacy_export_artifact ENABLE ROW LEVEL SECURITY" -or
    $rlsText -notmatch "privacy_export_artifact FORCE ROW LEVEL SECURITY") {
  Fail "privacy_export_artifact RLS/FORCE RLS migration is incomplete"
} else {
  Pass "privacy_export_artifact has RLS/FORCE RLS migration"
}

$defaultFallbackFiles = @(
  "llm-council\orchestrator-service\src\main\java\com\aio\orchestrator\workflow\actions\DispatchKnowledgeRetrievalAction.java",
  "llm-council\orchestrator-service\src\main\java\com\aio\orchestrator\workflow\actions\DispatchEvidenceEnrichmentAction.java",
  "llm-council\orchestrator-service\src\main\java\com\aio\orchestrator\workflow\actions\PersistRetrievalBundleAction.java"
)

foreach ($file in $defaultFallbackFiles) {
  $path = Join-Path $RepoRoot $file
  if (Test-Path -LiteralPath $path) {
    $matches = Select-String -Path $path -Pattern '"default"|default namespace|defaultTenant'
    if ($matches) {
      Fail "Default tenant/namespace fallback remains in $file"
    } else {
      Pass "No default tenant fallback in $file"
    }
  }
}

$locatorProducerFiles = @(
  "llm-council\account-service\src\main\java\com\aio\account\service\PersonalTenantProvisioningService.java",
  "llm-council\account-service\src\main\java\com\aio\account\service\UsageService.java",
  "llm-council\prompt-service\src\main\java\com\aio\prompt\artifacts\ArtifactRegistryService.java",
  "llm-council\prompt-service\src\main\java\com\aio\prompt\standardized\StandardizedPromptService.java",
  "llm-council\prompt-service\src\main\java\com\aio\prompt\workflow\web\WorkflowArtifactController.java"
)

foreach ($file in $locatorProducerFiles) {
  $path = Join-Path $RepoRoot $file
  if (-not (Test-Path -LiteralPath $path)) {
    Fail "Missing locator producer file $file"
    continue
  }
  $text = Get-Content -Raw -Path $path
  if ($text -notmatch "PrivacyLocator") {
    Fail "No PrivacyLocator producer call found in $file"
  } else {
    Pass "Locator producer present in $file"
  }
}

if (Test-Path -LiteralPath $ComposeFileList) {
  $generatedDirectory = Split-Path -Parent $ComposeFileList
  $infraRoot = (Resolve-Path "$PSScriptRoot\..").Path
  $composeArgs = @()
  $environmentLayersFile = Join-Path $generatedDirectory "environment.layers.txt"
  if (Test-Path -LiteralPath $environmentLayersFile) {
    foreach ($relativePath in Get-Content -LiteralPath $environmentLayersFile) {
      if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
        $composeArgs += @("--env-file", (Join-Path $infraRoot $relativePath))
      }
    }
  }
  foreach ($relativePath in Get-Content -LiteralPath $ComposeFileList) {
    if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
      $composeArgs += @("-f", (Join-Path $infraRoot $relativePath))
    }
  }
  $profilesFile = Join-Path $generatedDirectory "profiles.txt"
  if (Test-Path -LiteralPath $profilesFile) {
    foreach ($profile in Get-Content -LiteralPath $profilesFile) {
      if (-not [string]::IsNullOrWhiteSpace($profile)) {
        $composeArgs += @("--profile", $profile)
      }
    }
  }
  $composeArgs += @("config", "--quiet")
  docker compose @composeArgs
  if ($LASTEXITCODE -ne 0) {
    Fail "docker compose config --quiet failed for the generated option file list"
  } else {
    Pass "docker compose config --quiet passed for the generated option file list"
  }
} else {
  Fail "Generated prod-lite Compose file list not found; run scripts\config.bat prod-lite-local first"
}

if ($failed) {
  exit 1
}

Write-Host "BP1.5 static graduation checks passed." -ForegroundColor Green
