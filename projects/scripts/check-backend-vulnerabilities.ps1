[CmdletBinding()]
param(
    [string]$RepoRoot = $null,
    [string]$SbomPath = $null,
    [ValidateSet("low", "medium", "high", "critical")]
    [string]$FailOn = "high"
)

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

if ([string]::IsNullOrEmpty($SbomPath)) {
    $SbomPath = Join-Path $RepoRoot "target\backend-bom.json"
}

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SbomPath)) {
    Write-Host "Backend SBOM not found: $SbomPath" -ForegroundColor Red
    Write-Host "Run ``mvn -DskipTests verify`` from the Maven reactor root first."
    exit 2
}

$grype = Get-Command "grype" -ErrorAction SilentlyContinue
if ($null -ne $grype) {
    & $grype.Source "sbom:$SbomPath" "--fail-on" $FailOn
    exit $LASTEXITCODE
}

$trivy = Get-Command "trivy" -ErrorAction SilentlyContinue
if ($null -ne $trivy) {
    $severity = if ($FailOn -eq "critical") { "CRITICAL" } elseif ($FailOn -eq "high") { "HIGH,CRITICAL" } elseif ($FailOn -eq "medium") { "MEDIUM,HIGH,CRITICAL" } else { "LOW,MEDIUM,HIGH,CRITICAL" }
    & $trivy.Source "sbom" "--exit-code" "1" "--severity" $severity $SbomPath
    exit $LASTEXITCODE
}

$osvScanner = Get-Command "osv-scanner" -ErrorAction SilentlyContinue
if ($null -ne $osvScanner) {
    & $osvScanner.Source "--sbom" $SbomPath
    exit $LASTEXITCODE
}

Write-Host "No supported backend vulnerability scanner is installed." -ForegroundColor Red
Write-Host "Install one of: grype, trivy, or osv-scanner; then rerun this script against target\backend-bom.json."
exit 2
