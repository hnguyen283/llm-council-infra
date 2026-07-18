param(
  [string]$BaseUrl = "http://127.0.0.1:8080",
  [ValidateRange(5, 1000)][int]$JobCount = 100,
  [ValidateRange(60, 14400)][int]$JobTimeoutSeconds = 7200,
  [ValidateRange(1, 20)][int]$JobInFlightLimit = 5,
  [ValidateRange(1, 60)][int]$PollIntervalSeconds = 5,
  [string]$PostgresContainer = "llm-council-standard-postgres-1",
  [switch]$SkipLoadProof
)

$ErrorActionPreference = "Stop"

# This runner is deliberately self-contained and only creates disposable local
# accounts. Its stdout is an evidence ledger: it must never print credentials,
# bearer tokens, workspace IDs, account IDs, request IDs, prompts, or exports.
$runNonce = [Guid]::NewGuid().ToString("N")
$tempPlan = Join-Path ([IO.Path]::GetTempPath()) ("bp15-plan-" + $runNonce + ".json")
$evidenceKey = [Guid]::NewGuid().ToString("N")
$password = "bp15-" + [Guid]::NewGuid().ToString("N")

function Assert-LastExitCode([string]$Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Invoke-Psql([string]$Sql) {
  & docker exec $PostgresContainer psql -U llm_admin -d $script:databaseName -v ON_ERROR_STOP=1 -qAt -c ("SET search_path TO account; " + $Sql)
  Assert-LastExitCode "Postgres query"
}

function Invoke-Api([string]$Method, [string]$Path, $Body, [string]$Token, [string]$WorkspaceId, [string]$DeviceId) {
  $headers = @{}
  if ($Token) { $headers.Authorization = "Bearer $Token" }
  if ($WorkspaceId) { $headers["X-Workspace-Id"] = $WorkspaceId }
  if ($DeviceId) { $headers["X-Device-Id"] = $DeviceId }
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

function Get-EvidenceLabel([string]$Value) {
  $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($evidenceKey))
  try {
    $hex = [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace("-", "").ToLowerInvariant()
    return "h_" + $hex.Substring(0, 16)
  } finally {
    $hmac.Dispose()
  }
}

function New-DisposableUser($AdminToken, [int]$Index) {
  $suffix = $runNonce.Substring(0, 12) + $Index
  $deviceId = "bp15-device-" + $suffix
  $created = Invoke-Api "POST" "/admin/accounts" @{
    username = "bp15u_$suffix"
    email = "bp15u_$suffix@example.invalid"
    password = $password
    roles = @("USER")
  } $AdminToken $null $null
  $login = Invoke-Api "POST" "/auth/login" @{ username = $created.username; password = $password } $null $null $deviceId
  $workspaces = @(Invoke-Api "GET" "/me/workspaces" $null $login.accessToken $null)
  if ($workspaces.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$workspaces[0].tenantId)) {
    throw "Disposable user workspace provisioning did not return exactly one workspace (count=$($workspaces.Count))."
  }
  return [pscustomobject]@{
    AccountId = [string]$created.id
    Username = [string]$created.username
    Token = [string]$login.accessToken
    WorkspaceId = [string]$workspaces[0].tenantId
    DeviceId = $deviceId
  }
}

function Renew-DisposableUser($User) {
  $login = Invoke-Api "POST" "/auth/login" @{ username = $User.Username; password = $password } $null $null $User.DeviceId
  if ([string]::IsNullOrWhiteSpace([string]$login.accessToken)) {
    throw "Disposable user reauthentication did not return an access token."
  }
  $User.Token = [string]$login.accessToken
}

function Submit-PrivacyRequest($User, [string]$RequestType) {
  $result = Invoke-Api "POST" "/me/privacy/requests" @{ requestType = $RequestType } $User.Token $User.WorkspaceId
  if ([string]$result.status -ne "COMPLETED") {
    throw "Privacy request $RequestType did not complete."
  }
  return [string]$result.requestId
}

try {
  $databaseName = (& docker exec $PostgresContainer printenv POSTGRES_DB).Trim()
  Assert-LastExitCode "Postgres database discovery"
  if ([string]::IsNullOrWhiteSpace($databaseName)) { throw "POSTGRES_DB is not set in the Postgres container." }

  $adminId = [Guid]::NewGuid().ToString()
  $adminUser = "bp15admin_" + $runNonce.Substring(0, 12)
  $adminEmail = $adminUser + "@example.invalid"
  $adminDeviceId = "bp15-admin-device-" + $runNonce.Substring(0, 12)
  $adminTenantKey = "t_" + $adminId.Replace("-", "")
  $adminSql = "INSERT INTO accounts (id, username, email, password_hash, hash_algorithm, status) VALUES ('$adminId', '$adminUser', '$adminEmail', public.crypt('password', public.gen_salt('bf', 12)), 'BCRYPT', 'ACTIVE'); INSERT INTO account_roles (account_id, role_id) SELECT '$adminId', id FROM roles WHERE name = 'ADMIN'; INSERT INTO tenant (id, name, type, tenant_key) VALUES ('$adminId', 'BP1.5 Disposable Admin Tenant', 'PERSONAL', '$adminTenantKey'); INSERT INTO tenant_membership (tenant_id, account_id, role) VALUES ('$adminId', '$adminId', 'OWNER'); INSERT INTO billing_profile (tenant_id) VALUES ('$adminId');"
  Invoke-Psql $adminSql | Out-Null

  Write-Host "BP1.5 stage: disposable administrator authentication"
  $adminLogin = Invoke-Api "POST" "/auth/login" @{ username = $adminUser; password = "password" } $null $null $adminDeviceId
  if ([string]::IsNullOrWhiteSpace([string]$adminLogin.accessToken)) { throw "Disposable administrator login did not return an access token." }
  $claimsSegment = $adminLogin.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
  $claimsSegment += '=' * ((4 - $claimsSegment.Length % 4) % 4)
  $adminClaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsSegment)) | ConvertFrom-Json
  if (@($adminClaims.roles) -notcontains "ADMIN") { throw "Disposable administrator token does not carry the ADMIN role." }

  Write-Host "BP1.5 stage: disposable tenant provisioning"
  $users = @(0..4 | ForEach-Object { New-DisposableUser $adminLogin.accessToken $_ })
  $legalHoldUser = New-DisposableUser $adminLogin.accessToken 5

  # Seed an explicit granted consent for the disposable withdrawal subject;
  # account provisioning itself does not invent consent on a user's behalf.
  Invoke-Psql "INSERT INTO consent_record (data_subject_id, purpose, status, legal_basis) VALUES ('$($users[2].AccountId)', 'BP1.5 disposable graduation consent', 'GRANTED', 'CONSENT');" | Out-Null

  # The hold is introduced directly in the disposable local database because
  # its administration is intentionally not exposed on the public user API.
  Invoke-Psql "INSERT INTO legal_hold (data_subject_id, reason, scope) VALUES ('$($legalHoldUser.AccountId)', 'BP1.5 disposable graduation hold', 'DELETION');" | Out-Null

  if (-not $SkipLoadProof) {
    $plan = [pscustomobject]@{
      tenants = @($users | ForEach-Object {
        [pscustomobject]@{
          workspaceId = $_.WorkspaceId
          accessToken = $_.Token
          username = $_.Username
          password = $password
          deviceId = $_.DeviceId
        }
      })
    }
    # This file contains bearer tokens and disposable reauthentication
    # material, stays outside the repository, and is deleted in finally. It is
    # an operational input to the hardened load proof.
    $plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempPlan -Encoding UTF8

    & (Join-Path $PSScriptRoot "bp15-load-proof.ps1") -BaseUrl $BaseUrl -PlanFile $tempPlan -EvidenceHmacKey $evidenceKey -Concurrency $JobCount -InFlightLimit $JobInFlightLimit -TimeoutSeconds $JobTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
    if ($LASTEXITCODE -ne 0) { throw "BP1.5 load proof failed." }
  }

  # The load proof may reauthenticate after short-lived access JWTs expire.
  # Reuse the same device identity so the session id remains stable, then
  # renew the outer runner's tokens before exercising privacy endpoints.
  foreach ($user in $users) { Renew-DisposableUser $user }
  Renew-DisposableUser $legalHoldUser
  $adminLogin = Invoke-Api "POST" "/auth/login" @{ username = $adminUser; password = "password" } $null $null $adminDeviceId

  $exportRequestId = Submit-PrivacyRequest $users[0] "ACCESS_EXPORT"
  $restrictionRequestId = Submit-PrivacyRequest $users[1] "RESTRICTION"
  $withdrawRequestId = Submit-PrivacyRequest $users[2] "WITHDRAW_CONSENT"
  $deletionRequestId = Submit-PrivacyRequest $users[3] "DELETION"

  try {
    Invoke-Api "GET" ("/me/privacy/requests/" + $exportRequestId) $null $users[4].Token $users[4].WorkspaceId | Out-Null
    throw "Cross-workspace privacy request lookup unexpectedly succeeded."
  } catch {
    if ($_.Exception.Message -eq "Cross-workspace privacy request lookup unexpectedly succeeded.") { throw }
    if ((Get-StatusCode $_) -ne 404) { throw "Cross-workspace privacy lookup did not fail closed with 404." }
  }

  $legalHoldResponse = Invoke-Api "POST" "/me/privacy/requests" @{ requestType = "DELETION" } $legalHoldUser.Token $legalHoldUser.WorkspaceId
  if ([string]$legalHoldResponse.status -ne "BLOCKED_LEGAL_HOLD") { throw "Legal hold did not block deletion." }

  $allAccountIds = @($users.AccountId) + @($legalHoldUser.AccountId)
  $idList = ($allAccountIds | ForEach-Object { "'$_'" }) -join ","
  $privacySummary = @(Invoke-Psql "SELECT request_type || ':' || status || ':' || count(*) FROM privacy_request WHERE data_subject_id IN ($idList) GROUP BY request_type, status ORDER BY request_type, status;")
  $artifactCount = [int](Invoke-Psql "SELECT count(*) FROM privacy_export_artifact WHERE data_subject_id = '$($users[0].AccountId)';")
  $restrictionCount = [int](Invoke-Psql "SELECT count(*) FROM personal_data_locator WHERE data_subject_id = '$($users[1].AccountId)' AND deletion_state = 'PENDING_DELETION';")
  $withdrawCount = [int](Invoke-Psql "SELECT count(*) FROM consent_record WHERE data_subject_id = '$($users[2].AccountId)' AND status = 'WITHDRAWN';")
  $erasedAccountCount = [int](Invoke-Psql "SELECT count(*) FROM accounts WHERE id = '$($users[3].AccountId)' AND deleted_at IS NOT NULL;")
  $holdTaskCount = [int](Invoke-Psql "SELECT count(*) FROM erasure_task et JOIN privacy_request pr ON pr.id = et.privacy_request_id WHERE pr.data_subject_id = '$($legalHoldUser.AccountId)' AND et.status IN ('SKIPPED_LEGAL_HOLD', 'BLOCKED');")
  if ($artifactCount -lt 1 -or $restrictionCount -lt 1 -or $withdrawCount -lt 1 -or $erasedAccountCount -ne 1 -or $holdTaskCount -lt 1) {
    throw "Privacy persistence assertions failed."
  }

  # Prevent accidental reuse of the accounts that are still active. Deletion
  # evidence keeps its account erased; the legal-hold subject remains held.
  foreach ($user in @($users[0], $users[1], $users[2], $users[4], $legalHoldUser)) {
    Invoke-Api "POST" ("/admin/accounts/" + $user.AccountId + "/status") @{ status = "DISABLED" } $adminLogin.accessToken $null | Out-Null
  }

  [pscustomobject]@{
    Run = Get-EvidenceLabel $runNonce
    LoadProofExecuted = -not $SkipLoadProof
    JobCount = if ($SkipLoadProof) { 0 } else { $JobCount }
    TenantCount = $users.Count
    PrivacyRequestStates = $privacySummary
    ExportArtifactPresent = $artifactCount -ge 1
    RestrictedLocatorPresent = $restrictionCount -ge 1
    WithdrawnConsentPresent = $withdrawCount -ge 1
    DeletedAccountPresent = $erasedAccountCount -eq 1
    LegalHoldTaskPresent = $holdTaskCount -ge 1
    CrossWorkspacePrivacyDenied = $true
  } | ConvertTo-Json -Depth 4
} finally {
  Remove-Item -LiteralPath $tempPlan -Force -ErrorAction SilentlyContinue
}
