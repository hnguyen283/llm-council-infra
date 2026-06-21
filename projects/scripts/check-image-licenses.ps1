[CmdletBinding()]
param(
    # Repository root. By default, two levels up from this script.
    [string]$RepoRoot = $null,

    # Explicit image override (use for testing a single image without
    # walking the Compose project files).
    [string]$Image = $null
)

# ----------------------------------------------------------------------
# check-image-licenses.ps1 (P2.2, 2026-05-22)
#
# Walks every `image:` value pinned in projects/*/docker-compose.yml,
# runs Syft against each one to produce an SBOM, and fails (exit 1) if
# any package's declared license matches the deny list:
#
#   - AGPL-3.0       (Grafana, Loki, Redis 8 alternative)
#   - SSPL-1.0       (Redis 7.4+, MongoDB, Elasticsearch 7.11+)
#   - RSALv2         (Redis 7.4+)
#   - Confluent Community License (cp-* Confluent images)
#   - Business Source License 1.1 (Redpanda, Dragonfly, MariaDB MaxScale)
#   - Elastic License (Elasticsearch 7.11+)
#
# Prerequisite: `syft` (https://github.com/anchore/syft) on PATH.
# Install on Windows: scoop install syft  /  or grab the release binary.
#
# Note: this script reports per-package licenses; some base images
# bundle many OS packages and a small number of GPL-2.0 / LGPL kernel
# bits is expected and NOT on the deny list above (those are weak
# copyleft, not network copyleft). The deny list is specifically the
# licenses that block the project's distribution / SaaS model — the
# same set the Compose validator's image-name deny check covers, but
# evaluated at the package-license level inside the image rather than
# at the image-tag level outside it.
#
# Runnable on its own:
#   projects\scripts\check-image-licenses.cmd
# Test against one image:
#   projects\scripts\check-image-licenses.cmd -Image valkey/valkey:8.1-alpine
# ----------------------------------------------------------------------

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$denyPatterns = @(
    '(?i)agpl[\s\-]*3',
    '(?i)affero',
    '(?i)sspl[\s\-]*1',
    '(?i)server\s+side\s+public\s+license',
    '(?i)rsalv?2',
    '(?i)redis\s+source\s+available',
    '(?i)confluent\s+community',
    '(?i)business\s+source\s+license',
    '(?i)\bbusl[\s\-]*1(?:\.1)?\b',
    '(?i)\bbsl[\s\-]*1\.1\b',
    '(?i)elastic\s+license',
    '(?i)elastic-2'
)

