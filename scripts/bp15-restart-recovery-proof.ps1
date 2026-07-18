param(
  [string]$BaseUrl = "http://127.0.0.1:8080",
  [string]$PostgresContainer = "llm-council-standard-postgres-1",
  [string]$OrchestratorContainer = "llm-council-standard-orchestrator-service-1",
  [string]$ValkeyContainer = "llm-council-standard-valkey-1",
  [ValidateRange(1, 10)][int]$ProbeJobCount = 5,
  [ValidateRange(60, 600)][int]$RecoveryTimeoutSeconds = 360
)

$ErrorActionPreference = "Stop"
$nonce = [Guid]::NewGuid().ToString("N")
$password = "bp15-" + [Guid]::NewGuid().ToString("N")
$deviceId = "bp15-restart-device-" + $nonce.Substring(0, 12)
$databaseName = $null
$databaseUser = $null
$adminId = [Guid]::NewGuid().ToString()
$adminUser = "bp15restartadmin_" + $nonce.Substring(0, 12)
$adminEmail = $adminUser + "@example.invalid"
$adminTenantKey = "t_" + $adminId.Replace("-", "")
$user = $null
$adminLogin = $null
$jobIds = New-Object System.Collections.Generic.List[string]

function Assert-LastExitCode([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Invoke-Psql([string]$Sql) {
  & docker exec $PostgresContainer psql -U $script:databaseUser -d $script:databaseName -v ON_ERROR_STOP=1 -qAt -c ("SET search_path TO account; " + $Sql)
  Assert-LastExitCode "Postgres query"
}

function Invoke-Api([string]$Method, [string]$Path, $Body, [string]$Token, [string]$WorkspaceId, [string]$RequestDeviceId) {
  $headers = @{}
  if ($Token) { $headers.Authorization = "Bearer $Token" }
  if ($WorkspaceId) { $headers["X-Workspace-Id"] = $WorkspaceId }
  if ($RequestDeviceId) { $headers["X-Device-Id"] = $RequestDeviceId }
  if ($null -ne $Body) {
    $headers["Content-Type"] = "application/json"
    return Invoke-RestMethod -Method $Method -Uri ($BaseUrl + $Path) -Headers $headers -Body ($Body | ConvertTo-Json -Compress) -ErrorAction Stop
  }
  return Invoke-RestMethod -Method $Method -Uri ($BaseUrl + $Path) -Headers $headers -ErrorAction Stop
}

function Get-StatusCode($ErrorRecord) {
  if ($null -eq $ErrorRecord.Exception.Response) { return $null }
  try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return $null }
}

function Get-JwtSid([string]$Token) {
  $parts = $Token.Split('.')
  if ($parts.Count -ne 3) { throw "Access token is not a compact JWT." }
  $payload = $parts[1].Replace('-', '+').Replace('_', '/')
  switch ($payload.Length % 4) {
    2 { $payload += "==" }
    3 { $payload += "=" }
  }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
  return [string](($json | ConvertFrom-Json).sid)
}

function Wait-OrchestratorHealthy {
  $deadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $OrchestratorContainer 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and $status -eq "healthy") { return }
    Start-Sleep -Seconds 5
  }
  throw "Orchestrator did not become healthy after restart."
}

function Restart-Orchestrator {
  & docker restart $OrchestratorContainer | Out-Null
  Assert-LastExitCode "Orchestrator restart"
  Wait-OrchestratorHealthy
}

function Get-ValkeyPassword {
  $lines = & docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $ValkeyContainer
  Assert-LastExitCode "Inspect Valkey environment"
  foreach ($line in $lines) {
    if ($line.StartsWith("VALKEY_PASSWORD=")) { return $line.Substring(16) }
  }
  throw "VALKEY_PASSWORD is unavailable."
}

