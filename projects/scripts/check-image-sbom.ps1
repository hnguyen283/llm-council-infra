[CmdletBinding()]
param(
    [string]$RepoRoot = $null,
    [string]$OutputDir = $null,
    [int]$MinimumComponents = 5
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if ([string]::IsNullOrEmpty($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "target\image-sboms"
}

function Resolve-ImageReference {
    param([string]$ImageRef)
    $resolved = $ImageRef
    $pattern = '\$\{([^}:]+)(?:(:?)-([^}]*))?\}'

    while ($resolved -match $pattern) {
        $token = $matches[0]
        $name = $matches[1]
        $usesColon = $matches[2] -eq ':'
        $default = $matches[3]
        $value = [Environment]::GetEnvironmentVariable($name)

        if ([string]::IsNullOrEmpty($value) -and $null -ne $default) {
            $value = $default
        }
        if ([string]::IsNullOrEmpty($value) -and -not $usesColon) {
            $value = ""
        }

        $resolved = $resolved.Replace($token, $value)
    }

    return $resolved
}

function Test-IgnoredPath {
    param([string]$Path)
    return ($Path -match '\\(?:\.git|\.pytest_cache|target|node_modules|dist|build)\\')
}

function Get-ImageTargets {
    param([string]$Root)
    $targets = @()

    $yamlFiles = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Extension -eq ".yml" -or $_.Extension -eq ".yaml") -and -not (Test-IgnoredPath $_.FullName) }
    foreach ($file in $yamlFiles) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -match '^\s*image:\s*([^\s#]+)') {
                $raw = $matches[1]
                $resolved = Resolve-ImageReference $raw
                if (($raw -match 'LLM_COUNCIL_IMAGE_REGISTRY') -or ($resolved -match '^local/llm-council/')) { continue }
                $targets += $resolved
            }
        }
    }

    $dockerfiles = Get-ChildItem -Path $Root -Recurse -File -Filter "Dockerfile" -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IgnoredPath $_.FullName) }
    foreach ($file in $dockerfiles) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -match '^\s*FROM\s+(?:--platform=\S+\s+)?([^\s]+)') {
                $resolved = Resolve-ImageReference $matches[1]
                if ($resolved -ne "scratch") {
                    $targets += $resolved
                }
            }
        }
    }

    return ($targets | Sort-Object -Unique)
}

function ConvertTo-SafeFileName {
    param([string]$ImageRef)
    return (($ImageRef -replace '@sha256:', '_sha256_') -replace '[^A-Za-z0-9_.-]', '_') + ".cyclonedx.json"
}

try {
    & syft version 2>$null | Out-Null
} catch {
    Write-Host "ERROR: syft is not on PATH." -ForegroundColor Red
    Write-Host "Install Syft before running image SBOM validation."
    exit 2
}

Set-Location $RepoRoot
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$images = @(Get-ImageTargets -Root $RepoRoot)
if ($images.Count -eq 0) {
    Write-Host "No external image references found." -ForegroundColor Yellow
    exit 2
}

$failures = @()
foreach ($image in $images) {
    $target = Join-Path $OutputDir (ConvertTo-SafeFileName $image)
    Write-Host "Generating SBOM for $image"
    $json = & syft $image -o cyclonedx-json --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures += [PSCustomObject]@{ Image = $image; Error = (($json | ForEach-Object { [string]$_ }) -join "`n") }
        continue
    }

    $jsonText = ($json | ForEach-Object { [string]$_ }) -join "`n"
    try {
        $sbom = $jsonText | ConvertFrom-Json
    } catch {
        $failures += [PSCustomObject]@{ Image = $image; Error = "Invalid CycloneDX JSON: $($_.Exception.Message)" }
        continue
    }

    $components = @($sbom.components)
    if ($sbom.bomFormat -ne "CycloneDX" -or $components.Count -lt $MinimumComponents) {
        $failures += [PSCustomObject]@{ Image = $image; Error = "Unexpected SBOM shape: bomFormat=$($sbom.bomFormat), components=$($components.Count)" }
        continue
    }

    Set-Content -LiteralPath $target -Value $jsonText -Encoding UTF8
}

if ($failures.Count -gt 0) {
    Write-Host "Image SBOM generation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ("  {0}" -f $failure.Image) -ForegroundColor Red
        $summary = ($failure.Error -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 6) -join "`n      "
        if (-not [string]::IsNullOrWhiteSpace($summary)) {
            Write-Host ("      {0}" -f $summary) -ForegroundColor DarkGray
        }
    }
    exit 2
}

Write-Host ("Image SBOM OK: {0} SBOM file(s) generated under {1}." -f $images.Count, $OutputDir) -ForegroundColor Green
exit 0
