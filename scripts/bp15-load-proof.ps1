param(
  [Parameter(Mandatory=$true)][string]$BaseUrl,
  [Parameter(Mandatory=$true)][string]$PlanFile,
  [Parameter(Mandatory=$true)][string]$EvidenceHmacKey,
  [int]$Concurrency = 100,
  [ValidateRange(1, 100)][int]$InFlightLimit = 5,
  [int]$TimeoutSeconds = 900,
  [int]$PollIntervalSeconds = 5,
  [switch]$SkipCrossTenantDenyCheck
)

$ErrorActionPreference = "Stop"

if ($TimeoutSeconds -le 0 -or $PollIntervalSeconds -le 0) {
  throw "TimeoutSeconds and PollIntervalSeconds must be positive."
}
if (-not (Test-Path -LiteralPath $PlanFile)) {
  throw "Plan file not found: $PlanFile"
}

$plan = Get-Content -Raw -Path $PlanFile | ConvertFrom-Json
if (-not $plan.tenants -or $plan.tenants.Count -lt 5) {
  throw "Plan file must contain at least five tenant entries."
}
foreach ($tenant in $plan.tenants) {
  if ([string]::IsNullOrWhiteSpace($tenant.workspaceId) -or [string]::IsNullOrWhiteSpace($tenant.accessToken)) {
    throw "Every tenant entry must provide workspaceId and accessToken."
  }
}

$script:reauthenticationCount = 0

function Get-EvidenceLabel([string]$Value) {
  $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($EvidenceHmacKey))
  try {
    $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    $hex = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    return "h_" + $hex.Substring(0, 16)
  } finally {
    $hmac.Dispose()
  }
}

function Get-ErrorCategory($ErrorRecord) {
  if ($null -ne $ErrorRecord.Exception.Response) {
    return "HTTP_ERROR"
  }
  if ($ErrorRecord.Exception -is [System.Net.WebException]) {
    return "TRANSPORT_ERROR"
  }
  return "REQUEST_ERROR"
}

function Get-JobSnapshot($BaseUrl, $Item) {
  try {
    $response = Invoke-TenantRequest "GET" "$BaseUrl/jobs/$($Item.JobId)" $Item.Tenant $null
    return [pscustomobject]@{ Ok = $true; State = [string]$response.state; ErrorCategory = $null }
  } catch {
    return [pscustomobject]@{ Ok = $false; State = $null; ErrorCategory = Get-ErrorCategory $_ }
  }
}

function Get-StatusCodeFromError($ErrorRecord) {
  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) { return $null }
  try { return [int]$response.StatusCode } catch { return $null }
}

function Renew-TenantAccess($BaseUrl, $Tenant) {
  if ([string]::IsNullOrWhiteSpace([string]$Tenant.username) -or
      [string]::IsNullOrWhiteSpace([string]$Tenant.password) -or
      [string]::IsNullOrWhiteSpace([string]$Tenant.deviceId)) {
    throw "Tenant access expired and the temporary plan does not contain reauthentication material."
  }
  $headers = @{ "Content-Type" = "application/json"; "X-Device-Id" = [string]$Tenant.deviceId }
  $body = @{ username = [string]$Tenant.username; password = [string]$Tenant.password } | ConvertTo-Json -Compress
  $login = Invoke-RestMethod -Method Post -Uri "$BaseUrl/auth/login" -Headers $headers -Body $body -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$login.accessToken)) {
    throw "Tenant reauthentication did not return an access token."
  }
  $Tenant.accessToken = [string]$login.accessToken
  $script:reauthenticationCount++
}

function Invoke-TenantRequest([string]$Method, [string]$Uri, $Tenant, $Body) {
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    $headers = @{
      Authorization = "Bearer $($Tenant.accessToken)"
      "X-Workspace-Id" = [string]$Tenant.workspaceId
    }
    if ($null -ne $Body) { $headers["Content-Type"] = "application/json" }
    try {
      if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $Body -ErrorAction Stop
      }
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
    } catch {
      if ($attempt -eq 0 -and (Get-StatusCodeFromError $_) -eq 401) {
        Renew-TenantAccess $BaseUrl $Tenant
        continue
      }
      throw
    }
  }
}

$jobs = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $Concurrency; $i++) {
  $tenant = $plan.tenants[$i % $plan.tenants.Count]
  $body = @{
    query = "BP1.5 isolation proof query $i"
    locale = "en"
  } | ConvertTo-Json
  $jobs.Add([pscustomobject]@{
    Index = $i
    Tenant = $tenant
    Body = $body
  })
}

