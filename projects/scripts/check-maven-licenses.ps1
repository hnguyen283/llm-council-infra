[CmdletBinding()]
param(
    # Where to look for the license inventory XML files. By default
    # walks every module's target/generated-resources/licenses.xml
    # under the repo root. The default is computed inside the script
    # body (not the param expression) so $PSScriptRoot is reliably set
    # before resolution under both Windows PowerShell 5.1 and 7.x.
    [string]$RepoRoot = $null
)

if ([string]::IsNullOrEmpty($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

# ----------------------------------------------------------------------
# check-maven-licenses.ps1 (P2.1, 2026-05-22)
#
# Walks every Maven module's target/generated-resources/licenses.xml,
# extracts the declared license(s) for each compile/runtime dependency,
# and fails (exit 1) if any license matches the deny list:
#
#   - AGPL-3.0      (Grafana, Loki, Redis 8 alternative)
#   - SSPL-1.0      (Redis 7.4+, MongoDB)
#   - RSALv2        (Redis 7.4+)
#   - Confluent Community License (cp-* Confluent images)
#   - Business Source License 1.1 (Redpanda, Dragonfly, MariaDB MaxScale)
#   - Elastic License (Elasticsearch 7.11+)
#
# Match is case-insensitive and matches the license name (LicenseRef
# style) AND any URL containing the license short-name. Both are checked
# because the upstream Maven POMs declare licenses inconsistently — some
# carry only a URL, some only a name, and the SPDX identifier is the
# narrowest reliable signal.
#
# To regenerate the inventory:
#   mvn -DskipTests verify
#
# Run on its own (after a verify):
#   projects\scripts\check-maven-licenses.cmd
# ----------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$denyPatterns = @(
    @{ Name = "AGPL-3.0";                          Regex = '(?i)(agpl[\s\-]*3|affero\s+general\s+public\s+license|agpl-3\.0)' },
    @{ Name = "SSPL-1.0";                          Regex = '(?i)(sspl[\s\-]*1|server\s+side\s+public\s+license)' },
    @{ Name = "RSALv2 (Redis Source Available)";   Regex = '(?i)(rsalv?2|redis\s+source\s+available)' },
    @{ Name = "Confluent Community License";       Regex = '(?i)(confluent\s+community\s+license|^ccl$|confluent-community)' },
    @{ Name = "Business Source License";           Regex = '(?i)(business\s+source\s+license|busl[\s\-]*1(?:\.1)?|bsl[\s\-]*1\.1)' },
    @{ Name = "Elastic License";                   Regex = '(?i)(elastic\s+license(?:\s+2)?|elastic-2|^elv?[12]$)' }
)

Set-Location $RepoRoot

$inventories = Get-ChildItem -Path . -Recurse -Filter "licenses.xml" -ErrorAction SilentlyContinue `
    | Where-Object { $_.FullName -match [Regex]::Escape("target\generated-resources\licenses.xml") }

if ($inventories.Count -eq 0) {
    Write-Host "No license inventory files found." -ForegroundColor Yellow
    Write-Host "Run ``mvn -DskipTests verify`` first to generate target/generated-resources/licenses.xml."
    exit 2
}

Write-Host ("Scanning {0} license inventory file(s)..." -f $inventories.Count)

$violations = @()
$totalDeps = 0

foreach ($inventory in $inventories) {
    [xml]$doc = Get-Content $inventory.FullName -Raw
    # licenses.xml structure:
    #   <licenseSummary><dependencies><dependency>
    #     <groupId>g</groupId><artifactId>a</artifactId><version>v</version>
    #     <licenses><license><name>n</name><url>u</url></license></licenses>
    #   </dependency></dependencies></licenseSummary>
    $deps = $doc.SelectNodes("//dependency")
    if (-not $deps) { continue }

    foreach ($dep in $deps) {
        $totalDeps += 1
        $gav = "$($dep.groupId):$($dep.artifactId):$($dep.version)"
        $licNodes = $dep.SelectNodes("licenses/license")
        if (-not $licNodes -or $licNodes.Count -eq 0) { continue }

        foreach ($lic in $licNodes) {
            $name = if ($lic.name) { [string]$lic.name } else { "" }
            $url  = if ($lic.url)  { [string]$lic.url  } else { "" }
            $hay  = "$name | $url"

            foreach ($deny in $denyPatterns) {
                if ($hay -match $deny.Regex) {
                    $violations += [PSCustomObject]@{
                        Module     = $inventory.Directory.Parent.Parent.Name
                        Dependency = $gav
                        Matched    = $deny.Name
                        License    = $hay
                    }
                    break
                }
            }
        }
    }
}

Write-Host ("Scanned {0} dependency rows across {1} module(s)." -f $totalDeps, $inventories.Count)

if ($violations.Count -gt 0) {
    Write-Host ""
    Write-Host "License deny-list violations detected:" -ForegroundColor Red
    foreach ($v in $violations) {
        Write-Host ("  [{0}] {1}" -f $v.Matched, $v.Dependency) -ForegroundColor Red
        Write-Host ("      license: {0}" -f $v.License) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "See llm-council-docs/technical/licensing.html for the deny list and the replacement programme." -ForegroundColor Red
    exit 1
}

Write-Host "Maven license deny-check OK across all scanned modules." -ForegroundColor Green
exit 0
