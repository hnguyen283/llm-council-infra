[CmdletBinding()]
param(
    # The ref to diff against. Default: the merge base with origin/main.
    # Pass a specific SHA, branch, or tag to override (e.g. for CI:
    # the PR's base SHA, or the previous release tag).
    [string]$BaseRef = $null,

    # Path to the licensing.html file. Default resolves to the
    # sibling llm-council-docs directory at ..\..\llm-council-docs\technical\licensing.html
    # from the llm-council git root (multi-repo layout).
    [string]$LicensingHtmlPath = $null,

    # If set, exit 1 when relevant changes are detected and licensing.html
    # appears stale. Default: exit 0 with a warning (advisory mode).
    [switch]$Strict
)

# ----------------------------------------------------------------------
# check-licensing-docs-fresh.ps1 (P2.3, 2026-05-22)
#
# Fails (with -Strict) or warns (default) when a diff between
# $BaseRef..HEAD changes ANY of:
#
#   - llm-council/pom.xml (or any module pom.xml)
#   - llm-council/projects/*/docker-compose.yml `image:` lines
#     (or any overlay's `image:` line)
#
# without llm-council-docs/technical/licensing.html being up-to-date.
#
# Multi-repo layout note (D:\Project\LLM Council\):
#   The llm-council/ directory is its own git repo; the llm-council-docs/
#   directory lives as a sibling and is NOT inside the llm-council
#   git tree. The two Angular UIs (llm-council-ui, llm-council-admin-ui)
#   are ALSO their own git repos. So `git diff` from inside llm-council
#   cannot directly observe llm-council-docs/ or UI-side package.json bumps.
#
#   What this script does:
#     1. Scope the diff to the llm-council git tree only.
#     2. Detect pom.xml changes and Compose `image:` line changes there.
#     3. Compare the modification timestamp of
#        ..\..\llm-council-docs\technical\licensing.html against the timestamp
#        of the most recent llm-council commit that touched a relevant
#        file. If licensing.html is older, flag it as stale.
#
#   What this script does NOT do:
#     - It does not verify package.json bumps in the UI repos
#       (run each UI's `npm run license-check` for that — P2.1).
#     - It does not run inside llm-council-docs (no git history there).
#     - It cannot enforce a hard CI gate across the repo boundary
#       unless the CI job has access to both repos simultaneously.
#
# Exit codes:
#   0 — no relevant changes, OR licensing.html is fresh, OR not -Strict
#   1 — relevant changes detected, licensing.html appears stale, and -Strict was passed
#   2 — environmental error (git failure, missing file, etc.)
#
# Recommended invocation:
#   projects\scripts\check-licensing-docs-fresh.cmd             (advisory)
#   projects\scripts\check-licensing-docs-fresh.cmd -Strict     (CI gate)
# ----------------------------------------------------------------------

# Use "Continue" (not "Stop") globally because native `git` writes
# benign warnings (LF/CRLF, etc.) to stderr. In Windows PowerShell 5.1
# those would be wrapped as terminating NativeCommandError records
# under "Stop" and short-circuit the whole script even when git
# returned exit code 0. We rely on $LASTEXITCODE for git's real status.
$ErrorActionPreference = "Continue"

# llm-council/ git root (the script lives at projects/scripts/ relative to it).
$llmCouncilRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $llmCouncilRoot

# Verify we're inside a git repo.
$gitRoot = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: $llmCouncilRoot is not a git repository." -ForegroundColor Red
    exit 2
}

# Default licensing.html path: ../llm-council-docs/technical/licensing.html
# relative to the llm-council git root.
if ([string]::IsNullOrEmpty($LicensingHtmlPath)) {
    $LicensingHtmlPath = (Join-Path $llmCouncilRoot "..\llm-council-docs\technical\licensing.html")
}
$resolvedLicensingHtmlPath = $null
if (Test-Path $LicensingHtmlPath) {
    $resolvedLicensingHtmlPath = (Resolve-Path $LicensingHtmlPath).Path
}

# Default base ref: merge-base against origin/main, fall back to HEAD~1.
if ([string]::IsNullOrEmpty($BaseRef)) {
    try {
        $BaseRef = (& git merge-base HEAD origin/main 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($BaseRef)) {
            throw "no origin/main"
        }
    } catch {
        $BaseRef = "HEAD~1"
    }
}

Write-Host ("Diff base: {0}" -f $BaseRef)
$licensingDisplay = if ($resolvedLicensingHtmlPath) { $resolvedLicensingHtmlPath } else { "<not found at $LicensingHtmlPath>" }
Write-Host ("Licensing.html: {0}" -f $licensingDisplay)

