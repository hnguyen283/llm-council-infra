param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)

$requirements = Join-Path $RepoRoot "graphrag-service\requirements.txt"
$lock = Join-Path $RepoRoot "graphrag-service\requirements.lock"

if (-not (Test-Path -LiteralPath $requirements)) {
    Write-Error "Missing GraphRAG requirements manifest: $requirements"
    exit 1
}

if (-not (Test-Path -LiteralPath $lock)) {
    Write-Error "Missing GraphRAG requirements lock: $lock"
    exit 1
}

function ConvertTo-PackageKey {
    param([string]$Name)
    return $Name.ToLowerInvariant().Replace("_", "-").Replace(".", "-")
}

$directPins = @{}
foreach ($line in Get-Content -LiteralPath $requirements) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
        continue
    }
    if ($trimmed -notmatch '^([A-Za-z0-9_.-]+)==([^;\s]+)(?:\s*;.*)?$') {
        Write-Error "requirements.txt contains a non-exact or unsupported requirement: $trimmed"
        exit 1
    }
    $directPins[(ConvertTo-PackageKey $matches[1])] = $matches[2]
}

$lockedPins = @{}
foreach ($line in Get-Content -LiteralPath $lock) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
        continue
    }
    if ($trimmed -notmatch '^([A-Za-z0-9_.-]+)==([^;\s]+)(?:\s*;.*)?$') {
        Write-Error "requirements.lock contains a non-exact or unsupported requirement: $trimmed"
        exit 1
    }
    $lockedPins[(ConvertTo-PackageKey $matches[1])] = $matches[2]
}

$errors = New-Object System.Collections.Generic.List[string]
foreach ($name in $directPins.Keys) {
    if (-not $lockedPins.ContainsKey($name)) {
        $errors.Add("Missing direct dependency in requirements.lock: $name==$($directPins[$name])")
        continue
    }
    if ($lockedPins[$name] -ne $directPins[$name]) {
        $errors.Add("Version mismatch for $name`: requirements.txt has $($directPins[$name]), requirements.lock has $($lockedPins[$name])")
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "GraphRAG requirements lock OK: $($directPins.Count) direct pin(s), $($lockedPins.Count) locked package(s)."
