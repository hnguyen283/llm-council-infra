param(
  [string]$RepoRoot
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot -or $RepoRoot.Trim() -eq "") {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
} else {
  $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

$checkScript = Join-Path $RepoRoot "llm-council-infra\scripts\bp1-graduation-checks.ps1"
if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) {
  throw "BP1 graduation check script not found: $checkScript"
}

$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempParent ("bp1-graduation-evidence-" + [guid]::NewGuid())
$evidenceRoot = Join-Path $tempRoot "evidence"

function Invoke-GraduationCheck([string]$evidencePath) {
  $output = & powershell -NoProfile -ExecutionPolicy Bypass `
    -File $checkScript `
    -RepoRoot $RepoRoot `
    -EvidenceRoot $evidencePath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Graduation check failed unexpectedly:`n$($output -join [Environment]::NewLine)"
  }
  return $output -join [Environment]::NewLine
}

function Assert-Contains([string]$actual, [string]$expected) {
  if (-not $actual.Contains($expected)) {
    throw "Expected output to contain '$expected'. Actual output:`n$actual"
  }
}

try {
  $missingOutput = Invoke-GraduationCheck $evidenceRoot
  Assert-Contains $missingOutput "PENDING: BP1 runtime evidence root does not exist:"

  New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $evidenceRoot "runtime-graduation-complete.md") `
    -Encoding utf8 `
    -Value @"
# BP1 Runtime Graduation

Result: FAIL
"@
  $malformedOutput = Invoke-GraduationCheck $evidenceRoot
  Assert-Contains $malformedOutput "PENDING: BP1 runtime evidence does not declare Result: PASS."
  Assert-Contains $malformedOutput "PENDING: BP1 runtime evidence does not include a runtime job ID."

  Set-Content -LiteralPath (Join-Path $evidenceRoot "runtime-graduation-complete.md") `
    -Encoding utf8 `
    -Value @"
# BP1 Runtime Graduation

Result: PASS

- Main job ID: ae75e2c0-c86b-4a47-9296-91634ad59586
- Shadow job ID: ae75e2c0-c86b-4a47-9296-91634ad59586-shadow
- Phase 7 canaryEligible=true.
- Public edge health: http://localhost:8080/actuator/health returned UP.
- KnowledgeRetrieval fail-open and fail-closed evidence passed.
- Artifact and claim-check persistence evidence passed.
- Sensitive-data leak scan: PASS.
- Rollback restored the default Research path.
- No required check was skipped.
"@
  $validOutput = Invoke-GraduationCheck $evidenceRoot
  Assert-Contains $validOutput "PASS: BP1 runtime graduation evidence is valid at"
  Assert-Contains $validOutput "Pending runtime/promotion gates: 0"

  Write-Host "PASS: BP1 evidence lookup and content validation scenarios"
} finally {
  $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
  if (-not $resolvedTempRoot.StartsWith(
      $tempParent,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected test path: $resolvedTempRoot"
  }
  if (Test-Path -LiteralPath $resolvedTempRoot) {
    Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
  }
}
