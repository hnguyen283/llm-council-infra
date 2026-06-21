param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
)

$lock = Join-Path $RepoRoot "graphrag-service\requirements.lock"
if (-not (Test-Path -LiteralPath $lock)) {
    Write-Error "Missing GraphRAG requirements lock: $lock"
    exit 1
}

$pipAudit = Get-Command pip-audit -ErrorAction SilentlyContinue
if ($pipAudit) {
    & $pipAudit.Source --requirement $lock --strict
    exit $LASTEXITCODE
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('pip_audit') else 1)"
    if ($LASTEXITCODE -eq 0) {
        & $python.Source -m pip_audit --requirement $lock --strict
        exit $LASTEXITCODE
    }
}

Write-Host "ERROR: No supported Python vulnerability scanner is available. Install pip-audit and rerun this script." -ForegroundColor Red
Write-Host "Suggested: python -m pip install pip-audit"
exit 2