function Test-SyftAvailable {
    try {
        & syft version 2>$null | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-PinnedImages {
    param([string]$Root)
    $images = New-Object System.Collections.Generic.HashSet[string]
    $targets = @()
    $composeFiles = Get-ChildItem -Path (Join-Path $Root "projects") -Recurse -Filter "*.yml" -ErrorAction SilentlyContinue `
        | Where-Object { $_.FullName -match '\\projects\\[^\\]+\\(docker-compose|overlays\\[^\\]+)\.yml$' }
    foreach ($f in $composeFiles) {
        $content = Get-Content $f.FullName
        foreach ($line in $content) {
            if ($line -match '^\s*image:\s*([^\s#]+)') {
                $rawImage = $matches[1]
                $resolvedImage = Resolve-ImageReference $rawImage
                if ($images.Add($resolvedImage)) {
                    $targets += [PSCustomObject]@{
                        Image   = $resolvedImage
                        Raw     = $rawImage
                        Project = (($rawImage -match 'LLM_COUNCIL_IMAGE_REGISTRY') -or ($resolvedImage -match '^local/llm-council/'))
                    }
                }
            }
        }
    }
    return ,$targets
}

function Get-DockerfileBaseImages {
    param([string]$Root)
    $images = New-Object System.Collections.Generic.HashSet[string]
    $targets = @()
    $dockerfiles = Get-ChildItem -Path $Root -Recurse -File -Filter "Dockerfile" -ErrorAction SilentlyContinue `
        | Where-Object { $_.FullName -notmatch '\\target\\|\\node_modules\\' }

    foreach ($f in $dockerfiles) {
        $content = Get-Content $f.FullName
        foreach ($line in $content) {
            if ($line -match '^\s*FROM\s+(?:--platform=\S+\s+)?([^\s]+)') {
                $image = Resolve-ImageReference $matches[1]
                if ($image -eq "scratch") { continue }
                if ($images.Add($image)) {
                    $targets += [PSCustomObject]@{
                        Image   = $image
                        Raw     = $matches[1]
                        Project = $false
                    }
                }
            }
        }
    }

    return ,$targets
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

function Test-ImageLicenses {
    param([string]$ImageRef)
    Write-Host "  Scanning $ImageRef ..."
    $json = & syft $ImageRef -o json --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    syft failed: exit $LASTEXITCODE" -ForegroundColor Yellow
        return [PSCustomObject]@{
            Image      = $ImageRef
            Violations = @()
            Error      = (($json | ForEach-Object { [string]$_ }) -join "`n")
        }
    }

    try {
        $sbom = $json -join "`n" | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            Image      = $ImageRef
            Violations = @()
            Error      = "Syft returned invalid JSON: $($_.Exception.Message)"
        }
    }

    $violations = @()
    if ($null -eq $sbom.artifacts) {
        return [PSCustomObject]@{
            Image      = $ImageRef
            Violations = $violations
            Error      = $null
        }
    }

    foreach ($artifact in $sbom.artifacts) {
        if ($null -eq $artifact.licenses) { continue }
        foreach ($lic in $artifact.licenses) {
            # Syft can report license as either a string or an object
            # with `value` / `spdxExpression` fields, depending on the
            # cataloguer. Normalise to a single string for matching.
            $licValue = $null
            if ($lic -is [string]) {
                $licValue = $lic
            } elseif ($null -ne $lic.value) {
                $licValue = [string]$lic.value
            } elseif ($null -ne $lic.spdxExpression) {
                $licValue = [string]$lic.spdxExpression
            }
            if ([string]::IsNullOrEmpty($licValue)) { continue }
            foreach ($pat in $denyPatterns) {
                if ($licValue -match $pat) {
                    $violations += [PSCustomObject]@{
                        Image    = $ImageRef
                        Package  = "$($artifact.name)@$($artifact.version)"
                        License  = $licValue
                        Matched  = $pat
                    }
                    break
                }
            }
        }
    }
    return [PSCustomObject]@{
        Image      = $ImageRef
        Violations = $violations
        Error      = $null
    }
}

if (-not (Test-SyftAvailable)) {
    Write-Host "ERROR: syft is not on PATH." -ForegroundColor Red
    Write-Host "Install from https://github.com/anchore/syft (or `scoop install syft` on Windows)."
    exit 2
}

Set-Location $RepoRoot

$targets = @()
if (-not [string]::IsNullOrEmpty($Image)) {
    $targets = ,([PSCustomObject]@{ Image = (Resolve-ImageReference $Image); Raw = $Image; Project = $false })
} else {
    $images = @((Get-PinnedImages -Root $RepoRoot) + (Get-DockerfileBaseImages -Root $RepoRoot))
    if ($images.Count -eq 0) {
        Write-Host "No pinned Compose `image:` or Dockerfile `FROM` values found." -ForegroundColor Yellow
        exit 2
    }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $targets = @()
    foreach ($img in $images) {
        if ($seen.Add($img.Image)) {
            $targets += $img
        }
    }
}

$projectImages = @($targets | Where-Object { $_.Project })
$scanTargets = @($targets | Where-Object { -not $_.Project })

foreach ($img in $projectImages) {
    Write-Host ("Skipping project-built image {0}; scan its Dockerfile base image and Maven/npm dependencies separately." -f $img.Image) -ForegroundColor DarkGray
}

Write-Host ("Scanning {0} image(s)..." -f $scanTargets.Count)
$allViolations = @()
$scanFailures = @()
foreach ($img in $scanTargets) {
    $result = Test-ImageLicenses -ImageRef $img.Image
    if ($null -ne $result.Error) {
        $scanFailures += $result
    }
    if ($null -ne $result.Violations -and $result.Violations.Count -gt 0) {
        $allViolations += $result.Violations
    }
}

if ($scanFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "Image scan failures detected:" -ForegroundColor Red
    foreach ($failure in $scanFailures) {
        Write-Host ("  [image: {0}] Syft could not produce an SBOM." -f $failure.Image) -ForegroundColor Red
        $summary = ($failure.Error -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 6) -join "`n      "
        if (-not [string]::IsNullOrWhiteSpace($summary)) {
            Write-Host ("      {0}" -f $summary) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Fix the image reference or scanner environment before trusting this license gate." -ForegroundColor Red
    exit 2
}

if ($allViolations.Count -gt 0) {
    Write-Host ""
    Write-Host "Image-package license deny-list violations:" -ForegroundColor Red
    foreach ($v in $allViolations) {
        Write-Host ("  [image: {0}] {1} -> {2}" -f $v.Image, $v.Package, $v.License) -ForegroundColor Red
        Write-Host ("      matched pattern: /{0}/" -f $v.Matched) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "See llm-council-docs/technical/licensing.html for the deny list and the replacement programme." -ForegroundColor Red
    exit 1
}

Write-Host "Image-package license deny-check OK across all scanned images." -ForegroundColor Green
exit 0