# All changed files between the base ref and the WORKING TREE (not
# just committed history). This covers both:
#   - CI mode: PR's working tree (post-checkout, all changes committed)
#   - Local pre-commit mode: uncommitted edits the developer hasn't
#     pushed yet — we want to catch those BEFORE they ship.
$changedFiles = & git diff --name-only "$BaseRef" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ("ERROR: git diff against {0} failed." -f $BaseRef) -ForegroundColor Red
    exit 2
}
if ($null -eq $changedFiles -or @($changedFiles).Count -eq 0) {
    Write-Host "No files changed in the diff range. Nothing to check." -ForegroundColor Green
    exit 0
}

# Categorise relevant changes.
$pomChanges    = @($changedFiles | Where-Object { $_ -match '(?:^|/)pom\.xml$' })
$composeFiles  = @($changedFiles | Where-Object { $_ -match 'projects/[^/]+/(?:docker-compose\.yml|overlays/[^/]+\.yml)$' })

# For Compose files, only flag if the diff actually changed an `image:` line.
$composeImageBumps = New-Object System.Collections.Generic.List[string]
foreach ($cf in $composeFiles) {
    $diff = & git diff "$BaseRef" -- "$cf" 2>$null
    if ($LASTEXITCODE -ne 0) { continue }
    foreach ($line in $diff) {
        if ($line -match '^[+-]\s*image:\s*\S+') {
            $composeImageBumps.Add($cf) | Out-Null
            break
        }
    }
}

$relevantChanges = New-Object System.Collections.Generic.List[string]
foreach ($f in $pomChanges)        { $relevantChanges.Add($f) | Out-Null }
foreach ($f in $composeImageBumps) { $relevantChanges.Add($f) | Out-Null }

if ($relevantChanges.Count -eq 0) {
    Write-Host "No pom.xml / Compose `image:` changes detected in the llm-council tree." -ForegroundColor Green
    Write-Host "(Reminder: this script does NOT cover UI-side package.json bumps; run"
    Write-Host " `npm run license-check` in llm-council-ui and llm-council-admin-ui for those.)"
    exit 0
}

Write-Host ""
Write-Host "Relevant changes detected in the llm-council git tree:" -ForegroundColor Yellow
foreach ($f in ($relevantChanges | Sort-Object -Unique)) {
    Write-Host ("  - {0}" -f $f)
}

if (-not $resolvedLicensingHtmlPath) {
    Write-Host ""
    Write-Host "WARNING: llm-council-docs/technical/licensing.html not found at the expected sibling path." -ForegroundColor Yellow
    Write-Host "Pass -LicensingHtmlPath to point at it explicitly, or move llm-council-docs/ into the llm-council tree."
    if ($Strict) { exit 1 } else { exit 0 }
}

# Heuristic freshness check: licensing.html mtime vs the timestamp of
# the most recent commit that touched a relevant file. Git checkouts
# reset file mtimes to the checkout time, so this is best-effort —
# it catches the case where a developer locally bumps pom.xml or a
# Compose image but forgets to also touch licensing.html, but it
# does not catch the case where licensing.html was touched in a
# separate commit on a separate branch.
$mostRecentRelevantTs = $null
foreach ($f in $relevantChanges) {
    $ts = & git log -1 --format=%ct -- "$f" 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($ts)) {
        $tsInt = [int64]$ts
        if ($null -eq $mostRecentRelevantTs -or $tsInt -gt $mostRecentRelevantTs) {
            $mostRecentRelevantTs = $tsInt
        }
    }
}

$licensingHtmlMtime = (Get-Item $resolvedLicensingHtmlPath).LastWriteTimeUtc
$licensingHtmlTs = [DateTimeOffset]::new($licensingHtmlMtime, [TimeSpan]::Zero).ToUnixTimeSeconds()

Write-Host ""
Write-Host ("Most recent relevant llm-council commit timestamp: {0}" -f $mostRecentRelevantTs)
Write-Host ("llm-council-docs/technical/licensing.html mtime (unix):    {0}" -f $licensingHtmlTs)

if ($null -ne $mostRecentRelevantTs -and $licensingHtmlTs -lt $mostRecentRelevantTs) {
    Write-Host ""
    Write-Host "STALE: licensing.html mtime is older than the most recent relevant llm-council commit." -ForegroundColor Red
    Write-Host "Please update llm-council-docs/technical/licensing.html to reflect the dependency/image bump,"
    Write-Host "or explicitly add a comment in licensing.html noting that the bump does not change any"
    Write-Host "inventory row (e.g. for a same-license patch-version bump)."
    Write-Host ""
    Write-Host "(Cross-repo limitation: this script cannot diff licensing.html because llm-council-docs/ lives"
    Write-Host " outside the llm-council git tree. The check above is heuristic, based on file mtime.)"
    if ($Strict) { exit 1 } else { exit 0 }
}

Write-Host ""
Write-Host "OK: llm-council-docs/technical/licensing.html mtime is at or after the most recent relevant commit." -ForegroundColor Green
exit 0