$submittedLedger = New-Object System.Collections.Generic.List[object]
$active = New-Object System.Collections.Generic.List[object]
$nextIndex = 0
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while (($nextIndex -lt $jobs.Count -or $active.Count -gt 0) -and (Get-Date) -lt $deadline) {
  while ($nextIndex -lt $jobs.Count -and $active.Count -lt $InFlightLimit) {
    $item = $jobs[$nextIndex]
    try {
      $response = Invoke-TenantRequest "POST" "$BaseUrl/jobs" $Item.Tenant $Item.Body
      $accepted = [pscustomobject]@{
        Index = $Item.Index; Tenant = $Item.Tenant
        Accepted = $true; JobId = [string]$response.jobId; ErrorCategory = $null
        State = $null; StatusErrorCategory = $null
      }
      $submittedLedger.Add($accepted)
      $active.Add($accepted)
    } catch {
      $submittedLedger.Add([pscustomobject]@{
        Index = $Item.Index; Tenant = $Item.Tenant
        Accepted = $false; JobId = $null; ErrorCategory = Get-ErrorCategory $_
        State = "NOT_ACCEPTED"; StatusErrorCategory = $null
      })
    }
    $nextIndex++
  }

  $nextActive = New-Object System.Collections.Generic.List[object]
  foreach ($item in $active) {
    $snapshot = Get-JobSnapshot $BaseUrl $item
    $item.State = $snapshot.State
    $item.StatusErrorCategory = $snapshot.ErrorCategory
    if (-not $snapshot.Ok -or $snapshot.State -notin @("DONE", "FAILED", "CANCELED")) {
      $nextActive.Add($item)
    }
  }
  $active = $nextActive
  if (($nextIndex -lt $jobs.Count -or $active.Count -gt 0) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
  }
}

foreach ($item in $active) {
  $item.State = "TIMEOUT"
}

while ($nextIndex -lt $jobs.Count) {
  $item = $jobs[$nextIndex]
  $submittedLedger.Add([pscustomobject]@{
    Index = $Item.Index; Tenant = $Item.Tenant
    Accepted = $false; JobId = $null; ErrorCategory = "TIMEOUT"
    State = "NOT_ACCEPTED"; StatusErrorCategory = $null
  })
  $nextIndex++
}

$submitted = @($submittedLedger | Sort-Object Index)

foreach ($item in $submitted) {
  $item | Add-Member -NotePropertyName CrossTenantDenied -NotePropertyValue $null -Force
  if ($SkipCrossTenantDenyCheck -or -not $item.Accepted) { continue }

  $otherTenant = $plan.tenants | Where-Object { [string]$_.workspaceId -ne [string]$item.Tenant.workspaceId } | Select-Object -First 1
  if ($null -eq $otherTenant) { throw "No different tenant is available for cross-tenant denial verification." }
  try {
    Invoke-TenantRequest "GET" "$BaseUrl/jobs/$($item.JobId)" $otherTenant $null | Out-Null
    $item.CrossTenantDenied = $false
  } catch {
    $item.CrossTenantDenied = ((Get-StatusCodeFromError $_) -eq 404)
  }
}

$evidence = @($submitted | ForEach-Object {
  [pscustomobject]@{
    Index = $_.Index
    TenantLabel = Get-EvidenceLabel ([string]$_.Tenant.workspaceId)
    CorrelationLabel = if ($_.JobId) { Get-EvidenceLabel $_.JobId } else { $null }
    Accepted = $_.Accepted
    TerminalState = $_.State
    SubmissionErrorCategory = $_.ErrorCategory
    StatusErrorCategory = $_.StatusErrorCategory
    CrossTenantDenied = $_.CrossTenantDenied
  }
})

[pscustomobject]@{
  Summary = [pscustomobject]@{
    Requested = $Concurrency
    Accepted = @($evidence | Where-Object { $_.Accepted }).Count
    Done = @($evidence | Where-Object { $_.TerminalState -eq "DONE" }).Count
    CrossTenantDenied = @($evidence | Where-Object { $_.CrossTenantDenied -eq $true }).Count
    ReauthenticationCount = $script:reauthenticationCount
  }
  Rows = $evidence
} | ConvertTo-Json -Depth 5
$failed = @($evidence | Where-Object {
  -not $_.Accepted -or $_.TerminalState -ne "DONE" -or
  ((-not $SkipCrossTenantDenyCheck) -and $_.CrossTenantDenied -ne $true)
})
if ($failed.Count -gt 0) {
  Write-Error "$($failed.Count) of $Concurrency BP1.5 isolation-proof rows failed. Inspect only the sanitized JSON ledger above."
}
