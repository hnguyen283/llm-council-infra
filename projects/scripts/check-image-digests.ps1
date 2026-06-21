[CmdletBinding()]
param(
    [string]$RepoRoot = $null
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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

function Get-ComposeImageTargets {
    param([string]$Root)
    $targets = @()
    $files = Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Extension -eq ".yml" -or $_.Extension -eq ".yaml") -and -not (Test-IgnoredPath $_.FullName) }

    foreach ($file in $files) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -match '^\s*image:\s*([^\s#]+)') {
                $raw = $matches[1]
                $resolved = Resolve-ImageReference $raw
                $projectBuilt = (($raw -match 'LLM_COUNCIL_IMAGE_REGISTRY') -or ($resolved -match '^local/llm-council/'))
                $targets += [PSCustomObject]@{
                    Image        = $resolved
                    Raw          = $raw
                    Source       = $file.FullName.Substring($Root.Length + 1)
                    ProjectBuilt = $projectBuilt
                }
            }
        }
    }

    return ,$targets
}

function Get-DockerfileBaseTargets {
    param([string]$Root)
    $targets = @()
    $files = Get-ChildItem -Path $Root -Recurse -File -Filter "Dockerfile" -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IgnoredPath $_.FullName) }

    foreach ($file in $files) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -match '^\s*FROM\s+(?:--platform=\S+\s+)?([^\s]+)') {
                $raw = $matches[1]
                $resolved = Resolve-ImageReference $raw
                if ($resolved -eq "scratch") { continue }
                $targets += [PSCustomObject]@{
                    Image        = $resolved
                    Raw          = $raw
                    Source       = $file.FullName.Substring($Root.Length + 1)
                    ProjectBuilt = $false
                }
            }
        }
    }

    return ,$targets
}

Set-Location $RepoRoot

$targets = @((Get-ComposeImageTargets -Root $RepoRoot) + (Get-DockerfileBaseTargets -Root $RepoRoot))
$seen = New-Object System.Collections.Generic.HashSet[string]
$externalTargets = @()

foreach ($target in $targets) {
    if ($target.ProjectBuilt) { continue }
    $key = "$($target.Image)|$($target.Source)"
    if ($seen.Add($key)) {
        $externalTargets += $target
    }
}

$missing = @()
foreach ($target in $externalTargets) {
    if ($target.Image -notmatch '@sha256:[a-fA-F0-9]{64}$') {
        $missing += $target
    }
}

if ($missing.Count -gt 0) {
    Write-Host "External image references without digest pins:" -ForegroundColor Red
    foreach ($target in $missing) {
        Write-Host ("  {0}: {1}" -f $target.Source, $target.Raw) -ForegroundColor Red
    }
    exit 1
}

Write-Host ("Image digest pin check OK: {0} external reference(s) are pinned." -f $externalTargets.Count) -ForegroundColor Green
exit 0
