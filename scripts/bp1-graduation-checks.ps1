param(
  [string]$RepoRoot
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot -or $RepoRoot.Trim() -eq "") {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
} else {
  $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$failures = New-Object System.Collections.Generic.List[string]
$pending = New-Object System.Collections.Generic.List[string]

function Pass($message) {
  Write-Host "PASS: $message"
}

function Fail($message) {
  $script:failures.Add($message) | Out-Null
  Write-Host "FAIL: $message"
}

function Pending($message) {
  $script:pending.Add($message) | Out-Null
  Write-Host "PENDING: $message"
}

function Require-File($relativePath) {
  $path = Join-Path $RepoRoot $relativePath
  if (Test-Path $path) {
    Pass "$relativePath exists"
    return (Resolve-Path $path).Path
  }
  Fail "$relativePath is missing"
  return $null
}

function Read-Json($relativePath) {
  $path = Require-File $relativePath
  if (-not $path) { return $null }
  try {
    return (Get-Content -Raw -Path $path | ConvertFrom-Json)
  } catch {
    Fail "$relativePath is not valid JSON: $($_.Exception.Message)"
    return $null
  }
}

function Sequence-Names($pipeline) {
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($stageName in @("inbound", "processing", "outbound")) {
    $stage = $pipeline.stages.$stageName
    if ($stage) {
      foreach ($item in $stage) {
        $names.Add([string]$item.sequenceName) | Out-Null
      }
    }
  }
  return $names
}

Write-Host "=== BP1 static graduation checks ==="
Write-Host "Repo root: $RepoRoot"

$defaultPipeline = Read-Json "llm-council\prompt-service\src\main\resources\workflow-pipelines\default-research.v2.json"
if ($defaultPipeline) {
  if ($defaultPipeline.status -eq "ACTIVE") { Pass "default-research v2 is ACTIVE" } else { Fail "default-research v2 is not ACTIVE" }
  if ($defaultPipeline.defaultPipeline -eq $true) { Pass "default-research v2 is the default pipeline" } else { Fail "default-research v2 is not the default pipeline" }
  $names = Sequence-Names $defaultPipeline
  foreach ($required in @("RephrasePrompt", "Research", "FinalizeResearchOutput")) {
    if ($names -contains $required) { Pass "default pipeline includes $required" } else { Fail "default pipeline is missing $required" }
  }
  if ($names -contains "KnowledgeRetrieval") {
    Fail "default pipeline requires KnowledgeRetrieval before BP1 Phase 8 graduation"
  } else {
    Pass "default pipeline does not require KnowledgeRetrieval"
  }
}

$decomposedPipeline = Read-Json "llm-council\prompt-service\src\main\resources\workflow-pipelines\default-research-decomposed.v1.json"
if ($decomposedPipeline) {
  if ($decomposedPipeline.status -eq "ACTIVE") { Pass "decomposed pipeline is ACTIVE" } else { Fail "decomposed pipeline is not ACTIVE" }
  if ($decomposedPipeline.defaultPipeline -eq $false) { Pass "decomposed pipeline is opt-in, not default" } else { Fail "decomposed pipeline is unexpectedly default" }
  $names = Sequence-Names $decomposedPipeline
  foreach ($required in @("ResearchPlanning", "ResearchCollection", "ResearchAnalysis", "ResearchEvaluation", "ResearchJudgement", "EvidenceEnrichment", "FinalAnswerSynthesis")) {
    if ($names -contains $required) { Pass "decomposed pipeline includes $required" } else { Fail "decomposed pipeline is missing $required" }
  }
}

$ragPipeline = Read-Json "llm-council\prompt-service\src\main\resources\workflow-pipelines\default-research-rag.v1.json"
if ($ragPipeline) {
  $names = Sequence-Names $ragPipeline
  if ($names -contains "KnowledgeRetrieval") { Pass "RAG pipeline includes KnowledgeRetrieval" } else { Fail "RAG pipeline is missing KnowledgeRetrieval" }
  if ($ragPipeline.defaultPipeline -eq $false) { Pass "RAG pipeline is not default" } else { Fail "RAG pipeline is unexpectedly default before claim-check graduation" }
}

foreach ($xml in @(
  "llm-council\orchestrator-service\src\main\resources\rephrase-prompt-workflow.xml",
  "llm-council\orchestrator-service\src\main\resources\research-workflow.xml",
  "llm-council\orchestrator-service\src\main\resources\finalize-research-output-workflow.xml",
  "llm-council\orchestrator-service\src\main\resources\knowledge-retrieval-workflow.xml"
)) {
  [void](Require-File $xml)
}

$knowledgeXmlPath = Join-Path $RepoRoot "llm-council\orchestrator-service\src\main\resources\knowledge-retrieval-workflow.xml"
if (Test-Path $knowledgeXmlPath) {
  $knowledgeXml = Get-Content -Raw -Path $knowledgeXmlPath
  if ($knowledgeXml -match '<transition\s+on="error"\s+to=""') {
    Pending "KnowledgeRetrieval still has error transitions to the error terminal; Batch C must make optional fail-open paths explicit."
  } else {
    Pass "KnowledgeRetrieval optional error paths are explicit"
  }
}

foreach ($test in @(
  "llm-council\orchestrator-service\src\test\java\com\aio\orchestrator\workflow\phase7\WorkflowEquivalenceTest.java",
  "llm-council\orchestrator-service\src\test\java\com\aio\orchestrator\workflow\phase8\KnowledgeRetrievalXmlTest.java",
  "llm-council\orchestrator-service\src\test\java\com\aio\orchestrator\workflow\phase8\WorkflowRagE2eMatrixTest.java",
  "llm-council\orchestrator-service\src\test\java\com\aio\orchestrator\artifacts\LocalFileObjectPayloadStoreTest.java"
)) {
  [void](Require-File $test)
}

$evidenceRoot = Join-Path $RepoRoot "reports\architecture-roadmap\2026-07-12\02\evidence"
if (Test-Path (Join-Path $evidenceRoot "runtime-graduation-complete.md")) {
  Pass "BP1 runtime graduation evidence is attached"
} else {
  Pending "BP1 runtime graduation evidence is not attached yet."
}

Write-Host ""
Write-Host "=== BP1 static graduation summary ==="
Write-Host "Failures: $($failures.Count)"
Write-Host "Pending runtime/promotion gates: $($pending.Count)"

if ($pending.Count -gt 0) {
  foreach ($item in $pending) {
    Write-Host "PENDING: $item"
  }
}

if ($failures.Count -gt 0) {
  foreach ($item in $failures) {
    Write-Host "FAIL: $item"
  }
  exit 1
}

Write-Host "BP1 static checks passed. BP1 is not graduated while pending gates remain."
exit 0
