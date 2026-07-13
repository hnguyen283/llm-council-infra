param(
  [Parameter(Mandatory=$true)][string]$BaseUrl,
  [Parameter(Mandatory=$true)][string]$PlanFile,
  [int]$Concurrency = 100
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $PlanFile)) {
  throw "Plan file not found: $PlanFile"
}

$plan = Get-Content -Raw -Path $PlanFile | ConvertFrom-Json
if (-not $plan.tenants -or $plan.tenants.Count -lt 5) {
  throw "Plan file must contain at least five tenant entries."
}

$jobs = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $Concurrency; $i++) {
  $tenant = $plan.tenants[$i % $plan.tenants.Count]
  $body = @{
    query = "BP1.5 isolation proof query $i for tenant $($tenant.workspaceId)"
    locale = "en"
  } | ConvertTo-Json
  $jobs.Add([pscustomobject]@{
    Index = $i
    WorkspaceId = $tenant.workspaceId
    Token = $tenant.accessToken
    Body = $body
  })
}

$running = New-Object System.Collections.Generic.List[object]
$completed = New-Object System.Collections.Generic.List[object]
$throttle = [Math]::Min($Concurrency, 20)

foreach ($item in $jobs) {
  while ($running.Count -ge $throttle) {
    $done = Wait-Job -Job $running -Any
    $completed.AddRange(@($done))
    [void]$running.Remove($done)
  }
  $job = Start-Job -ScriptBlock {
    param($BaseUrl, $Item)
    $headers = @{
      Authorization = "Bearer $($Item.Token)"
      "X-Workspace-Id" = $Item.WorkspaceId
      "Content-Type" = "application/json"
    }
    try {
      $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/jobs" -Headers $headers -Body $Item.Body
      [pscustomobject]@{ Index = $Item.Index; WorkspaceId = $Item.WorkspaceId; Ok = $true; JobId = $response.jobId; Error = $null }
    } catch {
      [pscustomobject]@{ Index = $Item.Index; WorkspaceId = $Item.WorkspaceId; Ok = $false; JobId = $null; Error = $_.Exception.Message }
    }
  } -ArgumentList $BaseUrl, $item
  $running.Add($job)
}

while ($running.Count -gt 0) {
  $done = Wait-Job -Job $running -Any
  $completed.AddRange(@($done))
  [void]$running.Remove($done)
}

$results = @($completed | ForEach-Object {
  Receive-Job -Job $_
  Remove-Job -Job $_
} | Sort-Object Index)

$results | ConvertTo-Json -Depth 4
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
  Write-Error "$($failed.Count) of $Concurrency job submissions failed."
}
