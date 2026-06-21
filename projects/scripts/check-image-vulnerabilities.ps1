[CmdletBinding()]
param(
    [string]$RepoRoot = $null,
    [string]$SbomDir = $null,
    [ValidateSet("negligible", "low", "medium", "high", "critical")]
    [string]$FailOn = "high"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if ([string]::IsNullOrEmpty($SbomDir)) {
    $SbomDir = Join-Path $RepoRoot "target\image-sboms"
}

if (-not (Test-Path $SbomDir)) {
    Write-Host "Image SBOM directory not found: $SbomDir" -ForegroundColor Red
    Write-Host "Run projects\scripts\check-image-sbom.cmd first."
    exit 2
}

$sboms = @(Get-ChildItem -LiteralPath $SbomDir -File -Filter "*.cyclonedx.json")
if ($sboms.Count -eq 0) {
    Write-Host "No image SBOM files found under $SbomDir" -ForegroundColor Red
    Write-Host "Run projects\scripts\check-image-sbom.cmd first."
    exit 2
}

$grype = Get-Command "grype" -ErrorAction SilentlyContinue
if ($null -ne $grype) {
    foreach ($sbom in $sboms) {
        & $grype.Source "sbom:$($sbom.FullName)" "--fail-on" $FailOn
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Host ("Image vulnerability scan OK with Grype across {0} SBOM(s)." -f $sboms.Count) -ForegroundColor Green
    exit 0
}

$trivy = Get-Command "trivy" -ErrorAction SilentlyContinue
if ($null -ne $trivy) {
    $severity = if ($FailOn -eq "critical") { "CRITICAL" } else { "HIGH,CRITICAL" }
    foreach ($sbom in $sboms) {
        & $trivy.Source "sbom" "--exit-code" "1" "--severity" $severity $sbom.FullName
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Host ("Image vulnerability scan OK with Trivy across {0} SBOM(s)." -f $sboms.Count) -ForegroundColor Green
    exit 0
}

$osvScanner = Get-Command "osv-scanner" -ErrorAction SilentlyContinue
if ($null -ne $osvScanner) {
    foreach ($sbom in $sboms) {
        & $osvScanner.Source "--sbom" $sbom.FullName
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Host ("Image vulnerability scan OK with OSV Scanner across {0} SBOM(s)." -f $sboms.Count) -ForegroundColor Green
    exit 0
}

Write-Host "No supported image vulnerability scanner is installed." -ForegroundColor Red
Write-Host "Install one of: grype, trivy, or osv-scanner; then rerun this script after image SBOM generation."
exit 2
