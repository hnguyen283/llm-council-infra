[CmdletBinding()]
param(
    [string]$RepoRoot = $null,
    [string]$SbomPath = $null,
    [int]$MinimumComponents = 50
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

$sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json
$components = @($sbom.components)

if ($sbom.bomFormat -ne "CycloneDX") {
    Write-Host "Backend SBOM is not a CycloneDX document: $($sbom.bomFormat)" -ForegroundColor Red
    exit 1
}

if ($sbom.specVersion -ne "1.6") {
    Write-Host "Backend SBOM uses CycloneDX specVersion $($sbom.specVersion); expected 1.6." -ForegroundColor Red
    exit 1
}

if ($components.Count -lt $MinimumComponents) {
    Write-Host ("Backend SBOM has only {0} component(s); expected at least {1}." -f $components.Count, $MinimumComponents) -ForegroundColor Red
    exit 1
}

Write-Host ("Backend SBOM OK: {0} component(s), CycloneDX {1}." -f $components.Count, $sbom.specVersion) -ForegroundColor Green