try {
  $databaseName = (& docker exec $PostgresContainer printenv POSTGRES_DB).Trim()
  Assert-LastExitCode "Postgres database discovery"
  $databaseUser = (& docker exec $PostgresContainer printenv POSTGRES_USER).Trim()
  Assert-LastExitCode "Postgres user discovery"

  $adminSql = "INSERT INTO accounts (id, username, email, password_hash, hash_algorithm, status) VALUES ('$adminId', '$adminUser', '$adminEmail', public.crypt('password', public.gen_salt('bf', 12)), 'BCRYPT', 'ACTIVE'); INSERT INTO account_roles (account_id, role_id) SELECT '$adminId', id FROM roles WHERE name = 'ADMIN'; INSERT INTO tenant (id, name, type, tenant_key) VALUES ('$adminId', 'BP1.5 Restart Probe Admin', 'PERSONAL', '$adminTenantKey'); INSERT INTO tenant_membership (tenant_id, account_id, role) VALUES ('$adminId', '$adminId', 'OWNER'); INSERT INTO billing_profile (tenant_id) VALUES ('$adminId');"
  Invoke-Psql $adminSql | Out-Null
  $adminLogin = Invoke-Api "POST" "/auth/login" @{ username = $adminUser; password = "password" } $null $null ("bp15-restart-admin-device-" + $nonce.Substring(0, 12))

  $suffix = $nonce.Substring(0, 12)
  $created = Invoke-Api "POST" "/admin/accounts" @{
    username = "bp15restart_$suffix"
    email = "bp15restart_$suffix@example.invalid"
    password = $password
    roles = @("USER")
  } $adminLogin.accessToken $null $null
  $login = Invoke-Api "POST" "/auth/login" @{ username = $created.username; password = $password } $null $null $deviceId
  $sidBeforeRestart = Get-JwtSid ([string]$login.accessToken)
  $workspaces = @(Invoke-Api "GET" "/me/workspaces" $null $login.accessToken $null $null)
  if ($workspaces.Count -ne 1) { throw "Restart probe user does not have exactly one workspace." }
  $user = [pscustomobject]@{
    AccountId = [string]$created.id
    Username = [string]$created.username
    Token = [string]$login.accessToken
    WorkspaceId = [string]$workspaces[0].tenantId
  }

  # Container health can precede gateway/Eureka route convergence. Prove the
  # authenticated job route is ready with a non-mutating missing-job lookup
  # before accepting any probe workload, avoiding ambiguous POST retries.
  $routeReady = $false
  $routeDeadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)
  $missingJobId = "bp15-route-ready-" + $nonce
  while ((Get-Date) -lt $routeDeadline) {
    try {
      Invoke-Api "GET" ("/jobs/" + $missingJobId) $null $user.Token $user.WorkspaceId $null | Out-Null
    } catch {
      $status = Get-StatusCode $_
      if ($status -eq 404) {
        $routeReady = $true
        break
      }
      if ($status -eq 401) {
        try {
          $login = Invoke-Api "POST" "/auth/login" @{ username = $user.Username; password = $password } $null $null $deviceId
          $user.Token = [string]$login.accessToken
        } catch {
          # Route convergence remains bounded by the deadline.
        }
      }
    }
    Start-Sleep -Seconds 5
  }
  if (-not $routeReady) { throw "Authenticated job route did not become ready." }

  for ($i = 0; $i -lt $ProbeJobCount; $i++) {
    $accepted = Invoke-Api "POST" "/jobs" @{ query = "BP1.5 restart recovery probe $i"; locale = "en" } $user.Token $user.WorkspaceId $null
    if ([string]::IsNullOrWhiteSpace([string]$accepted.jobId)) { throw "Restart probe job was not accepted." }
    $jobIds.Add([string]$accepted.jobId)
  }

  $jobIdList = ($jobIds | ForEach-Object { "'$_'" }) -join ","
  $activeBeforeRestart = [int](Invoke-Psql "SELECT count(*) FROM usage_requests ur JOIN usage_reservations r ON r.request_uid = ur.request_uid WHERE ur.job_id IN ($jobIdList) AND ur.status = 'RESERVED' AND r.status = 'ACTIVE';")
  if ($activeBeforeRestart -ne $ProbeJobCount) {
    throw "Restart probe did not capture every job with an active reservation."
  }

  Restart-Orchestrator

  # Reuse the same device identity so the session id embedded in the recovered
  # job remains stable if the short-lived access JWT needs renewal.
  $login = Invoke-Api "POST" "/auth/login" @{ username = $user.Username; password = $password } $null $null $deviceId
  $user.Token = [string]$login.accessToken
  $sessionStableAfterRestart = $sidBeforeRestart -eq (Get-JwtSid $user.Token)

  $deadline = (Get-Date).AddSeconds($RecoveryTimeoutSeconds)
  $terminalJobs = 0; $failedUsage = 0; $releasedReservations = 0; $completedOutbox = 0
  $lastJobReadStatus = $null
  while ((Get-Date) -lt $deadline) {
    $terminalJobs = 0
    foreach ($jobId in $jobIds) {
      try {
        $snapshot = Invoke-Api "GET" ("/jobs/" + $jobId) $null $user.Token $user.WorkspaceId $null
        $lastJobReadStatus = 200
        if ([string]$snapshot.state -eq "FAILED") { $terminalJobs++ }
      } catch {
        $lastJobReadStatus = Get-StatusCode $_
        if ($lastJobReadStatus -eq 401) {
          # Access JWTs are intentionally short-lived. Preserve the device
          # identity (and therefore the session identity that owns the job)
          # while discovery/recovery converges.
          try {
            $login = Invoke-Api "POST" "/auth/login" @{ username = $user.Username; password = $password } $null $null $deviceId
            $user.Token = [string]$login.accessToken
            $sessionStableAfterRestart = $sessionStableAfterRestart -and
                ($sidBeforeRestart -eq (Get-JwtSid $user.Token))
            $snapshot = Invoke-Api "GET" ("/jobs/" + $jobId) $null $user.Token $user.WorkspaceId $null
            $lastJobReadStatus = 200
            if ([string]$snapshot.state -eq "FAILED") { $terminalJobs++ }
          } catch {
            $lastJobReadStatus = Get-StatusCode $_
            # Startup/discovery convergence is bounded by the deadline.
          }
        }
      }
    }
    $failedUsage = [int](Invoke-Psql "SELECT count(*) FROM usage_requests WHERE job_id IN ($jobIdList) AND status = 'FAILED';")
    $releasedReservations = [int](Invoke-Psql "SELECT count(*) FROM usage_reservations r JOIN usage_requests ur ON ur.request_uid = r.request_uid WHERE ur.job_id IN ($jobIdList) AND r.status = 'RELEASED';")
    $completedOutbox = [int](Invoke-Psql "SELECT count(*) FROM usage_reconciliation_outbox WHERE job_id IN ($jobIdList) AND lower(status) = 'failed' AND state = 'COMPLETED';")
    if ($terminalJobs -eq $ProbeJobCount -and $failedUsage -eq $ProbeJobCount -and
        $releasedReservations -eq $ProbeJobCount -and $completedOutbox -eq $ProbeJobCount) {
      break
    }
    Start-Sleep -Seconds 5
  }
  if ($terminalJobs -ne $ProbeJobCount -or $failedUsage -ne $ProbeJobCount -or
      $releasedReservations -ne $ProbeJobCount -or $completedOutbox -ne $ProbeJobCount) {
    throw "Restart recovery did not converge: jobs=$terminalJobs usage=$failedUsage reservations=$releasedReservations outbox=$completedOutbox lastHttp=$lastJobReadStatus sessionStable=$sessionStableAfterRestart."
  }

  $outboxBeforeSecondRestart = [int](Invoke-Psql "SELECT count(*) FROM usage_reconciliation_outbox WHERE job_id IN ($jobIdList);")
  if ($outboxBeforeSecondRestart -ne $ProbeJobCount) { throw "Reconciliation outbox contains duplicate probe rows." }
  Restart-Orchestrator
  for ($retryCycle = 0; $retryCycle -lt 13; $retryCycle++) { Start-Sleep -Seconds 5 }
  $outboxAfterSecondRestart = [int](Invoke-Psql "SELECT count(*) FROM usage_reconciliation_outbox WHERE job_id IN ($jobIdList);")
  $failedUsageAfterSecondRestart = [int](Invoke-Psql "SELECT count(*) FROM usage_requests WHERE job_id IN ($jobIdList) AND status = 'FAILED';")
  $releasedAfterSecondRestart = [int](Invoke-Psql "SELECT count(*) FROM usage_reservations r JOIN usage_requests ur ON ur.request_uid = r.request_uid WHERE ur.job_id IN ($jobIdList) AND r.status = 'RELEASED';")
  if ($outboxAfterSecondRestart -ne $ProbeJobCount -or
      $failedUsageAfterSecondRestart -ne $ProbeJobCount -or
      $releasedAfterSecondRestart -ne $ProbeJobCount) {
    throw "Second restart changed exactly-once recovery accounting."
  }

  $valkeyPassword = Get-ValkeyPassword
  $failureMarkers = 0
  foreach ($jobId in $jobIds) {
    $exists = & docker exec $ValkeyContainer valkey-cli --no-auth-warning -a $valkeyPassword --raw EXISTS ("reconcile-failed:" + $jobId)
    Assert-LastExitCode "Valkey reconciliation marker query"
    $failureMarkers += [int]$exists
  }
  if ($failureMarkers -ne 0) { throw "Restart probe left durable reconciliation failure markers." }

  [pscustomobject]@{
    ActiveReservationsBeforeRestart = $activeBeforeRestart
    JobsFailedAfterRestart = $terminalJobs
    UsageRowsFailed = $failedUsageAfterSecondRestart
    ReservationsReleased = $releasedAfterSecondRestart
    CompletedOutboxRows = $outboxAfterSecondRestart
    DuplicateOutboxRows = $outboxAfterSecondRestart - $ProbeJobCount
    FailureMarkers = $failureMarkers
    SecondRestartAccountingStable = $true
  } | ConvertTo-Json -Compress
} finally {
  if (-not [string]::IsNullOrWhiteSpace($databaseName) -and
      -not [string]::IsNullOrWhiteSpace($databaseUser) -and $user -and $user.AccountId) {
    Invoke-Psql "UPDATE accounts SET status = 'DISABLED', token_version = token_version + 1, updated_at = now() WHERE id = '$($user.AccountId)' AND status = 'ACTIVE';" | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($databaseName) -and
      -not [string]::IsNullOrWhiteSpace($databaseUser) -and $adminId) {
    Invoke-Psql "UPDATE accounts SET status = 'DISABLED', token_version = token_version + 1, updated_at = now() WHERE id = '$adminId' AND status = 'ACTIVE';" | Out-Null
  }
}
